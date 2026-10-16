/** Migration 082 - wire-format + mapper tests for `getChats`. The backend
 * (llm_history.zig::buildSessionListJson + session_list.zig) now emits `last_human_touched_at` on
 * every session in the GET /api/sessions response. These tests lock in: 1. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import * as api from '../api'
import type { Chat } from '../api'

describe('getChats - Migration 082 last_human_touched_at wire shape', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch fires an error toast via useNotificationStore() on
    // non-2xx. A fresh Pinia keeps that path from crashing in tests.
    setActivePinia(createPinia())
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      // apiFetch on non-2xx calls response.text() for the toast payload.
      text: () => Promise.resolve(JSON.stringify(body)),
    } as unknown as Response)
  }

  it('forwards last_human_touched_at to Chat when the backend provides a value', async () => {
    // Backend wire shape: unix-ms as a string, e.g. "1786500000000".
    // Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
    mockFetchOnce(200, {
      sessions: [
        {
          session_id: 'sess_1',
          session_name: 'My chat',
          status: 'active',
          created_at: '2026-08-29 10:00:00',
          updated_at: '2026-08-29 10:05:00',
          last_human_touched_at: '1786500000000',
          is_auto_retry_until_stop: '0',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const result = await api.getChats('updated_at', 'desc', 30)

    expect(result.sessions).toHaveLength(1)
    expect(result.sessions[0]!.last_human_touched_at).toBe('1786500000000')
    // Sanity: other fields still pass through.
    expect(result.sessions[0]!.session_id).toBe('sess_1')
    expect(result.sessions[0]!.is_auto_retry_until_stop).toBe('0')
  })

  it('defaults last_human_touched_at to empty string when the backend omits it (legacy rows)', async () => {
    // Pre-Migration-082 sessions in the DB don't have the column at all - the backend COALESCE
    // renders them as '' in the SELECT, but this test guards the mapper fallback too in case the
    // field is missing from the JSON entirely.
    mockFetchOnce(200, {
      sessions: [
        {
          session_id: 'sess_legacy',
          session_name: 'Legacy chat',
          status: 'active',
          created_at: '2026-08-01 10:00:00',
          updated_at: '2026-08-29 10:05:00',
          // NO last_human_touched_at field
          is_auto_retry_until_stop: '0',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const result = await api.getChats('updated_at', 'desc', 30)

    expect(result.sessions[0]!.last_human_touched_at).toBe('')
  })

  it('preserves an explicit empty-string value (frontend `?? updated_at` fallback expects "")', async () => {
    mockFetchOnce(200, {
      sessions: [
        {
          session_id: 'sess_empty',
          session_name: 'Empty stamp',
          status: 'active',
          created_at: '2026-08-29 10:00:00',
          updated_at: '2026-08-29 10:05:00',
          last_human_touched_at: '', // explicit empty
          is_auto_retry_until_stop: '0',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const result = await api.getChats('updated_at', 'desc', 30)

    expect(result.sessions[0]!.last_human_touched_at).toBe('')
  })

  it('Chat interface accepts last_human_touched_at as an optional string', () => {
    // Type-level test: if the field becomes required or the type
    // changes (e.g. number), this assignment fails to compile.
    const withField: Chat = {
      session_id: 'sess_1',
      last_human_touched_at: '1786500000000',
    }
    expect(withField.last_human_touched_at).toBe('1786500000000')

    const withoutField: Chat = { session_id: 'sess_1' }
    expect(withoutField.last_human_touched_at).toBeUndefined()
  })
})