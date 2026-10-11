# Claude Code agent support (Phase 1)

Pabrik profiles were HTTP-only: each profile named a `model` + `base_url` +
`api_key` + `url_style` (`openai` | `openai-response` | `anthropic`) and the
workflow POSTed to that endpoint. Claude Code does not fit that shape — it is
a local `claude` CLI authenticated by subscription (`claude login`,
credentials in `~/.claude/`), with its own agentic loop.

Phase 1 models the backend as a fourth `url_style`, `"claude-code"`, so the
entire existing cascade keeps working unchanged:

- `resolveEffectiveProfile` (selected → active → top-level) already cascades
  `url_style` per-field; no new config key was needed.
- Per-session overlays (`users.config_json`, `workspace_settings`) and
  sub-agent inheritance ride the same path.
- HTTP-only fields (`base_url`, `api_key`) are ignored for this style.

## Config shape

```json
{
  "profiles_models": {
    "claude-cli": {
      "model": "sonnet",
      "url_style": "claude-code",
      "thinking": "auto",
      "temperature": "auto"
    }
  },
  "active_profile": "claude-cli"
}
```

- `model`: `sonnet`, `opus`, or a full id like
  `claude-sonnet-4-5-20250929`. Passed as `claude --model <value>`.
- `base_url` / `api_key`: leave empty. Auth comes from `claude login`.
- `url_style`: must be exactly `"claude-code"`.

## What works in Phase 1

- Saving / loading `claude-code` profiles (backend + frontend + overlays).
- Profile Test button: skips the HTTP probe and reports the CLI reminder.
- `zig build test`: `claude_code.zig` (argv builder, stream-json parser,
  validation), `Agent.callStreaming` fail-fast guard, `llmTestValidate`.
- Context-window cascade: `sonnet` / `opus` / `claude-sonnet-4-5-20250929`
  resolve to 200k tokens via `LLMModels`.

## What fails fast (by design)

A `claude-code` profile that reaches `Agent.callStreaming` returns
`error.ClaudeCodeNotWired` with an actionable `last_error_message`
(install the CLI, run `claude login`, or switch back to HTTP). The
workflow surfaces that error through its existing retry path instead of
a confusing `InvalidUri` from the empty `base_url`.

## Roadmap (Phase 2)

- Spawn `claude -p <prompt> --verbose --output-format stream-json
  [--model m] [--add-dir cwd] [--max-turns n]` from the workflow.
- Stream `assistant` deltas into the existing SSE channel; map the
  terminal `{"type":"result"}` line to `CallResponse`.
- Decide tool ownership: Pabrik tools vs CLI tools (likely: CLI owns
  file/bash edits inside `--add-dir`, Pabrik keeps memory/kanban/skills).
- Record CLI usage (tokens/cost) into `llm_history` like HTTP calls.
- Binary discovery + `claude --version` health check in Settings.

## Files

- `src/agentic_loop/claude_code.zig` — style constant, validation, argv
  builder, stream-json parser, not-wired message. Single owner.
- `src/modules/agent/Agent.zig` — `CallError.ClaudeCodeNotWired` +
  `callStreaming` guard + behaviour test.
- `src/modules/agent/LLMModels.zig` — `sonnet` / `opus` /
  `claude-sonnet-4-5-20250929` token entries.
- `src/http_handlers/mod.zig` — `llmTestValidate` + probe bypass + tests.
- `src/apps/desktop/src/components/pabrik/LlmConfigForm.vue` —
  `Claude Code (CLI)` option + hint block.
