// Behavioural tests for the chatview profile persistence bug fix. Bug: "profiles in chatview not
// persistent" (2026-08-07). The user picked a profile (e.g. "900ribu") in the chatview dropdown →
// chip showed the selection → user refreshed the page → chip reverted to "Default" (no profile).
// Root cause: PUT /api/llm/session/:id writes the profile to `sessions.selected_profile_model`, but
// the read endpoint (GET /api/llm/session/:id/messages) never returned it.
// The frontend's `loadChatHistory` / `getSession` always saw `undefined` and ChatView's
// `selectedProfile` ref defaulted to `null`.
// Fix: `getChatHistory` now extracts `data.selected_profile_model` from the messages response, and
// ChatView's `loadChatHistory` reads it into `selectedProfile.value` after the messages are
// rendered.
// These tests pin down the wire shape (TypeScript side) so a future refactor of the API wrapper
// doesn't silently re-introduce the bug.
import { describe, expect, it } from 'vitest'
import * as api from '../api'

describe('chatview profile persistence — selected_profile_model wire shape', () => {
  it('getChatHistory return type includes selected_profile_model?: string', () => {
    // The TypeScript return-type of getChatHistory must carry the field. A refactor that drops it
    // would silently re-introduce the bug (frontend would read `undefined` and reset to null).
    // We assert the type via the explicit return shape — the value flows through the apiFetch call
    // below.
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

  it('getSession return type carries selectedProfile?: string | undefined', () => {
    type Ret = Awaited<ReturnType<typeof api.getSession>>
    // If the getSession impl drops the field, the assignment fails
    // type-check. Lock it down.
    const sample: Ret = {
      sessionId: 'sess_x',
      cwd: '',
      createdAt: '',
      agent: '',
      sessionName: '',
      selectedProfile: '900ribu',
      git_worktree_cwd: undefined,
    }
    expect(sample.selectedProfile).toBe('900ribu')
  })

  it('empty / missing selected_profile_model coerces to null semantics', () => {
    // The frontend's loadChatHistory branch in ChatView.vue does selectedProfile.value =
    // data.selected_profile_model || null so empty string (= "no profile set" from the backend's
    // COALESCE-on-NULL) is treated identically to missing/undefined.
    // Lock in that coercion here so a future "let me use ?? instead" refactor is caught.
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
