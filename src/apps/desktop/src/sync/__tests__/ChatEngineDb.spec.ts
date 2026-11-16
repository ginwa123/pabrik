import { describe, it, expect, vi } from 'vitest'
import { Effect } from 'effect'
import { ChatEngineDb, toChatMessage } from '../ChatEngineDb'
import { makeMemorySyncStore } from '../SyncStore'
import type { ChatRawRow } from '../ChatEngineDb'

const rawRow = (over: Partial<ChatRawRow> = {}): ChatRawRow =>
  ({
    id: 'm1',
    role: 'user',
    content: 'hello',
    created_at: 1700000000,
    ...over,
  }) as ChatRawRow

const emptyHistory = async () => ({ messages: [], has_more: false, next_cursor: null })

/** Every engine gets its own in-memory store, as it did before the port. */
const engineWith = (fetchFn: unknown) =>
  new ChatEngineDb(fetchFn as never, 'messages', makeMemorySyncStore())

const run = <A, E>(eff: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(eff)

describe('ChatEngineDb mapping', () => {
  it('cursorOf returns created_at_nano string and compareFn sorts newest-first', () => {
    const eng = engineWith(emptyHistory)
    expect(
      eng.cursorOf({
        id: 'row-1',
        sortKey: 5,
        session_id: 's',
        created_at_nano: 5,
        created_at: 0,
        role: 'user',
        content: 'hi',
        raw: rawRow({ id: 'row-1' }),
      }),
    ).toBe('5')
    const a = toChatMessage('s', rawRow({ id: 'a', created_at: 1 }))
    const b = toChatMessage('s', rawRow({ id: 'b', created_at: 2 }))
    expect([a, b].sort((x, y) => eng.compareFn(x, y)).map((m) => m.id)).toEqual(['b', 'a'])
  })

  it('fetchDelta maps getChatHistory rows to ChatMessage (via syncOnMount)', async () => {
    const eng = engineWith(async () => ({
      messages: [rawRow()],
      has_more: true,
      next_cursor: 'cur-9',
    }))

    const res = await run(eng.syncOnMount('sess-1', 50))

    expect(res.items).toHaveLength(1)
    const first = res.items[0]!
    expect(first.id).toBe('m1')
    expect(first.session_id).toBe('sess-1')
    expect(first.created_at).toBe(1700000000)
    expect(res.delta?.nextCursor).toBe('cur-9')
    // Sync cursor tracks the newest row, not the pagination cursor, so the next mount fetches the tail instead of re-fetching the same page.
    expect(await run(eng.getCursor('sess-1'))).toBe(String(1700000000 * 1e9))
  })

  it('stores the full server row in raw (tool calls / images / reasoning survive)', async () => {
    const eng = engineWith(async () => ({
      messages: [
        rawRow({
          tool_calls_json: [{ name: 'edit' }],
          image_url: 'a.png|b.png',
          reasoning_content: 'thinking…',
        }),
      ],
      has_more: false,
      next_cursor: 'cur-1',
    }))

    const res = await run(eng.syncOnMount('sess-raw', 50))
    const cached = await run(eng.primeFromCache('sess-raw', 50))

    expect(cached).toHaveLength(1)
    const stored = cached[0]!
    expect(stored.raw.tool_calls_json).toEqual([{ name: 'edit' }])
    expect((stored.raw as { image_url?: string }).image_url).toBe('a.png|b.png')
    expect(stored.raw.reasoning_content).toBe('thinking…')
    expect(res.items[0]!.raw).toEqual(stored.raw)
  })

  it('delta-with-cursor sends cursor+asc; cold start sends no cursor (desc default)', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [],
        has_more: false,
        next_cursor: 'cur-next',
      }),
    )
    const eng = engineWith(fetchFn)

    // Cold start: no stored cursor → full load, direction left as default.
    await run(eng.loadDelta('sess-cold', 60))
    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]![2]).toBeUndefined()
    expect(fetchFn.mock.calls[0]![3] ?? 'desc').toBe('desc')

    // Warm mount: stored cursor → tail-only fetch with cursor+asc.
    fetchFn.mockClear()
    await run(eng.setCursor('sess-warm', 'stored-cur'))
    await run(eng.putLocal('sess-warm', [toChatMessage('sess-warm', rawRow({ id: 'old' }))]))
    const delta = await run(eng.loadDelta('sess-warm', 60))
    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]).toEqual(['sess-warm', 60, 'stored-cur', 'asc'])
    expect(delta?.cursorToSave).toBe('cur-next')
    expect(await run(eng.getCursor('sess-warm'))).toBe('cur-next')
  })

  it('small delta (has_more=false, next_cursor=null) advances cursor to newest row', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [rawRow({ id: 'n1', created_at: 100 }), rawRow({ id: 'n2', created_at: 200 })],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = engineWith(fetchFn)
    await run(eng.setCursor('sess-small', '1700000000'))

    const delta = await run(eng.loadDelta('sess-small', 1000))

    // Tail-only fetch with the stored cursor…
    expect(fetchFn.mock.calls[0]).toEqual(['sess-small', 1000, '1700000000', 'asc'])
    // …and the cursor advances to the newest row instead of being wiped to null.
    expect(delta?.cursorToSave).toBe(String(200 * 1e9))
    expect(await run(eng.getCursor('sess-small'))).toBe(String(200 * 1e9))
  })

  it('empty delta keeps the previous cursor instead of wiping it to null', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = engineWith(fetchFn)
    await run(eng.setCursor('sess-empty', '999'))

    const delta = await run(eng.loadDelta('sess-empty', 1000))

    expect(delta?.cursorToSave).toBe('999')
    expect(await run(eng.getCursor('sess-empty'))).toBe('999')
  })

  it('cold full load derives cursor from newest row when next_cursor is null', async () => {
    const fetchFn = vi.fn(
      async (_sid: string, _limit: number, _cursor?: string, _dir?: string) => ({
        messages: [rawRow({ id: 'a', created_at: 10 }), rawRow({ id: 'b', created_at: 30 })],
        has_more: false,
        next_cursor: null,
      }),
    )
    const eng = engineWith(fetchFn)

    const delta = await run(eng.loadDelta('sess-fresh', 1000))

    expect(fetchFn.mock.calls[0]![2]).toBeUndefined()
    expect(delta?.cursorToSave).toBe(String(30 * 1e9))
    expect(await run(eng.getCursor('sess-fresh'))).toBe(String(30 * 1e9))
  })

  it('does not let a delta overwrite a live row in preserveIds', async () => {
    const fetchFn = vi.fn(async () => ({
      messages: [rawRow({ id: 'tool-row-1', content: 'stale server row' })],
      has_more: false,
      next_cursor: null,
    }))
    const eng = engineWith(fetchFn)
    await run(
      eng.putLocal('sess-preserve', [
        toChatMessage('sess-preserve', rawRow({ id: 'tool-row-1', content: 'live SSE row' })),
      ]),
    )

    await run(eng.loadDelta('sess-preserve', 100, new Set(['tool-row-1'])))

    const cached = await run(eng.primeFromCache('sess-preserve', 100))
    expect(cached[0]?.raw.content).toBe('live SSE row')
    expect(await run(eng.getCursor('sess-preserve'))).toBeNull()
  })

  it('protects a live row written while the delta request is pending', async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    let started!: () => void
    const startedPromise = new Promise<void>((resolve) => {
      started = resolve
    })
    const fetchFn = vi.fn(async () => {
      started()
      await gate
      return {
        messages: [rawRow({ id: 'tool-row-1', content: 'stale server row' })],
        has_more: false,
        next_cursor: null,
      }
    })
    const eng = engineWith(fetchFn)
    const preserveIds = new Set<string>()

    const pending = Effect.runPromise(eng.loadDelta('sess-race', 100, preserveIds))
    await startedPromise

    preserveIds.add('tool-row-1')
    await run(
      eng.putLocal('sess-race', [
        toChatMessage('sess-race', rawRow({ id: 'tool-row-1', content: 'live SSE row' })),
      ]),
    )
    release()
    await pending

    const cached = await run(eng.primeFromCache('sess-race', 100))
    expect(cached[0]?.raw.content).toBe('live SSE row')
    expect(await run(eng.getCursor('sess-race'))).toBeNull()
  })

  it('older-from-cache hit serves rows with zero network calls', async () => {
    const fetchFn = vi.fn(emptyHistory)
    const eng = engineWith(fetchFn)
    const newer = toChatMessage('sess-older', rawRow({ id: 'new', created_at: 200 }))
    const older = toChatMessage('sess-older', rawRow({ id: 'old', created_at: 100 }))
    await run(eng.putLocal('sess-older', [newer, older]))

    const rows = await run(eng.loadOlderFromCache('sess-older', newer.sortKey, 50))

    expect(rows.map((r) => r.id)).toEqual(['old'])
    // Full-fidelity raw rides along for the view mapper.
    expect(rows[0]!.raw.content).toBe('hello')
    expect(fetchFn).not.toHaveBeenCalled()
  })

  it('loadDelta reports a backend failure instead of returning null', async () => {
    const fetchFn = vi.fn(async () => {
      throw new Error('backend down')
    })
    const eng = engineWith(fetchFn)

    const exit = await Effect.runPromise(Effect.exit(eng.loadDelta('sess-err', 50)))

    expect(exit._tag).toBe('Failure')
  })
})
