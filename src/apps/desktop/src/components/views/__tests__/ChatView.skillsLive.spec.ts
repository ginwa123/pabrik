/** Tests for ChatView's live skills-badge update from `llm_full` SSE. 2026-09-08
 * live-session-skills-sse Task 3 — the backend piggybacks `session_skills` on every `llm_full`
 * event (sse_on_event_send_llm_history.zig:45). */
import { describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'
import { readChatViewSource } from '../../../__tests__/helpers/chatViewSource'
import type * as api from '../../../api'

const SID = 'sess_target'

type FullEventLike = {
  type: 'full'
  session_id?: string
  content?: string
  finish_reason?: string
  session_skills?: api.SkillInfo[] | unknown
}

// Mirrors the ChatView.vue bus.on('llm') skills snippet (Task 3):
// session-scoped, Array.isArray-guarded, no loadChatHistory call.
function makeSkillsHandler() {
  const sessionSkills = ref<api.SkillInfo[]>([])
  const loadChatHistory = vi.fn()
  const onEvent = (event: FullEventLike) => {
    if (event.session_id !== SID) return
    if (event.type !== 'full') return
    // Live skills: backend piggybacks session_skills on every llm_full
    // (fresh on tool-result emit, stale on assistant emit — see
    // handle_tool.zig:459 vs :745). REST remains initial source.
    if (Array.isArray((event as { session_skills?: unknown }).session_skills))
      sessionSkills.value = (event as { session_skills: api.SkillInfo[] }).session_skills
  }
  return { sessionSkills, loadChatHistory, onEvent }
}

describe('ChatView live skills harness', () => {
  it('applies session_skills from a full event without loadChatHistory', () => {
    const { sessionSkills, loadChatHistory, onEvent } = makeSkillsHandler()
    onEvent({
      type: 'full',
      session_id: SID,
      content: 'done',
      finish_reason: 'stop',
      session_skills: [{ skill_name: 'live-skill', content: 'x' }],
    })
    expect(sessionSkills.value).toEqual([{ skill_name: 'live-skill', content: 'x' }])
    expect(loadChatHistory).not.toHaveBeenCalled()
  })

  it('ignores session_skills for a different session_id', () => {
    const { sessionSkills, onEvent } = makeSkillsHandler()
    onEvent({
      type: 'full',
      session_id: 'OTHER_SESSION',
      content: 'done',
      finish_reason: 'stop',
      session_skills: [{ skill_name: 'live-skill', content: 'x' }],
    })
    expect(sessionSkills.value).toEqual([])
  })

  it('ignores missing/non-array session_skills', () => {
    const { sessionSkills, onEvent } = makeSkillsHandler()
    onEvent({ type: 'full', session_id: SID, content: 'hi', finish_reason: 'stop' })
    onEvent({
      type: 'full',
      session_id: SID,
      content: 'hi',
      finish_reason: 'stop',
      session_skills: 'live-skill',
    })
    expect(sessionSkills.value).toEqual([])
  })
})

describe('ChatView.vue live-skills wiring (static contract)', () => {
  const src = readChatViewSource()
  const llmHandler = src.slice(src.indexOf("bus.on('llm'"))

  it('handler reads session_skills into sessionSkills', () => {
    expect(llmHandler).toContain('session_skills')
    expect(llmHandler).toContain('sessionSkills.value')
  })

  it('covers BOTH full paths (in-place AND push returns)', () => {
    const hits = llmHandler.match(/sessionSkills\.value\s*=/g) || []
    expect(hits.length).toBeGreaterThanOrEqual(2)
  })

  it('guards with Array.isArray and never calls loadChatHistory for skills', () => {
    expect(llmHandler).toContain('Array.isArray')
    const skillsLines = llmHandler.split('\n').filter((l) => l.includes('sessionSkills.value'))
    expect(skillsLines.some((l) => l.includes('loadChatHistory'))).toBe(false)
  })
})
