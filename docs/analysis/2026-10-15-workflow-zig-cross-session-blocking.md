# Is `workflow.zig` blocking? — cross-session blocking audit

**Task:** `task_1792076614092_0` — "Is there a posiblity in workflow.zig blocking ?"
**Clarified question:** "blocking mean if one session blocking it will block the other session that running parallel too?"
**Date:** 2026-10-15 · **Audited rev:** `711979279` (main)

---

## TL;DR

**Yes, but not from `workflow.zig` itself.**

`src/agentic_loop/workflow.zig` contains **no** lock, `Thread`, `sleep`, `wait` or
mutex of its own — a grep for every blocking primitive finds exactly one match,
and it is a *comment* (`workflow.zig:1501`). Every block it can hit is a **call it
makes**, and the loop body runs on **its own OS thread**, so a slow LLM, a slow
tool, a `retryDelayMs` sleep or a long DB write in session A does **not** stall
session B's loop.

Cross-session blocking is real, but it lives in **four shared singletons** the
loop calls into. Ranked by how bad they can get:

| # | Shared resource | Held across | Worst case for another session | Bounded? |
|---|---|---|---|---|
| 1 | MCP stdio child lease (`mcp_stdio.zig`) | whole `tools/call` (send **+** recv) | **unbounded** — waits forever, cancel can't reach it | ❌ **no** |
| 2 | SSE manager (`kabelweb/sse_manager.zig`) | a blocking socket write | 5 s per stalled peer, once, then peer is dropped | ✅ 5 s |
| 3 | SQLite write connection | one statement | up to `busy_timeout` = 15 s | ✅ 15 s |
| 4 | Global logger | a write to `stderr` | unbounded if `stderr` is an undrained pipe | ⚠️ dev only |

Finding **#1 is a bug**, not a design trade-off: the lease API has a wait budget
and a cancel hook, the production call site passes neither, and the cancel
contract is asserted by a test in the same file that production violates.

---

## 1. The execution model — why sessions are *mostly* isolated

One session = one dedicated OS thread. Chain:

1. `src/http_handlers/session_create.zig:327` (or `start_agent.zig:99`,
   `kanban_tasks_create.zig:244`) → `App.emit_run_agent` (`src/app.zig:99`).
2. `src/app.zig:146` → `self.group_emit_session_create.concurrent(self.io, run, …)`.
   `concurrent` **returns as soon as the task is queued**; the HTTP handler does
   not wait for the run.
3. `std.Io.Threaded`'s `concurrent` vtable (`/usr/lib/zig/std/Io/Threaded.zig:2130`)
   spawns a **detached OS thread per call** (`Thread.spawn` at `:2164`), because
   the runtime's `concurrent_limit` defaults to `.unlimited`
   (`Threaded.zig:1592`; the app's Io comes from `std/start.zig:724` with `.{…}`
   defaults, and no build flag sets `single_threaded`).
4. That thread runs `CallbackAiWorkerFlow.callback` (`workflow.zig:119`) →
   `runAgenticMultiStepnew` (`workflow.zig:505`), including the `while (true)`
   loop. Sub-agent batches get their own extra threads the same way
   (`sub_agent_batch.zig:441`/`480`).

So the loop's own blocking work is private to the session:
`agent.callStreaming` (LLM HTTP), `handle_tool` (`workflow.zig:1434`), the
blocking `nanosleep`/`Sleep` in `retryDelayMs` (`retry_delay_ms.zig:22-38`,
called at `workflow.zig:1032/1272/1505`), `insertLLMHistories`
(`workflow.zig:882/1015/1066/1358/1736`) — thread-local cost only.

**Verified empirically** (appendix A, run against the same default runtime the
server boots with):

```
claim1 isolation: fast loop done in 101ms while the sibling is blocked for 2000ms (both finished at 2007ms)
```

### The mechanism that turns any shared lock into cross-session blocking

`EventBus.emit` is deliberately **synchronous and unlocked** — it calls the
subscriber on the caller's thread:

```zig
// src/modules/event_bus/src/event.zig:47
pub fn emit(self: *Self, comptime T: type, id: []const u8, data: T) void {
    // Deliberately unlocked: emit runs on the caller's thread and the …
    if (self.listeners.get(id)) |cb| { … typed_fn(data); }
}
```

Every SSE frame the loop emits therefore runs **inline on that session's loop
thread**, inside whatever lock the subscriber takes. That is why a stall in one
subscriber (a socket, a pipe) can be a stall for every session — see §2.2.

---

## 2. The cross-session blocking inventory

### 2.1 ❌ MCP stdio lease — unbounded, cancel-proof (worst finding)

