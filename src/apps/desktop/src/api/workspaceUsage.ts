import { apiFetch } from './client'

/** The three ranges the endpoint accepts. Anything else is a 400, so the type is the
 * allow-list rather than a free string. */
export type WorkspaceUsageRange = '7d' | '30d' | '90d'

export interface WorkspaceUsageTotals {
  calls: number
  sessions: number
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  cache_creation_tokens: number
  /** Calls that returned a cache counter (`cache_read` or `cache_creation` non-zero). */
  calls_with_cache: number
  /** Calls whose `cache_read_input_tokens` exceeded their own `prompt_tokens`. Excluded from
   * every rate above, so a broken provider mapping cannot print a rate over 100%. */
  excluded_calls: number
  tool_calls: number
  /** Percentage 0..100, or null when nothing divided into it: null means "no counter was
   * reported", which is not the same answer as 0%. */
  cache_hit_rate: number | null
}

export interface WorkspaceUsageDailyPoint {
  day: string
  calls: number
  input_tokens: number
  cache_read_tokens: number
  cache_hit_rate: number | null
}

export interface WorkspaceUsageModelRow {
  model: string
  calls: number
  input_tokens: number
  calls_with_cache: number
  cache_hit_rate: number | null
}

export interface WorkspaceUsageToolRow {
  tool_name: string
  calls: number
}

export interface WorkspaceUsageReasonRow {
  reason: string
  calls: number
}

export interface WorkspaceUsageCallPoint {
  i: number
  at: string
  input_tokens: number
  cache_read_tokens: number
  rate: number | null
}

export interface WorkspaceUsageCacheSeries {
  session_id: string
  model: string
  total_calls: number
  cache_hit_rate: number | null
  calls: WorkspaceUsageCallPoint[]
}

export interface WorkspaceUsage {
  workspace_id: string
  range: WorkspaceUsageRange
  totals: WorkspaceUsageTotals
  daily: WorkspaceUsageDailyPoint[]
  models: WorkspaceUsageModelRow[]
  tools: WorkspaceUsageToolRow[]
  finish_reasons: WorkspaceUsageReasonRow[]
  /** The most recent session in range that reported cache, capped at 120 calls, or null when
   * no provider reported one. */
  cache_series: WorkspaceUsageCacheSeries | null
}

/** GET /api/workspaces/:workspaceId/usage?range=30d — aggregates only, computed per request. */
export async function fetchWorkspaceUsage(
  workspaceId: string,
  range: WorkspaceUsageRange,
): Promise<WorkspaceUsage> {
  return await apiFetch<WorkspaceUsage>(
    `/workspaces/${encodeURIComponent(workspaceId)}/usage?range=${range}`,
    { track: false },
  )
}
