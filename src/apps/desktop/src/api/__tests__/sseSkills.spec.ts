/** Task 2 — SseEvent carries live session_skills. Backend: sse_on_event_send_llm_history.zig:45
 * (SseEventLLMHistory.session_skills, next to is_error). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import type { SseEvent, SkillInfo } from '../index'
import { getChatHistory } from '../index'

function apiIndexSource(): string {
  const cands = [
    join(process.cwd(), 'src/api/sseEvents.ts'), // cwd = src/apps/desktop
    join(process.cwd(), 'src/apps/desktop/src/api/sseEvents.ts'), // cwd = repo root
  ]
  try {
    cands.unshift(join(dirname(fileURLToPath(import.meta.url)), '../sseEvents.ts'))
  } catch {
    // vite-rewritten import.meta.url — fall through to cwd candidates.
  }
  const hit = cands.find((p) => existsSync(p))
  if (!hit) throw new Error(`api/index.ts not found (tried ${cands.join(', ')})`)
  return readFileSync(hit, 'utf8')
}

describe('SseEvent session_skills (live skills over SSE)', () => {
  it('accepts session_skills?: SkillInfo[] (compile + runtime passthrough)', () => {
    const skills: SkillInfo[] = [{ skill_name: 'pdf', content: '...', loaded_at: 123 }]
    const evt: SseEvent = { session_id: 'sess_1', session_skills: skills }
    expect(evt.session_skills).toHaveLength(1)
    expect(evt.session_skills?.[0]?.skill_name).toBe('pdf')
  })

  it('leaves session_skills undefined when the backend omits it', () => {
    const evt: SseEvent = { session_id: 'sess_1' }
    expect(evt.session_skills).toBeUndefined()
    const roundTripped = JSON.parse(JSON.stringify(evt)) as SseEvent
    expect(roundTripped.session_skills).toBeUndefined()
  })

  it('declares session_skills?: SkillInfo[] on the SseEvent wire shape', () => {
    expect(apiIndexSource()).toMatch(/session_skills\?:\s*SkillInfo\[\]/)
  })
})

describe('getChatHistory error path returns skills [] (Task 4)', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('resolves with skills: [] when the backend is unreachable', async () => {
    vi.stubGlobal('fetch', () => Promise.reject(new Error('backend down')))
    const data = await getChatHistory('sess_1', 50)
    expect(data.messages).toEqual([])
    expect(data.skills).toEqual([])
  })
})
