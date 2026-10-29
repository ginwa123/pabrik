import { describe, it, expect, vi } from 'vitest'
import { Cause, Effect } from 'effect'
import { SessionEngineDb, toSessionRow, sessionSortKey } from '../SessionEngineDb'
import { SyncRemoteError } from '../SyncError'
import { makeMemorySyncStore } from '../SyncStore'
import type { Chat } from '../../api'

const session = (over: Partial<Chat> = {}): Chat =>
  ({
    session_id: 's1',
    session_name: 'Hello',
    status: 'active',
    updated_at: '2026-09-20 10:00:00',
    last_human_touched_at: '',
    ...over,
  }) as Chat

const fetchOk = (sessions: Chat[], extra: object = {}) =>
  vi.fn(async () => ({
    sessions,
    has_more: false,
    next_cursor: null,
    total: sessions.length,
    ...extra,
  }))

const fetchFail = (reason: string) =>
  vi.fn(async () => {
    throw new Error(reason)
  })

/** Every engine gets its own in-memory store, as it did before the port. */
const engineWith = (fetchFn: unknown) =>
  new SessionEngineDb(fetchFn as never, 'sessions', makeMemorySyncStore())

const run = <A, E>(eff: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(eff)

describe('SessionEngineDb mapping', () => {
  it('sortKey tracks updated_at (backend sort_by) with empty fallback', () => {
    expect(sessionSortKey(session({ updated_at: '2026-09-20 10:00:00' }))).toBe(
      '2026-09-20 10:00:00',
    )
    expect(sessionSortKey(session({ updated_at: '' }))).toBe('')
    expect(sessionSortKey(session({ updated_at: undefined }))).toBe('')
  })

  it('toSessionRow keeps the full server row in raw', () => {
    const row = toSessionRow(
      session({ session_id: 'abc', git_branch: 'feat/x', sub_agent_name: 'helper' }),
    )
    expect(row.id).toBe('abc')
    expect(row.sortKey).toBe('2026-09-20 10:00:00')
    expect(row.raw.git_branch).toBe('feat/x')
    expect(row.raw.sub_agent_name).toBe('helper')
  })

  it('compareFn sorts newest-first (ISO strings compare lexicographically)', () => {
    const eng = engineWith(fetchOk([]))
    const a = toSessionRow(session({ session_id: 'a', updated_at: '2026-09-19 10:00:00' }))
    const b = toSessionRow(session({ session_id: 'b', updated_at: '2026-09-21 10:00:00' }))
    expect([a, b].sort((x, y) => eng.compareFn(x, y)).map((r) => r.id)).toEqual(['b', 'a'])
  })
})

describe('SessionEngineDb delta', () => {
  it('fetchDeltaPage asks for page 1 desc (backend cursor only pages older)', async () => {
    const fetchFn = fetchOk([session()])
    const eng = engineWith(fetchFn)

    const delta = await run(eng.fetchDeltaPage('ignored-cursor', 30, 'ws-1'))

    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]).toEqual(['updated_at', 'desc', 30, undefined, 'ws-1'])
    expect(delta.items).toHaveLength(1)
    expect(delta.items[0]!.id).toBe('s1')
    expect(delta.total).toBe(1)
  })

  it("ctx 'all' fetches unscoped (workspaceId undefined)", async () => {
    const fetchFn = fetchOk([])
    const eng = engineWith(fetchFn)
    await run(eng.fetchDeltaPage(null, 30, 'all'))
    expect(fetchFn.mock.calls[0]).toEqual(['updated_at', 'desc', 30, undefined, undefined])
  })

  it('loadDelta persists rows so primeFromCache paints them (in-memory path)', async () => {
    const eng = engineWith(fetchOk([session({ session_id: 'n1' }), session({ session_id: 'n2' })]))
    expect(await run(eng.primeFromCache('ws-cache', 30))).toHaveLength(0)

    const delta = await run(eng.loadDelta('ws-cache', 30))

    expect(delta).not.toBeNull()
    const cached = await run(eng.primeFromCache('ws-cache', 30))
    expect(cached.map((r) => r.id).sort()).toEqual(['n1', 'n2'])
  })

  it('loadDelta fails with a typed SyncRemoteError and keeps the painted cache', async () => {
    // Seed the cache through a working engine, then revalidate with a
    // failing fetcher against the same store.
    const store = makeMemorySyncStore()
    const seeded = new SessionEngineDb(fetchOk([]) as never, 'sessions', store)
    await run(seeded.putLocal('ws-fail', [toSessionRow(session({ session_id: 'keep' }))]))

    const failing = new SessionEngineDb(fetchFail('offline') as never, 'sessions', store)

    // The old contract returned `null` here, which the caller could not tell
    // apart from "no new sessions". Now the reason is in the type.
    const exit = await Effect.runPromise(Effect.exit(failing.loadDelta('ws-fail', 30)))
    expect(exit._tag).toBe('Failure')
    const err = exit._tag === 'Failure' ? (Cause.squash(exit.cause) as SyncRemoteError) : null
    expect(err).toMatchObject({
      _tag: 'SyncRemoteError',
      op: 'sessions.fetchDelta',
      reason: 'offline',
    })

    // …and the painted cache survived the failure.
    expect((await run(failing.primeFromCache('ws-fail', 30))).map((r) => r.id)).toEqual(['keep'])
  })

  it('an empty page flagged failed is a failed refresh, not an empty scope', async () => {
    const eng = engineWith(fetchOk([], { failed: true }))

    const exit = await Effect.runPromise(Effect.exit(eng.loadDelta('ws-flag', 30)))

    expect(exit._tag).toBe('Failure')
  })

  it('removeSession evicts one row and leaves the rest', async () => {
    const eng = engineWith(fetchOk([]))
    await run(
      eng.putLocal('ws-evict', [
        toSessionRow(session({ session_id: 'gone' })),
        toSessionRow(session({ session_id: 'stays' })),
      ]),
    )

    await run(eng.removeSession('ws-evict', 'gone'))

    expect((await run(eng.primeFromCache('ws-evict', 30))).map((r) => r.id)).toEqual(['stays'])
  })

  it('caches are partitioned by workspace ctx', async () => {
    const eng = engineWith(fetchOk([]))
    await run(eng.putLocal('ws-a', [toSessionRow(session({ session_id: 'only-a' }))]))
    expect(await run(eng.primeFromCache('ws-b', 30))).toHaveLength(0)
    expect((await run(eng.primeFromCache('ws-a', 30))).map((r) => r.id)).toEqual(['only-a'])
  })
})
