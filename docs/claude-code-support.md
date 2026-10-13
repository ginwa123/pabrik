# Claude Code agent support (Phase 1)

Pabrik profiles have always been HTTP-only: a profile names a `model`, a
`base_url`, an `api_key` and a `url_style` (the HTTP **body shape**), and the
workflow POSTs to that endpoint. Claude Code does not fit that shape — it is a
local `claude` CLI authenticated by subscription (`claude login`, state under
`~/.claude/`), and it owns its own agentic loop.

## The seam: `backend`, orthogonal to `url_style`

The transport lives in its **own** profile field, `backend`:

| field | answers | values |
|---|---|---|
| `backend` | *which transport runs this call* | `"http"` (default), `"claude-code"` |
| `url_style` | *what HTTP body shape* | `"openai"`, `"openai-response"`, `"anthropic"` |

An earlier revision of this work put `"claude-code"` into `url_style`. That was
wrong, and worth recording why:

- `url_style` is read by `buildJson*Request` and the SSE parsers — a non-HTTP
  value forces a "not applicable" arm into each of those dispatch sites.
- `base_url` / `api_key` would stay in the struct but silently do nothing for
  that profile: the same dead-field ambiguity that makes per-profile
  credentials hard to reason about.
- It does not scale. The next external agent (Codex, Gemini CLI) would need
  another bogus `url_style` value.

With `backend`, `base_url` on a `claude-code` profile is a **validation
error**, not a silently-ignored field — strictly better than a value that
means two things.

## Config shape

```json
{
  "profiles_models": {
    "claude-work": {
      "backend": "claude-code",
      "model": "sonnet",
      "config_dir": "~/.claude-work",
      "max_turns": 40
    },
    "team-gateway": {
      "backend": "http",
      "url_style": "anthropic",
      "model": "claude-sonnet-4-5-20250929",
      "base_url": "https://gateway.corp.example.com",
      "api_key": "<workspace-secret placeholder>"
    }
  }
}
```

- **`backend`**: omit it and you get `"http"` — every existing config parses
  byte-identically, so there is nothing to migrate.
- **`model`** (claude-code): `sonnet`, `opus`, or a full
  `claude-sonnet-4-5-20250929`. Passed as `claude --model <value>`.
- **`config_dir`** (claude-code): maps to `CLAUDE_CONFIG_DIR`. This is how
  **per-profile identity works without an API key** — two profiles pointing at
  two directories are two different `claude login` sessions.
- **`max_turns`** (claude-code): the agentic turn ceiling (`--max-turns`).
- **`base_url` / `api_key` / `url_style`**: HTTP only. Not required for
  claude-code (auth comes from the CLI's own login), and rejected by validation
  if a claude-code profile sets them.

For an HTTP gateway token, use a workspace secret rather than a literal
credential: the double-braced `SECRETS:` placeholder documented in AGENTS.md
resolves per workspace at spawn time, so the plaintext never lands in
`config.json` or `users.config_json`.

Sub-agents follow the same shape: `SubAgentConfig.backend` empty = inherit the
parent profile's transport, and `config_dir` / `max_turns` inherit the same way.

## What works in Phase 1

- Saving / loading `claude-code` profiles (backend parser, per-session
  overlays, sub-agent inheritance, clone/deinit).
- **A real Test probe.** The Settings Test button dispatches on `backend`: an
  HTTP profile gets a POST, and a CLI profile runs `claude --version` through
  `helpers.run_captured`. That catches "not installed" and "installed but
  broken", which a config-shape check cannot.
- Backend-aware validation: `LlmConfig.validate()` requires
  `api_key` / `base_url` only for `http`, so a CLI-only config boots clean.
- Context-window cascade: `sonnet` / `opus` / `claude-sonnet-4-5-20250929`
  resolve to 200k tokens via `LLMModels`.
- Frontend: a **Backend** selector gates the field sets — HTTP shows base URL /
  API key / wire style, claude-code shows `config_dir` / `max_turns`.

## What fails fast (by design)

A `claude-code` profile reaching `Agent.callStreaming` returns
`error.ClaudeCodeNotWired` with an actionable `last_error_message` (install the
CLI, run `claude login`, or set the backend back to `http`). The workflow
surfaces that through its existing retry path instead of a confusing
`InvalidUri` from the empty `base_url`.

## Roadmap (Phase 2)

1. **Credentials per profile.** The three CLI auth modes — subscription
   (`claude login` state), API key (`ANTHROPIC_API_KEY`), and gateway
   (`ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL`) — belong to a per-profile
   `auth_mode`, mapped to the child's environment. Keys never go on argv: argv
   is world-readable via `ps`.
2. **An env allowlist per spawn.** If the `pabrik` server itself runs with
   `ANTHROPIC_API_KEY` exported, a subscription profile's child would inherit
   it and bill the wrong account. Each spawn must unset every `ANTHROPIC_*` the
   profile did not ask for. `buildEnvOverlay` is the seam;
   `run_captured.Options` needs an `env` field to carry it.
3. **Construction-time backend gating.** The not-wired failure belongs where
   the backend is built, not mid-call.
4. **The spawn + stream.** `claude -p <prompt> --verbose --output-format
   stream-json [--model m] [--add-dir cwd] [--max-turns n]`, assistant deltas
   forwarded to the existing SSE channel, the terminal
   `{"type":"result"}` line mapped to `CallResponse`.
5. **Tool ownership.** Likely: the CLI owns file/bash edits inside `--add-dir`;
   Pabrik keeps memory / kanban / skills.
6. **Usage ledger.** Record CLI tokens/cost into `llm_history` like HTTP calls.

## Files

- `src/agentic_loop/claude_code.zig` — backend predicates, profile validation,
  `claude -p` argv builder, `CLAUDE_CONFIG_DIR` env overlay, `--version` probe
  argv + interpretation, stream-json line parser. Single owner.
- `src/modules/config/Config.zig` — `Backend` constants, `backend` /
  `config_dir` / `max_turns` on `LlmProfile` / `SubAgentConfig` /
  `ProfileJson` / `SubAgentJson` / `ResolvedSubAgent` / `EffectiveProfile`,
  backend-aware `validate`, `effectiveBackend()`.
- `src/modules/agent/Agent.zig` — `backend` field,
  `CallError.ClaudeCodeNotWired`, `callStreaming` guard.
- `src/modules/agent/LLMModels.zig` — `sonnet` / `opus` /
  `claude-sonnet-4-5-20250929` token entries.
- `src/agentic_loop/workflow.zig` — threads `eff.backend` into the naming call,
  the streaming call, and `SubAgentOverrides`.
- `src/http_handlers/mod.zig` — `backend` on the Test request, backend-aware
  validation, the real `claude --version` probe.
- `src/apps/desktop/src/components/pabrik/LlmConfigForm.vue` — Backend
  selector + backend-gated field sets.
