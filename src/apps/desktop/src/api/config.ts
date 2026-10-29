import { API_BASE, apiFetch } from './core'

// Pabrik Config API
export interface PabrikAgent {
  model?: string
  base_url?: string
  thinking?: string
  temperature?: string
  url_style?: string
  api_key?: string
  /** The agent's persona. Injected into a spawned child's system prompt as its
   * `## Your Active Agent Configuration` block. */
  system_prompt?: string
  /** Which TRANSPORT runs this profile's calls: `"http"` (default), `"claude-code"` (the local
   * `claude` CLI, subscription auth via `claude login`), or `"opencode"` (the local `opencode` CLI,
   * auth via `opencode login`). Mirrors the backend's `LlmProfile.backend`. */
  backend?: string
  /**    * Claude Code only: `CLAUDE_CONFIG_DIR` for this profile. Two profiles pointing at two
   * directories are two different `claude login` sessions — the way per-profile identity works when
   * there is no API key. Mirrors `LlmProfile.config_dir`. Null = CLI default (`~/.claude`). */
  config_dir?: string | null
  /** Claude Code only: agentic turn ceiling passed as `--max-turns`.
   * Mirrors `LlmProfile.max_turns`. Null = the CLI's own default. */
  max_turns?: number | null
  /** Optional override for this profile's context window (in tokens). When null (or omitted), the
   * backend's built-in per-model default is used (e.g. 200_000 for MiniMax-M2.7, 500_000 for
   * MiniMax-M3, 200_000 fallback). Useful for self-hosted models with a non-standard window. */
  max_capacity_tokens?: number | null
  /** Compaction threshold as a percentage (0-100) of this profile's context window. When null (or
   * omitted), defaults to 80. Out-of-range values are rejected by the backend with
   * `error.InvalidThresholdPercent`. */
  compaction_threshold_percent?: number | null
  /** Anthropic-only override for `thinking.budget_tokens`. Plan 2026-08-23-model-thinking. Mirrors
   * `LlmProfile.thinking_budget_tokens`. Hidden when `thinking === "off"`. Range (0, 2_000_000]
   * enforced server-side. */
  thinking_budget_tokens?: number | null
  /**    * OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). Plan 2026-08-23-model-thinking.
   * Mirrors `LlmProfile.reasoning_effort`. Hidden when `thinking === "off"`. Server-side validation
   * via `parse_thinking.parseReasoningEffort` (low|medium|high|auto). */
  reasoning_effort?: 'low' | 'medium' | 'high' | 'auto' | null
  /** False = the agent is switched off: `list_agents` does not offer it, `spawn_sub_agent` cannot
   * run it, and the agent pickers hide it. Absent/true = enabled (every old config keeps working). */
  enabled?: boolean
}

export interface McpHeader {
  key: string
  value: string
}

export interface McpServer {
  name: string
  /**    * Transport discriminator. Defaults to 'http' on legacy entries that predate this field. Mutually
   * exclusive with itself — a server is either HTTP or stdio, never both. */
  transport?: 'http' | 'stdio'
  /** HTTP transport — required when transport === 'http'. */
  url?: string
  /** Optional list of HTTP headers to send with MCP requests (e.g. API keys). */
  headers?: McpHeader[]
  /**    * stdio transport — required when transport === 'stdio'. The command (executable name or absolute
   * path) the agent will spawn as a child process and talk MCP JSON-RPC to. */
  command?: string
  /** stdio transport — argv (excluding argv[0]). One entry per line in the UI. */
  args?: string[]
  /**    * stdio transport — "KEY=VALUE" per line, ADDED on top of inherited env. v1 limitation: Zig
   * 0.16's std.process.Child has no clean .env_map setter, so a custom env requires a
   * pre-fork+execve helper — not in v1. The UI exposes this for documentation + forward-compat. */
  env?: string[]
  /** stdio transport — optional child working directory (absolute path). */
  cwd?: string
  /**    * When false the agent skips this server (no tools listed, no calls). Missing/undefined renders
   * as enabled. Omitted on the wire when enabled so legacy configs stay clean. */
  enabled?: boolean
}

/** One entry of the top-level `web_search` map in `config.json` — the wire shape of a single
 * web-search provider. The map key is the provider name the agent passes to `web_search`; the agent
 * discovers the names through `list_web_search_providers`. */
export interface PabrikWebSearchProvider {
  /** Host pin. The ONLY host whose requests may carry `key`. Must be
   *  `https` and must not name a loopback, private or link-local host. */
  url: string
  /** Credential, stored separately from `curl` so nothing derived from
   *  the template can leak it. Optional. */
  key?: string
  /**    * Request template copied from the provider's docs, carrying the literal text `{key}` where the
   * credential goes. Must contain `{key}` when the provider declares a `key`, and must NOT when it
   * does not. */
  curl: string
  /** Free-text note about when to prefer this provider. Optional. */
  description?: string
  /** Defaults to true. `false` keeps the provider configured but hides
   *  it from `list_web_search_providers`. */
  enabled?: boolean
}

