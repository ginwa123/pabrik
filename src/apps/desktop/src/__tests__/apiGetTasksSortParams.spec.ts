/** Behavioural tests for the no-default-sort-by behavior of `api.getTasks` (kanban default-URL,
 * 2026-08-06). Why. The frontend used to send `sort_by=updated_at&direction=desc` on every
 * task-fetch — even when the URL had no `sorts` param and the user hadn't picked a sort. */

/** The backend's default is also `updated_at desc`, so the wire payload was redundant and noisy in
 * the network tab. The user feedback: "no need set default when load task kanban". */

/** New behaviour: `api.getTasks` only adds `sort_by` and `direction` to the URL params when BOTH
 * are explicitly provided. Missing either → both omitted → backend defaults apply. */

/** Match-up: the URL round-trip end-to-end tests in `AppLayout.urlPersist.spec.ts` and
 * `KanbanView.sortByApi.spec.ts` cover the higher-level "click sort → URL → fetch" flow. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as api from '../api'

describe('api.getTasks — sort params (2026-08-06 no-default behavior)', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    // Spy on the globally-patched fetch so we can read the URL
    // and the saved params. Each test sets the response so the
    // call doesn't throw.
    fetchSpy = vi.spyOn(globalThis, 'fetch')
  })

  afterEach(() => {
    fetchSpy.mockRestore()
  })

  // ─── 1. No sort params → URL omits sort_by + direction ──────────────

  it('omits sort_by + direction when neither is provided', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await api.getTasks('ws_1', 'item_1', 10)

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    expect(calledUrl).not.toContain('sort_by=')
    expect(calledUrl).not.toContain('direction=')
    // The other expected params are still present.
    expect(calledUrl).toContain('limit=10')
  })

  it('omits sort_by + direction when only sortBy is provided (no direction)', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    // Type-assert to bypass the optional parameter narrowing — the
    // contract under test is the runtime behaviour when one of the
    // pair is undefined.
    await api.getTasks(
      'ws_1',
      'item_1',
      10,
      undefined,
      'updated_at' as 'created_at' | 'updated_at' | 'name',
      undefined,
    )

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    // Backend requires both together — we DON'T send sort_by
    // without direction (cursor format depends on the sort field).
    expect(calledUrl).not.toContain('sort_by=')
    expect(calledUrl).not.toContain('direction=')
  })

  it('omits sort_by + direction when only direction is provided (no sortBy)', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await api.getTasks(
      'ws_1',
      'item_1',
      10,
      undefined,
      undefined,
      'desc' as 'asc' | 'desc',
    )

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    expect(calledUrl).not.toContain('sort_by=')
    expect(calledUrl).not.toContain('direction=')
  })

  // ─── 2. Both provided → URL has sort_by + direction ─────────────────

  it('includes sort_by + direction when both are provided', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await api.getTasks('ws_1', 'item_1', 10, undefined, 'updated_at', 'desc')

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    expect(calledUrl).toContain('sort_by=updated_at')
    expect(calledUrl).toContain('direction=desc')
  })

  it('includes sort_by + direction for the explicit-name sort', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await api.getTasks('ws_1', 'item_1', 10, undefined, 'name', 'asc')

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    expect(calledUrl).toContain('sort_by=name')
    expect(calledUrl).toContain('direction=asc')
  })

  // ─── 3. Other params (column_id, q, cursor) still sent ──────────────

  it('still includes column_id, q, and cursor when no sort provided', async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ tasks: [], has_more: false, next_cursor: null }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await api.getTasks(
      'ws_1',
      'item_1',
      10,
      'cursor_abc',
      undefined,
      undefined,
      'col_X',
      'search term',
    )

    const calledUrl = fetchSpy.mock.calls[0]![0] as string
    expect(calledUrl).toContain('limit=10')
    expect(calledUrl).toContain('cursor=cursor_abc')
    expect(calledUrl).toContain('column_id=col_X')
    expect(calledUrl).toContain('q=search+term')
    expect(calledUrl).not.toContain('sort_by=')
    expect(calledUrl).not.toContain('direction=')
  })
})