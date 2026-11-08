# Android sync — design, conflict policy, and how to test

This document describes the local-first sync layer the Android app is growing toward parity with
the Vue desktop app. It is written for the next agent: what exists, what the rules are, and what is
still missing.

## Pieces

| Piece | Location | Status |
|---|---|---|
| Offline outbox (Room entity + DAO + queue) | `cache/OutboxEntry.kt`, `cache/OutboxDao.kt`, `sync/OutboxQueue.kt` | Done (F02) |
| LWW merge engine | `sync/SyncEngine.kt`, `sync/Syncable.kt` | Done (F03) |
| UTC storage + local rendering | `sync/UtcTime.kt` | Done (F03) |
| Per-feature sync registry | `sync/SyncRegistry.kt` | Done (F64–F71) |
| WorkManager triggers | — | Blocked (F01: dependency unavailable offline) |
| Per-feature outbox/merge wiring | — | Not started |

## Conflict policy

**Last-write-wins by `updatedAt`.** Every syncable entity carries:

- `syncId: String` — stable identity across devices.
- `updatedAtEpochMillis: Long` — the write's timestamp, stored in **UTC**.
- `isDeleted: Boolean` — a tombstone flag.

`SyncEngine.merge(local, remote)` picks the newer copy per id; on an exact tie the **remote** copy
wins (the server is authoritative). Tombstones are dropped from the merged *view* but kept in the
store so a delete can propagate.

`SyncEngine.applyWrite(current, incoming)` is the idempotent write path used when replaying the
outbox: a newer write replaces the stored entity, an equal-or-older write leaves it untouched. That
makes replaying the same outbox entry twice a no-op.

## Deletes

A delete is a **tombstone**, not a row removal:

```kotlin
val tombstone = SyncEngine.delete(entity, nowMillis)
```

The tombstone carries a fresh `updatedAtEpochMillis`, so it wins LWW against any older live copy and
travels to other devices. `SyncEngine.visible(entities)` filters tombstones out for rendering.

## Time

Storage is always UTC epoch millis. Only display converts:

- `UtcTime.format(epochMillis, zone)` — UTC instant rendered in a zone (`yyyy-MM-dd HH:mm`).
- `UtcTime.toUtcMillis(localDateTime, zone)` — a wall clock the user picked, converted to UTC.
- `UtcTime.toLocalDateTime(epochMillis, zone)` — the inverse.

Never store a local wall clock. Never format with the default zone in a test — inject one.

## Outbox

`OutboxQueue` owns persistence and ordering; the network call is a `SyncHandler` supplied per drain.

- `enqueue(...)` writes a `pending` row with a fresh `idempotencyKey`.
- `drain(userId, handler)` replays in `createdAt` order, marking each row `in_flight` first.
- `Success` deletes the row; `Retryable` returns it to `pending` with `retryCount + 1`;
  `Permanent` marks it `failed`.
- `retryFailed(userId)` resets failed rows to `pending`.

`RetryBackoff.delayFor(attempt)` gives the exponential delay (1 s base, 60 s cap) for a retry loop.

## Per-feature registry

`SyncRegistry` lists every feature that syncs, its outbox `entityType`, its merge policy (all LWW),
and whether it supports delete. `SyncRegistry.outboxOperation(isDelete, exists)` maps a local change
to `create` / `update` / `delete`.

## How to run the tests

```bash
cd src/apps/android_mobile
JAVA_HOME=~/.local/jdk17 ./gradlew :app:testDebugUnitTest
```

JDK 17 is required (the system JDK 27 breaks Kotlin 2.0.21).

**Robolectric gotcha:** if `java.io.tmpdir` is a small tmpfs, every Room test fails with
`UnsatisfiedLinkError: ...SQLiteConnectionNatives.nativeOpen`. Point the test JVM at a real disk:

```bash
mkdir -p ~/tmp/robo
JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$HOME/tmp/robo" \
  JAVA_HOME=~/.local/jdk17 ./gradlew :app:testDebugUnitTest
```

## Known limitations

- **No background triggers.** F01 (WorkManager) is blocked: `androidx.work:work-runtime` is not in
  the local Gradle cache and there is no network. Drains are in-process only.
- **No per-feature wiring yet.** The engine, outbox and registry exist; no feature calls them. Each
  feature still needs its own adapter (entity ↔ `Syncable`, outbox enqueue on write, drain on
  resume).
- **No server-side delta endpoint on Android.** The Vue app uses a cache-then-delta cursor model
  (`src/apps/desktop/src/sync/`); Android uses LWW per the parity brief. The two are not
  interchangeable.
- **Tombstone retention is unbounded.** Nothing prunes old tombstones yet; a long-lived install will
  accumulate them.
- **No cross-device clock skew handling.** LWW trusts `updatedAt`; a device with a fast clock wins
  ties it should not.