/** The Skill Evals block of `config.json`, as the wire carries it (snake_case, matching
 * `SkillEvalsJson` in `Config.zig`). `enabled` is the master switch the Settings toggle writes. */
export interface PabrikSkillEvalsConfig {
  enabled?: boolean
  max_skills_per_run?: number
  max_evals_per_day?: number
  fact_lease_seconds?: number
  include_listed_without_loading?: boolean
  /** `'off' | 'propose' | 'auto_low_risk'`. Null = not set on disk. */
  apply_mode?: string | null
}

export interface PabrikConfig {
  // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM defaults
  // (api_endpoint/api_key/model/url_style/temperature/max_tokens/system_prompt) were REMOVED from
  // config.json.
  profiles?: Record<string, PabrikAgent>
  active_profile?: string
  /** Map of MCP server name to its raw JSON config (snake_case). Each value follows the `{"url":
   * "...", "headers": {...}}` shape used by the LLM config. Sent verbatim to the backend on save. */
  mcp_servers?: Record<
    string,
    | { url: string; headers?: Record<string, string>; enabled?: boolean }
    | { command: string; args?: string[]; env?: string[]; cwd?: string; enabled?: boolean }
  >
  /**    * Default tool checklist (Tools tab). `null` / absent = the key is not in config.json — the
   * backend treats those as "no change" on PUT and the built-in defaults apply. An array (including
   * `[]`) replaces the whole list. */
  tools?: string[] | null
  /** Map of web-search provider name to its configuration — the top-level `web_search` key in
   * config.json. Keys of this map are the names the agent passes to `web_search`'s `provider`
   * argument; the agent discovers them through `list_web_search_providers`. */
  web_search?: Record<string, PabrikWebSearchProvider> | null
  /**    * Opt-in OS notification flag. When true, the backend fires `notify-send` / osascript /
   * PowerShell when an LLM response completes with `finish_reason === 'stop'`. Defaults to `false`
   * when absent (matches the `LlmConfigJson` default in `Config.zig`). */
  notify_on_complete?: boolean
  /** Plan 2026-08-25-notify-on-error — opt-in OS notification flag for the error path. When true,
   * the backend fires a desktop notification when the workflow hits a transport error, exhausts
   * retries (TooManyRetries), or fails the outer agentic loop. */
  notify_on_error?: boolean
  /** Skill Evals block — the master switch for the `run_skill_eval` tool and the budget knobs
   * around it. */
  skill_evals?: PabrikSkillEvalsConfig
  /**    * Compaction threshold in KB. Sessions whose DB-stored token estimate exceeds this value trigger
   * context compaction. Defaults to `100` when absent. Not exposed in the UI — power users can edit
   * `config.json` directly. */
  model_compaction_size_kb?: number
  /** Optional top-level override for the model's context window (in tokens). `null` = fall through
   * to per-profile override, then built-in default. Restored in plan 2026-07-07-compaction-inline
   * so the Defaults tab can show + edit the top-level compaction defaults. */
  max_capacity_token_model?: number | null
  /**    * Optional top-level compaction threshold as a percentage (0-100). `null` = fall through to
   * per-profile override, then built-in 80. Mirrors `LlmConfig.compaction_threshold_percent`. */
  compaction_threshold_percent?: number | null
  /** Delay in milliseconds before the workflow retries a failed `callDynamicAgentNew` call. 0 = no
   * delay (current behavior, the retry fires immediately on the next loop iteration). Range: 0–60
   * 000. The backend clamps values > 60 000 to 60 000. */
  retry_delay_ms?: number
  /** Plan 2026-09-10-web-launch-toggle — browser-mode flag. When true, the settings General tab
   * advertises the same UI in the system browser (URL pill + auto-open) and the server defaults to
   * a random local port at startup. Defaults to `false` when absent (matches `LlmConfigJson`). */
  web_launch_enabled?: boolean
  /** How the chat draws tool calls: "dev" keeps a card per call, "compact" folds a run of calls
   * into one card. Defaults to "dev" when absent (matches `LlmConfigJson`). */
  chat_view?: 'dev' | 'compact'
  // Per-profile compaction overrides (`max_capacity_tokens` /
  // `compaction_threshold_percent`) live on `PabrikAgent` (Chunk
  // 7.6) and remain there. Both layers coexist.
}

export async function getPabrikConfig(): Promise<PabrikConfig> {
  try {
    return await apiFetch<PabrikConfig>('/config/pabrik')
  } catch {
    return {}
  }
}

export async function savePabrikConfig(config: PabrikConfig): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>('/config/pabrik', {
    method: 'PUT',
    body: config,
  })
}

// ─── Per-workspace config overlay (Migration 105) ──────────────────────── The workspace-scope
// twin of the pair above.
export async function getWorkspaceConfig(workspaceId: string): Promise<PabrikConfig> {
  return await apiFetch<PabrikConfig>(`/workspaces/${encodeURIComponent(workspaceId)}/config`)
}