`tools/call` over the **stdio** transport takes a per-server exclusive lease for
the whole request/response transaction:

```zig
// src/agentic_loop/handle_mcp_tool.zig:86
const deadline_ns: u64 = 60 * std.time.ns_per_s;      // tools/call budget
…
// src/agentic_loop/handle_mcp_tool.zig:241
var lease = reg.acquire(server_name, argv, .{}) catch |err| { … };
…
// src/agentic_loop/handle_mcp_tool.zig:268
const r = client.recv(deadline_ns, null) catch |err| { … };   // up to 3 attempts
```

`acquire(…, .{})` passes `AcquireOptions{}` → `wait_ns = 0` and
`is_cancelled = null` (`mcp_stdio.zig:563-566`). `tryLockUntil` reads `0` as
**"wait forever"**:

```zig
// src/modules/agent/mcp/mcp/mcp_stdio.zig:509-535
fn tryLockUntil(io, m, wait_ns, is_cancelled) bool {
    if (m.tryLock()) return true;
    const has_deadline = wait_ns != 0;
    while (true) {
        if (is_cancelled) |cb| if (cb()) return false;   // null here ⇒ never
        if (has_deadline) { … } else {                   // 0 ⇒ 2 ms poll, forever
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(2), … }, io) catch return m.tryLock();
        }
        if (m.tryLock()) return true;
    }
}
```

The lease is held across `sendNDJSON` **and** `recv`, and the *send* has no
deadline at all:

```zig
// mcp_stdio.zig:396 → 290-301 — no deadline, no cancel
pub fn sendNDJSON(self: *StdioClient, body: []const u8) !void { … try writeNDJSON(…) }
fn writeNDJSON(io, file, body) !void { … try std.Io.File.writeStreamingAll(file, io, …); }
```

Consequence, with two parallel sessions both using the MCP server `X`:

* **A** runs `mcp_X_*`; the child wedges (or simply stops reading stdin) →
  `sendNDJSON`/`recv` parks A's loop thread (recv ≤ 60 s × up to 3 attempts).
* **B** runs any `mcp_X_*` tool → `acquire` spins a 2 ms sleep loop **forever**.
  No deadline, no `isWorkerCancelled` consult, no cancel thunk — B's **Stop
  button cannot break it**. B's session is frozen until A's call finishes (or the
  child dies), even though B itself is a healthy, unrelated session.
* This serialises MCP tools *by design for one server* (one child per server for
  the whole process — `StdioRegistry`, `mcp_stdio.zig:569`), but the wait is the
  problem, not the serialisation.

The file's own tests state the intended contract — and production does not meet
it:

```zig
// src/modules/agent/mcp/mcp/mcp_stdio.zig:1642
test "acquire honours is_cancelled under contention without respawning the cached child" {
    // The Stop button has to reach the lease wait too: a user who cancels
    // while another session is mid-transaction must not be pinned for the
    // rest of the (tens of seconds long) wait budget.
```

`add_mcp_server.zig:1103` has the same `.{}` call — same hazard on the
config-save path (that one is HTTP-triggered, not agent-triggered).

**Fix:** pass a real budget and the loop's cancel thunk, mirroring the existing
`McpCancelCtx`/`llm_cancel_thunk` pattern (`workflow.zig:350-362`, `:387-431`):

```zig
var lease = reg.acquire(server_name, argv, .{
    .wait_ns = 60 * std.time.ns_per_s,      // same budget as the call itself
    .is_cancelled = cancelThunkFor(copy_session_id),  // isWorkerCancelled(session) + Stop
}) catch |err| { … };
```

and give `sendNDJSON` a deadline (`writeFramed` already has the machinery —
`mcp_stdio.zig:304-336`; `writeNDJSON` at `:290` bypasses it).

### 2.2 ⚠️ SSE emit — bounded at 5 s, but held across the manager lock

SSE frames are emitted from the loop thread on **every streamed chunk**:

```
workflow.zig:1917  on_event_sent.sendStreamChunkContent(…)   // + :1933, :1945
  → on_event_sent.zig:559-563   event_bus.emit(SseEvent, session_id, …)
                                event_bus.emit(SseEvent, "llm", …)   // central broadcast
  → unified_events_sse.zig:11    forwardToClients("llm", data)
  → unified_events_sse.zig:47    server.sse_manager.sendToClient(client_id, …)
  → sse_manager.zig:807          self.lock.lock(io)          // manager lock taken (817)
  → sse_manager.zig:833          writeChunkedFrame(...)      // BLOCKING write, lock held
```

