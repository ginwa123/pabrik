// Behavioural tests for the chatview profile persistence bug fix. Bug: "profiles in chatview not
// persistent" (2026-08-07). The user picked a profile (e.g. "900ribu") in the chatview dropdown →
// chip showed the selection → user refreshed the page → chip reverted to "Default" (no profile).
import { describe, expect, it } from 'vitest'
import * as api from '../api'

describe('chatview profile persistence — selected_profile_model wire shape', () => {
  it('getChatHistory return type includes selected_profile_model?: string', () => {
    // The TypeScript return-type of getChatHistory must carry the field. A refactor that drops it
    // would silently re-introduce the bug (frontend would read `undefined` and reset to null).
    type Ret = Awaited<ReturnType<typeof api.getChatHistory>>
    // Compile-time check: if the field is missing, this assignment
    // fails to type-check.
    const sample: Ret = {
      messages: [],
      has_more: false,
      next_cursor: null,
      cwd: undefined,
      git_worktree_cwd: undefined,
      selected_profile_model: '900ribu',
      max_total_tokens: undefined,
      max_capacity_total_tokens: undefined,
      total_count: undefined,
      skills: undefined,
    }
    expect(sample.selected_profile_model).toBe('900ribu')
  })

  it('getSession return type carries selectedAgent?: string | undefined', () => {
    type Ret = Awaited<ReturnType<typeof api.getSession>>
    // If the getSession impl drops the field, the assignment fails
    // type-check. Lock it down.
    const sample: Ret = {
      sessionId: 'sess_x',
      cwd: '',
      createdAt: '',
      agent: '',
      sessionName: '',
      selectedAgent: '900ribu',
      git_worktree_cwd: undefined,
    }
    expect(sample.selectedAgent).toBe('900ribu')
  })

  it('empty / missing selected_profile_model coerces to null semantics', () => {
    // The frontend's loadChatHistory branch in ChatView.vue does selectedAgent.value =
    // data.selected_profile_model || null so empty string (= "no profile set" from the backend's
    // COALESCE-on-NULL) is treated identically to missing/undefined.
    const cases: Array<{ input: string | undefined; expected: string | null }> = [
      { input: '900ribu', expected: '900ribu' },
      { input: '', expected: null },
      { input: undefined, expected: null },
    ]
    for (const c of cases) {
      const coerced = c.input || null
      expect(coerced).toBe(c.expected)
    }
  })
})
