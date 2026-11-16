import { API_BASE, apiFetch } from './client'

// Pabrik Config API
export interface PabrikAgent {
  model?: string
  base_url?: string
  thinking?: string
  temperature?: string
  url_style?: string
  api_key?: string
  /** The agent's persona. */
  system_prompt?: string
  /** Which TRANSPORT runs this profile's calls: `"http"` (default), `"claude-code"` (the local `claude` CLI, subscription auth via `claude login`), or `"opencode"` … */
  backend?: string
  /** Claude Code only: `CLAUDE_CONFIG_DIR` for this profile. */
  config_dir?: string | null
  /** Claude Code only: agentic turn ceiling passed as `--max-turns`. */
  max_turns?: number | null
  /** Optional override for this profile's context window (in tokens). */
  max_capacity_tokens?: number | null
  /** Compaction threshold as a percentage (0-100) of this profile's context window. */
  compaction_threshold_percent?: number | null
  /** Anthropic-only override for `thinking.budget_tokens`. */
  thinking_budget_tokens?: number | null
  /** OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). */
  reasoning_effort?: 'low' | 'medium' | 'high' | 'auto' | null
  /** False = the agent is switched off: `list_agents` does not offer it, `spawn_sub_agent` cannot run it, and the agent pickers hide it. */
  enabled?: boolean
}

export interface McpHeader {
  key: string
  value: string
}

export interface McpServer {
  name: string
  /** Transport discriminator. */
  transport?: 'http' | 'stdio'
  /** HTTP transport — required when transport === 'http'. */
  url?: string
  /** Optional list of HTTP headers to send with MCP requests (e.g. API keys). */
  headers?: McpHeader[]
  /** stdio transport — required when transport === 'stdio'. */
  command?: string
  /** stdio transport — argv (excluding argv[0]). One entry per line in the UI. */
  args?: string[]
  /** stdio transport — "KEY=VALUE" per line, ADDED on top of inherited env. v1 limitation: Zig 0.16's std.process.Child has no clean .env_map setter, so a custom … */
  env?: string[]
  /** stdio transport — optional child working directory (absolute path). */
  cwd?: string
  /** When false the agent skips this server (no tools listed, no calls). */
  enabled?: boolean
}

/** One entry of the top-level `web_search` map in `config.json` — the wire shape of a single web-search provider. */
export interface PabrikWebSearchProvider {
  /** Host pin. */
  url: string
  /** Credential, stored separately from `curl` so nothing derived from the template can leak it. */
  key?: string
  /** Request template copied from the provider's docs, carrying the literal text `{key}` where the credential goes. */
  curl: string
  /** Free-text note about when to prefer this provider. Optional. */
  description?: string
  /** Defaults to true. */
  enabled?: boolean
}

/** The Skill Evals block of `config.json`, as the wire carries it (snake_case, matching `SkillEvalsJson` in `Config.zig`). */
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
  // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM defaults (api_endpoint/api_key/model/url_style/temperature/max_tokens/system_prompt) were …
  profiles?: Record<string, PabrikAgent>
  active_profile?: string
  /** Map of MCP server name to its raw JSON config (snake_case). Each value follows the `{"url" */
  mcp_servers?: Record<
    string,
    | { url: string; headers?: Record<string, string>; enabled?: boolean }
    | { command: string; args?: string[]; env?: string[]; cwd?: string; enabled?: boolean }
  >
  /** Default tool checklist (Tools tab). */
  tools?: string[] | null
  /** Map of web-search provider name to its configuration — the top-level `web_search` key in config.json. */
  web_search?: Record<string, PabrikWebSearchProvider> | null
  /** Opt-in OS notification flag. */
  notify_on_complete?: boolean
  /** Plan 2026-08-25-notify-on-error — opt-in OS notification flag for the error path. */
  notify_on_error?: boolean
  /** Skill Evals block — the master switch for the `run_skill_eval` tool and the budget knobs around it. */
  skill_evals?: PabrikSkillEvalsConfig
  /** Compaction threshold in KB. */
  model_compaction_size_kb?: number
  /** Optional top-level override for the model's context window (in tokens). */
  max_capacity_token_model?: number | null
  /** Optional top-level compaction threshold as a percentage (0-100). */
  compaction_threshold_percent?: number | null
  /** Whether the AGENT may compact its own context through `compaction`. */
  agent_auto_compaction?: boolean | null
  /** Delay in milliseconds before the workflow retries a failed `callDynamicAgentNew` call. 0 = no delay (current behavior, the retry fires immediately on the next … */
  retry_delay_ms?: number
  /** Overall deadline in milliseconds for ONE streaming LLM call (response head to last chunk). */
  llm_read_timeout_ms?: number
  /** Plan 2026-09-10-web-launch-toggle — browser-mode flag. */
  web_launch_enabled?: boolean
  /** How the chat draws tool calls: "dev" keeps a card per call, "compact" folds a run of calls into one card. */
  chat_view?: 'dev' | 'compact'
  // Per-profile compaction overrides (`max_capacity_tokens` /`compaction_threshold_percent`) live on `PabrikAgent` (Chunk 7.6) and remain there.
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

// ─── Per-workspace config overlay (Migration 105) ────────────────────────
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

/** Plan 2026-09-10-web-launch-toggle — browser-mode status. */
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

/** Response shape from `DELETE /api/config/pabrik/profiles/:name`. */
export interface AgentDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/** Running sessions bound to an agent profile — the rename guard. */
export interface AgentProfileInUse {
  name: string
  running: number
  sessions: { id: string; sub_agent: boolean }[]
}

export async function getAgentProfileInUse(name: string): Promise<AgentProfileInUse> {
  return await apiFetch<AgentProfileInUse>(`/agent-profiles/${encodeURIComponent(name)}/in-use`)
}

/** DELETE /api/config/pabrik/profiles/:name Removes a profile from `config.json` and live-reloads the backend's in-memory LLM config. */
export async function deleteAgent(name: string): Promise<AgentDeleteResponse> {
  return await apiFetch<AgentDeleteResponse>(
    `/config/pabrik/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

/** `DELETE /api/workspaces/:workspace_id/config/profiles/:name` Removes the profile from THIS workspace's own settings. */
export async function deleteWorkspaceAgent(
  workspaceId: string,
  name: string,
): Promise<AgentDeleteResponse> {
  return await apiFetch<AgentDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/config/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// ─── MCP server test probe ──────────────────────────────────────────────────
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
  /** The workspace whose secrets the headers/env may reference. */
  workspace_id?: string
}): Promise<McpTestResult> {
  // We deliberately DON'T use the shared `apiFetch` wrapper here because (a) the endpoint always returns HTTP 200 with a payload that may carry `{ ok: false, ... …
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

// ─── LLM profile test probe ─────────────────────────────────────────────────
export interface LlmTestRequest {
  model: string
  base_url: string
  api_key: string
  url_style: string
  /** The workspace whose secrets `api_key` may reference. */
  workspace_id?: string
}
export type LlmTestResult =
  | { ok: true; model: string; reply: string; latency_ms: number }
  | { ok: false; error: string; details?: string }

export async function testLlmProfile(body: LlmTestRequest): Promise<LlmTestResult> {
  // Deliberately NOT the shared `apiFetch` wrapper (same reason as `testMcpServer` above): the endpoint always returns HTTP 200 with a payload that may carry `{ …
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
