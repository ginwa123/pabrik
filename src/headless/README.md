# `pabrik headless` — the backend, with no server and no port

Run the **real** pabrik backend from the command line: the same agentic
loop, the same tools, the same SQLite database and migration chain, the
same `App` singleton — and **no HTTP listener**.

Built for AI agents. An agent that wants to run one turn and read the
result should not have to boot a server, pick a port, poll for readiness
and tear the whole thing down again. Headless mode is one process that
does the work and exits.

```
pabrik headless run "fix the login bug" --cwd ~/myproject
```

## Why not just start the server?

Every other way to drive pabrik — the Vue webapp, `pabrikcli`,
`pabrik-tui`, the functional-test harness — speaks HTTP to a bound
listener. That is right for a human at a browser and wrong for a script:

| | server mode | `headless` |
|---|---|---|
| Port | must pick one, can collide (8081 is the dev server) | none |
| Readiness | poll `/health` until it answers | none — it runs |
| Teardown | signal, drain, join the cron thread | process exits |
| Output | HTML / SSE frames | one JSON object on stdout |

## Commands

### `run` — one agentic turn

```
pabrik headless run <message> [flags]
```

| Flag | Meaning |
|---|---|
| `--session <id>` | Resume an existing session (default: mint a new one) |
| `--cwd <dir>` | Working directory for the turn (default: process cwd) |
| `--profile <name>` | LLM profile from `config.json`'s `profiles_models` |
| `--tools <a,b,c>` | Comma-separated tool allowlist (default: the config default) |
| `--timeout-ms <n>` | Wall-clock budget for the turn (default: no budget) |
| `--quiet` | Print the assistant text only, not the JSON envelope |
| `--json` | Force the JSON envelope even with `--quiet` |

Output — one JSON object, nothing else:

```json
{
  "session_id": "sess_1791635257_392fca6a61e73600",
  "finish_reason": "stop",
  "iterations": 1,
  "timed_out": false,
  "error": null,
  "assistant": "hello from stub"
}
```

Exit code is `0` when the turn produced an assistant reply, `1` when it
timed out, errored, or produced nothing — so `if pabrik headless run …`
works in a shell script without parsing the JSON.

### `sessions` — list recent sessions

```
pabrik headless sessions [--limit N]
```

### `messages` — print one session's messages

```
pabrik headless messages <id> [--limit N]
```

### `usage` — a workspace's token, cache and tool totals

```
pabrik headless usage --workspace <id> [--range 1d|7d|30d|90d]
```

Prints exactly the body `GET /api/workspaces/:workspace_id/usage` returns,
including `totals.reported_input_tokens` and `cache_hit_rate`. `--range`
defaults to the endpoint's own default (`30d`); a range the endpoint
rejects exits non-zero with nothing on stdout.

### `help`

```
pabrik headless help
```

## Global flags

| Flag | Meaning |
|---|---|
| `--log-file <path>` | Where diagnostics go (default: `$TMPDIR/agentic_coding.log`) |

Diagnostics never touch stdout. That is the whole point: stdout is the
machine-readable channel, and a log line in the middle of a JSON object
breaks every parser that reads it.

## One code path, not two

**Headless mode contains no second implementation of the backend.** That
is the design rule, and it is worth being concrete about what it buys.

`headless run` calls `sessionCreateUseCase` — the exact `useCase` behind
`POST /api/llm/session`. That function:

1. resolves the cwd (explicit → per-task → kanban → sandbox → TMPDIR),
   including the relative-path join and the absoluteness invariant
2. snapshots the active profile into the session row
3. abandons a pending `ask_user` question so the model cannot guess
4. expands `/skill-<name>` slash tokens
5. upserts the session row
6. calls `App.emit_run_agent`, which schedules the turn on
   `group_emit_session_create` and emits `RunParamsNew`

`boot` installs the `ai_worker_flow` subscriber — the same one
`main.zig:219` installs — so that emit reaches
`CallbackAiWorkerFlow.callback` → `runAgenticMultiStepnew`. The tool
registry, prompt builder, retry policy, compaction and sub-agent
spawning are all the production paths, because it *is* the production
path.

An earlier draft of this feature re-implemented steps 1, 2 and 5 by hand
and drove `runAgenticMultiStepnew` directly. That was a bug twice over: it
would have run **two** turns for one message, and the hand-rolled SQL
would have drifted from `App.insert_worker` on the next schema change.
Both are gone.

### What headless mode adds

Exactly one thing the HTTP path does not need: a way to **wait** for the
turn and read its result. `emit_run_agent` is fire-and-forget — the
handler returns as soon as the work is scheduled. A CLI that printed
nothing would be useless, so `run` subscribes to the completion signal
the loop already emits (`llm_full` with `finish_reason: stop`) and blocks
on it, bounded by `--timeout-ms`.

That is the whole addition. Everything else is borrowed.

### The one thing that is not real

`App.server` is a `*gserverz.GinwaServer` with no optional. Three call
sites dereference it (`web_status`, `shutdown`, `unified_events_sse`) and
all three are HTTP handlers headless mode never reaches. Rather than
widen the field to optional — which would push a null check into every
one of those handlers — headless mode constructs a real `GinwaServer`
**without binding it**. `init` allocates the struct, the router, the SSE
manager and the cronjob manager; nothing listens, so nothing can connect.

That is not a stub. It is the same object the server uses, in its
pre-listen state.

## Layout

```
src/headless/
├── mod.zig        module surface + the `Command` union
├── args.zig       argv parsing — pure, unit-tested without booting
├── boot.zig       the backend boot sequence (no server, no port)
├── run.zig        `headless run` — one agentic turn
├── sessions.zig   `headless sessions` / `headless messages`
├── usage.zig      `headless usage` — the workspace usage payload
└── README.md      this file

src/boot/headless_dispatch.zig   argv[1] == "headless" → dispatch
```

`args.zig` is pure for the same reason `src/cli_args.zig` is: parsing
must be complete and unit-testable **before** any subsystem starts.
`LlmConfig.init` starts the routine scheduler on a background thread, so
an error returned after that point exits the process while the thread is
mid-query — which segfaults and buries the real message in a crash dump.

## How completion is detected

The loop writes every assistant message through
`insertLLMHistories(..., .is_emit_sse = true)`, which emits an `SseEvent`
on the event bus under the session id and under `"llm"`. `run` subscribes
to both keys **before** starting the turn and watches for an assistant
row whose `finish_reason` is `stop`.

This is the same signal the frontend renders from, so a headless run and
a browser run agree on when a turn is over.

## Why the process exits instead of unwinding

`boot` submits the routine scheduler onto
`ctx.group_emit_session_create`. That task holds `*ctx` and
`&db_handles.db` for the life of the process. Freeing either while it
sleeps between ticks is a use-after-free.

`main.zig` never unwinds for the same reason — see the `cli_args.zig`
header. Headless mode takes the same route: `Backend.finish(code)` calls
`std.process.exit`. WAL mode replays uncheckpointed frames on the next
boot, so nothing committed is lost.

## Testing

```bash
zig build install:linux
HOME=/tmp/some-isolated-dir ./zig-out/bin/pabrikcore-linux-x86_64 headless help
```

Point `HOME` at a scratch directory so you never touch the real
`agent.db`. The functional suite covers this end-to-end — see
`tests/functional/headless_*_test.zig`.