`kabelweb/src/server/sse_manager.zig` names this exact chain in the comment above
`SSE_SEND_TIMEOUT_MS` (`:1037-1059`): *"SSE emits are SYNCHRONOUS: `event_bus.emit`
runs the forwarding callback on the CALLER's thread, which for `llm_chunk` is the
agent workflow thread. With an unbounded blocking `send()` on a peer that has
stopped reading … ONE dead client parks that thread while holding the manager
lock — so every other SSE emit in the process queues behind it."*

Current state: the hazard was **fixed at the socket level** — every registered
SSE fd gets `SO_SNDTIMEO = 5_000 ms` (`sse_manager.zig:257` via
`setFdSendTimeout`, `:1078`, `:1059`), so a stalled peer is dropped instead of
parking the writer forever. Regression-tested at `sse_manager.zig:3782`
("`setFdSendTimeout` bounds a write to a peer that never reads").

So today: one stalled browser client can delay **every** session's chunk delivery
(and, because the emitter is the loop thread, every session's loop) by **≈5 s,
once** — after the failed write the client is removed and later emits skip it.
Before that fix this was an unbounded, cascading stall (it aborted in-flight LLM
streams with `WriteError`).

Note the "llm" key is a **broadcast**: every chunk is written to *every* client
registered under `llm` (the frontend filters by `session_id` client-side), so the
cost is `O(clients)` blocking writes per chunk on the emitting session's thread.

### 2.3 ⚠️ SQLite — one writer, one mutex, 15 s busy timeout

All sessions share one write connection guarded by one mutex:

```zig
// databases-…/src/sqlite/Sqlite.zig:1296-1297
pub fn exec(self, allocator, sql, argv) Error!void {
    try self.mutex.lock(self.io);
```

Policy (`src/boot/db_config.zig:5-20`): WAL, `busy_timeout_ms = 15_000`,
`synchronous = .full`, **elastic reader pool** (`read_conns = 1` warm floor,
`max_read_conns = 0` = unlimited) — reads deliberately never queue behind a
reader (`Sqlite.zig:61-119`), and a reader only falls back to the write
connection after `reader_wait_ms = 5_000`.

So: reads are effectively non-blocking for other sessions; **writes serialise**,
bounded by `busy_timeout` (15 s). `insertLLMHistories` + `updateWorker` run
several times per loop iteration in every session, so this is the most
frequently-contended shared resource — but it is bounded and by design. There is
no long-lived transaction in the loop (`workflow.zig` never calls `db.begin`;
the only `begin`s in `agentic_loop/` are `design_model.zig` and `skills_store.zig`).

### 2.4 ⚠️ Global logger — one mutex, held across the write

```zig
// src/modules/logger/Logger.zig:294-324
self.mutex.lockUncancelable(self.io);
defer self.mutex.unlock(self.io);
… // file write / rotation
try std.Io.File.writeStreamingAll(std.Io.File.stderr(), self.io, output);
```

Every session logs through this one instance (CHECKPOINT lines, MCP traces — many
per iteration). A blocking write to `stderr`/log file therefore stalls *every*
logging thread while holding the mutex. In the shipped desktop path this is
dormant: the desktop app spawns the backend with `.stdout = .ignore`, `.stderr =
.ignore` (`src/apps/desktop_app/subprocess.zig:300-305`) → writes go to the null
device. It is live in dev/terminal runs: a stopped terminal (Ctrl+S) or a
saturated log filesystem blocks fd 2 and with it *all* sessions — unbounded.
Low priority on this box's normal usage, but it is a genuine global stall vector.

### 2.5 ℹ️ MCP tools cache — spinlock, short critical section

`App.isMcpToolsInit/getMcpToolsCached/storeMcpToolsCache/clearMcpToolsCache`
(`src/app.zig:275-320`) all take a **spinlock** (`std.atomic.Mutex`, `:627`) around
a deep-copy/free of the tool list — microseconds of memory work, microseconds of
spinning. Not a stall source today, but it is a spinlock (a descheduled holder
burns CPU in every other session's loop), so it should never be widened to
include I/O. The expensive fan-out (`fetchMcpToolsFresh`, `workflow.zig:713`/`763`)
is correctly done *outside* the lock.

Worth knowing: if that fetch fails, `mark_init=false` keeps the cache
uninitialised, so **every** session re-pays the full MCP `tools/list` fan-out
*every loop iteration* while a server is down — a shared, self-inflicted
slowdown of every parallel session (bounded per server by its own budget, but
multiplied by session count).

### 2.6 ℹ️ `emit_run_agent` is fire-and-forget

The HTTP layer never waits for a run: the handler spawns the session task and
returns. So the HTTP worker pool (`kabelweb/src/server/worker_pool.zig:22-30`:
`cpu_count` threads, `queue_depth = 1024`, `submit` never blocks) is **not**
consumed by agent runs — a long turn does not cup the API's capacity.

---

## 3. What does *not* block another session (avoid misdiagnosis)

* `retryDelayMs` backoff (`workflow.zig:1032/1272/1505` → `retry_delay_ms.zig`)
  — a real blocking `nanosleep`/`Sleep`, but on the session's own thread.
* A hung LLM HTTP call — same: the session's own thread + its own curl client.
* `handle_tool` / `bash` / `command` subprocess waits — session-local.
* `ask_user` — deliberately non-blocking by design
  (`ask_user_pending.zig:1-2`: *"the `ask_user` tool does NOT block the agentic
  loop"*); the loop ends the turn and the answer path resumes the session.
* `getSingleton()` — a bare global pointer read, no lock (`src/app.zig:18`).
* Sub-agent fan-out (`sub_agent_batch.zig:441-480`) — extra threads, same
  isolation; `concurrent` is unlimited, so B is never queued behind A *at the
  runtime level*. (Unbounded thread growth is a resource question, not a
  blocking one: N sessions = N freshly spawned 16 MiB-stack threads.)

---

## 4. Reproduce / confirm on a live box

* **Find a frozen session whose neighbour is healthy:** look for a loop thread
  parked in `tryLockUntil`'s 2 ms sleep loop. With `gdb`/`eu-stack`, the stack is
  `StdioRegistry.acquire → tryLockUntil → std.Io.Clock.Duration.sleep`; the
  holding thread is in `mcp_stdio.recv`/`writeNDJSON`. A `Stop` click that does
  nothing while the thread sits there is the signature of finding #1.
* **SSE variant:** one browser tab whose socket has unread bytes makes other
  tabs' streams stutter in ~5 s steps (the `SO_SNDTIMEO` bound), with
  `sendToClient write FAILED` / `remove … reason=send_to_client_failed` in the log.
* **Probe (appendix A)** proves the isolation/serialisation split in ~4 s:

  ```
  cd /tmp/pabrik-blocking-probe && zig run blocking_probe.zig
  ```

---

## 5. Recommended order of work

1. **Fix the MCP lease wait (finding §2.1)** — pass
   `.{ .wait_ns = <budget>, .is_cancelled = <session cancel thunk> }` at
   `handle_mcp_tool.zig:241` (and `add_mcp_server.zig:1103`), and give
   `writeNDJSON` (`mcp_stdio.zig:290`) a deadline so the *send* half of the
   transaction cannot hold the lease forever either. Add a regression test: a
   stub MCP child that never reads stdin + two sessions on one server ⇒ the
   second `acquire` returns `LeaseTimeout` **within the budget** and is
   cancellable, instead of hanging. Test infra already exists for exactly this
   ("`acquire honours is_cancelled under contention …`", `mcp_stdio.zig:1642`).
2. **Make `forwardToClients` unable to block the loop** (`unified_events_sse.zig:11`)
   — per-client outbound queue drained by the existing SSE loops, so an emit is
   enqueue-only. That removes the last "loop thread inside a shared lock" hop and
   makes §2.2 a latency-only concern.
3. **Optional:** bound `writeStreamingAll` to fd 2 (`Logger.zig:323`) or make the
   global logger never block on the sink (§2.4); and stop masking a failed MCP
   tools fetch as "retry forever per iteration" (§2.5).

Only #1 is a defect with a clear correctness smell (an unbounded,
uncancellable wait contradicting a test in the same module). #2 and #3 are
hardening.

---

## Appendix A — probe used for the empirical claims

Run: `zig run blocking_probe.zig` (Zig 0.16.0, no build file). It uses the exact
runtime the server boots with (`std.process.Init.io`, i.e. the default
`std.Io.Threaded`), so claim 1 is measured on production scheduling.

```zig
const std = @import("std");

const BLOCK_MS: i64 = 2_000;

var shared_mutex: std.Io.Mutex = .init;

fn sleepMs(io: std.Io, ms: i64) void {
    std.Io.Clock.Duration.sleep(
        .{ .raw = std.Io.Duration.fromMilliseconds(ms), .clock = .real },
        io,
    ) catch {};
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

// Task A: takes the shared lock and blocks "in a socket write" for BLOCK_MS.
fn holder(io: std.Io, report: *std.atomic.Value(i64)) void {
    shared_mutex.lockUncancelable(io);
    defer shared_mutex.unlock(io);
    const t0 = nowNs(io);
    sleepMs(io, BLOCK_MS);
    report.store(@intCast(nowNs(io) - t0), .release);
}

// Task B: does a trivial unit of work, but needs the same shared lock.
fn waiter(io: std.Io, delay_ms: i64, waited: *std.atomic.Value(i64), ran: *std.atomic.Value(i64)) void {
    sleepMs(io, delay_ms);
    const t0 = nowNs(io);
    shared_mutex.lockUncancelable(io);
    defer shared_mutex.unlock(io);
    waited.store(@intCast(nowNs(io) - t0), .release);
    ran.store(1, .release);
}

// A loop body that blocks and never touches the shared lock.
fn isolatedLoop(io: std.Io, ms: i64, done: *std.atomic.Value(i64)) void {
    sleepMs(io, ms);
    done.store(1, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // ─── Claim 1: two concurrent loops, one blocking ────────────────────
    var slow_done: std.atomic.Value(i64) = .init(0);
    var fast_done: std.atomic.Value(i64) = .init(0);

    var g1: std.Io.Group = .init;
    const t_start = nowNs(io);
    try g1.concurrent(io, isolatedLoop, .{ io, BLOCK_MS, &slow_done });
    try g1.concurrent(io, isolatedLoop, .{ io, 100, &fast_done });
    while (fast_done.load(.acquire) == 0) sleepMs(io, 10);
    const fast_ms = @divTrunc(nowNs(io) - t_start, std.time.ns_per_ms);
    while (slow_done.load(.acquire) == 0) sleepMs(io, 10);
    const slow_ms = @divTrunc(nowNs(io) - t_start, std.time.ns_per_ms);
    std.debug.print(
        "claim1 isolation: fast loop done in {d}ms while the sibling is blocked for {d}ms (both finished at {d}ms)\n",
        .{ fast_ms, BLOCK_MS, slow_ms },
    );

    // ─── Claim 2: a shared lock held across a blocking wait ─────────────
    var hold_ms: std.atomic.Value(i64) = .init(0);
    var waited_ms: std.atomic.Value(i64) = .init(0);
    var ran = std.atomic.Value(i64).init(0);

    var g2: std.Io.Group = .init;
    try g2.concurrent(io, holder, .{ io, &hold_ms });
    try g2.concurrent(io, waiter, .{ io, 50, &waited_ms, &ran }); // asks for the lock 50ms in
    while (ran.load(.acquire) == 0) sleepMs(io, 10);
    const held_ms = @divTrunc(hold_ms.load(.acquire), std.time.ns_per_ms);
    const waited_for_ms = @divTrunc(waited_ms.load(.acquire), std.time.ns_per_ms);
    std.debug.print(
        "claim2 shared lock: holder blocked {d}ms while holding the lock; the sibling task waited {d}ms for that same lock\n",
        .{ held_ms, waited_for_ms },
    );
}
```

Observed (2026-10-15, 8-core Linux, Zig 0.16.0):

```
claim1 isolation: fast loop done in 101ms while the sibling is blocked for 2000ms (both finished at 2007ms)
claim2 shared lock: holder blocked 2000ms while holding the lock; the sibling task waited 1950ms for that same lock
```

Claim 1 is the answer to "does session A's slow work stall session B?" — **no, not
by itself**. Claim 2 is the answer to "can it, through a shared lock?" — **yes,
for the full duration of the wait**, which is what findings §2.1–§2.3 are about.

---

## Appendix B — evidence commands

```bash
# The loop holds no blocking primitive of its own (one comment hit only):
rg -n 'sleep|nanosleep|\.lock\(\)|\.wait\(\)|\.join\(\)|Thread\.spawn|Mutex|Condition' \
   src/agentic_loop/workflow.zig

# Emission is synchronous on the caller's thread:
sed -n '47,56p' src/modules/event_bus/src/event.zig

# One session = one OS thread:
sed -n '140,150p' src/app.zig
sed -n '2130,2170p' /usr/lib/zig/std/Io/Threaded.zig

# MCP lease: production passes no budget and no cancel:
sed -n '241p;268p' src/agentic_loop/handle_mcp_tool.zig
sed -n '505,535p;561,566p' src/modules/agent/mcp/mcp/mcp_stdio.zig

# SSE lock held across the socket write + the 5s socket bound:
sed -n '807,835p;1047,1078p' /home/ginwa/kabelweb/src/server/sse_manager.zig

# SQLite: one write mutex, elastic readers, 15s busy timeout:
sed -n '1296,1300p' ~/.cache/../../pabrik/zig-pkg/databases-*/src/sqlite/Sqlite.zig
sed -n '1,25p' src/boot/db_config.zig
```