export async function saveWorkspaceConfig(
  workspaceId: string,
  config: PabrikConfig,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/config`,
    { method: 'PUT', body: config },
  )
}

/** Plan 2026-09-10-web-launch-toggle — browser-mode status. `GET /api/web/status` is read-only
 * (lifecycle A: no server-side start/stop). `url` is always the live bound port
 * (`http://127.0.0.1:<port>/`, loopback-only). */
export interface WebStatus {
  enabled: boolean
  running: boolean
  url: string
  port: number
}

export async function getWebStatus(): Promise<WebStatus | null> {
  try {
    return await apiFetch<WebStatus>('/web/status')
  } catch {
    return null
  }
}

/** Response shape from `DELETE /api/config/pabrik/profiles/:name`. `active_profile_was_cleared` is
 * `true` when the deleted profile was the active one (the backend also cleared `active_profile` on
 * disk). */
export interface AgentDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/** Running sessions bound to an agent profile — the rename guard. `running > 0` means a worker
 * is mid-run on this agent, so renaming it would leave that session pinned to a name that no
 * longer exists. GET /api/agent-profiles/:name/in-use */
export interface AgentProfileInUse {
  name: string
  running: number
  sessions: { id: string; sub_agent: boolean }[]
}

export async function getAgentProfileInUse(name: string): Promise<AgentProfileInUse> {
  return await apiFetch<AgentProfileInUse>(`/agent-profiles/${encodeURIComponent(name)}/in-use`)
}

/**  * DELETE /api/config/pabrik/profiles/:name Removes a profile from `config.json` and live-reloads
 * the backend's in-memory LLM config. Throws an Error (with the HTTP status) on non-2xx responses;
 * the composable wraps this for UI concerns (optimistic update, rollback, notification). */
export async function deleteAgent(name: string): Promise<AgentDeleteResponse> {
  return await apiFetch<AgentDeleteResponse>(
    `/config/pabrik/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

/**  * `DELETE /api/workspaces/:workspace_id/config/profiles/:name` Removes the profile from THIS
 * workspace's own settings. The user-scope config is never touched: a workspace starts with no
 * profiles of its own, so there is nothing to inherit back. */
export async function deleteWorkspaceAgent(
  workspaceId: string,
  name: string,
): Promise<AgentDeleteResponse> {
  return await apiFetch<AgentDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/config/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// ─── MCP server test probe ────────────────────────────────────────────────── Wire shape mirrors
// the backend `POST /api/mcp/test` handler in src/ai_workflow/tui/http_handlers/mcp_test.zig.
export interface McpToolPreview {
  name: string
  description: string
}
export type McpTestResult =
  | { ok: true; transport: 'http' | 'stdio'; tools: McpToolPreview[] }
  | { ok: false; error: string; details?: string }

export async function testMcpServer(body: {
  transport: 'http' | 'stdio'
  command?: string
  args?: string[]
  env?: string[]
  cwd?: string
  url?: string
  headers?: Record<string, string>
}): Promise<McpTestResult> {
  // We deliberately DON'T use the shared `apiFetch` wrapper here because (a) the endpoint always
  // returns HTTP 200 with a payload that may carry `{ ok: false, ... }`, and (b) we want the
  // modal's inline result panel to render the error message rather than firing a toast.
  const res = await fetch(`${API_BASE}/mcp/test`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await res.text().catch(() => '')
  let parsed: unknown = null
  try {
    parsed = text.length > 0 ? JSON.parse(text) : null
  } catch {
    // Non-JSON response — fall through to the generic error shape.
  }
  if (parsed && typeof parsed === 'object') {
    return parsed as McpTestResult
  }
  return {
    ok: false,
    error: `Unexpected response (HTTP ${res.status})`,
    details: text.slice(0, 200),
  }
}

// ─── LLM profile test probe ───────────────────────────────────────────────── Wire shape mirrors
// the backend `POST /api/llm/test` handler in src/http_handlers/llm_test.zig.
export interface LlmTestRequest {
  model: string
  base_url: string
  api_key: string
  url_style: string
}
export type LlmTestResult =
  | { ok: true; model: string; reply: string; latency_ms: number }
  | { ok: false; error: string; details?: string }

export async function testLlmProfile(body: LlmTestRequest): Promise<LlmTestResult> {
  // Deliberately NOT the shared `apiFetch` wrapper (same reason as `testMcpServer` above): the
  // endpoint always returns HTTP 200 with a payload that may carry `{ ok: false, ... }`, and we
  // want the modal's inline result panel to render the error rather than firing a toast.
  const res = await fetch(`${API_BASE}/llm/test`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await res.text().catch(() => '')
  let parsed: unknown = null
  try {
    parsed = text.length > 0 ? JSON.parse(text) : null
  } catch {
    // Non-JSON response — fall through to the generic error shape.
  }
  if (parsed && typeof parsed === 'object') {
    return parsed as LlmTestResult
  }
  return {
    ok: false,
    error: `Unexpected response (HTTP ${res.status})`,
    details: text.slice(0, 200),
  }
}
