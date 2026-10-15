/** The Vue bridge: `runSyncEffect*` is what nineteen call sites in ChatView,
 * ChatsList and the workspaces store use to run an Effect from `<script setup>`.
 * Its whole job is to preserve the pre-Effect degradation behaviour (a failed
 * cache read never breaks a render) while keeping the typed reason reachable. */
import { Cause, Effect, Exit, Layer } from 'effect'
import { describe, expect, it, vi } from 'vitest'
import { SyncRemoteError, SyncStorageError, describeSyncError } from '../SyncError'
import { SyncStore, makeMemorySyncStore, memorySyncStoreLayer, sortNewestFirst } from '../SyncStore'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../runtime'

interface Row {
  id: string
  sortKey: number
}

const ok = <A>(value: A): Effect.Effect<A, SyncRemoteError> => Effect.succeed(value)
const boom = (reason: string): Effect.Effect<never, SyncRemoteError> =>
  Effect.fail(new SyncRemoteError({ op: 'test', reason }))

describe('runSyncEffect', () => {
  it('returns the value on success', async () => {
    await expect(runSyncEffect(ok(42), 'test')).resolves.toBe(42)
  })

  it('degrades to null on failure, the shape the old `catch { return null }` produced', async () => {
    await expect(runSyncEffect(boom('offline'), 'test')).resolves.toBeNull()
  })

  it('distinguishes a null value from a failure by the typed error on the channel', async () => {
    const asNull: Effect.Effect<null, SyncRemoteError> = Effect.succeed(null)
    await expect(runSyncEffect(asNull, 'test')).resolves.toBeNull()
    // Both render as null to the caller; only the Effect can tell them apart.
    const exit = await Effect.runPromise(Effect.exit(boom('offline')))
    expect(Exit.isFailure(exit)).toBe(true)
  })
})

describe('runSyncEffectOr', () => {
  it('returns the value on success', async () => {
    await expect(runSyncEffectOr(ok([1, 2]), [] as number[], 'test')).resolves.toEqual([1, 2])
  })

  it('degrades to the supplied fallback for non-null empties', async () => {
    await expect(runSyncEffectOr(boom('offline'), [] as number[], 'test')).resolves.toEqual([])
    await expect(
      runSyncEffectOr(boom('offline'), null as string | null, 'test'),
    ).resolves.toBeNull()
  })
})

describe('runSyncVoid', () => {
  it('resolves for an infallible effect', async () => {
    await expect(runSyncVoid(Effect.void, 'test')).resolves.toBeUndefined()
  })

  it('resolves rather than rejects even if the effect fails', async () => {
    const failing: Effect.Effect<void, SyncRemoteError> = boom('nope')
    await expect(runSyncVoid(failing, 'test')).resolves.toBeUndefined()
  })
})

describe('SyncStore as an Effect service', () => {
  it('the memory layer provides the service to a whole program', async () => {
    const program = Effect.gen(function* () {
      const store = yield* SyncStore
      yield* store.putAll<Row>('sessions', 'all', [{ id: 'a', sortKey: 1 }])
      return yield* store.getAll<Row>('sessions', 'all', 10)
    })

    const rows = await Effect.runPromise(Effect.provide(program, memorySyncStoreLayer))

    expect(rows).toEqual([{ id: 'a', sortKey: 1 }])
  })

  it('Layer.succeed substitutes a double for one program', async () => {
    const failing: Layer.Layer<SyncStore> = Layer.succeed(SyncStore)({
      ...makeMemorySyncStore(),
      getAll: () =>
        Effect.fail(
          new SyncStorageError({ op: 'getAll', store: 'sessions', reason: 'db closed' }),
        ) as never,
    })
    const program = Effect.gen(function* () {
      const store = yield* SyncStore
      return yield* store.getAll<Row>('sessions', 'all', 10)
    })

    const exit = await Effect.runPromise(Effect.exit(Effect.provide(program, failing)))

    expect(Exit.isFailure(exit)).toBe(true)
    const err = Exit.isFailure(exit) ? (Cause.squash(exit.cause) as SyncStorageError) : null
    expect(err).toMatchObject({ _tag: 'SyncStorageError', store: 'sessions' })
  })

  it('the memory store partitions by object store, not just by context key', async () => {
    const store = makeMemorySyncStore()
    await Effect.runPromise(store.putAll<Row>('messages', 'shared', [{ id: 'm', sortKey: 1 }]))

    expect(await Effect.runPromise(store.getAll<Row>('messages', 'shared', 10))).toHaveLength(1)
    expect(await Effect.runPromise(store.getAll<Row>('sessions', 'shared', 10))).toHaveLength(0)
  })
})

describe('sortNewestFirst', () => {
  it('orders numeric sort keys descending', () => {
    const rows = [
      { id: 'a', sortKey: 1 },
      { id: 'c', sortKey: 3 },
      { id: 'b', sortKey: 2 },
    ]
    expect(sortNewestFirst(rows).map((r) => r.id)).toEqual(['c', 'b', 'a'])
  })

  it('orders string sort keys descending', () => {
    const rows = [
      { id: 'a', sortKey: '2026-09-19' },
      { id: 'c', sortKey: '2026-09-21' },
      { id: 'b', sortKey: '2026-09-20' },
    ]
    expect(sortNewestFirst(rows).map((r) => r.id)).toEqual(['c', 'b', 'a'])
  })

  it('does not mutate its input', () => {
    const rows = [
      { id: 'a', sortKey: 1 },
      { id: 'b', sortKey: 2 },
    ]
    sortNewestFirst(rows)
    expect(rows.map((r) => r.id)).toEqual(['a', 'b'])
  })
})

describe('describeSyncError', () => {
  it('distinguishes a storage failure from a remote failure', () => {
    const storage = new SyncStorageError({ op: 'putAll', store: 'tasks', reason: 'quota' })
    const remote = new SyncRemoteError({ op: 'sessions.fetchDelta', reason: 'offline' })
    expect(describeSyncError(storage)).toContain('store "tasks"')
    expect(describeSyncError(remote)).toContain('offline')
    expect(describeSyncError(storage)).not.toBe(describeSyncError(remote))
  })
})

describe('dev-only diagnostics', () => {
  it('warns once per degraded operation so a silent cache failure stays diagnosable', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await runSyncEffect(boom('offline'), 'sessions.loadDelta')
      expect(warn).toHaveBeenCalledTimes(1)
      expect(String(warn.mock.calls[0]?.[0])).toContain('sessions.loadDelta')
    } finally {
      warn.mockRestore()
    }
  })
})
