import { apiFetch } from './client'

// ─── models.dev catalog (Migration 106) ───────────────────────────────── The catalog is a
// machine-wide snapshot, cached in the DB and synced hourly in the background.
export type ModelCatalogState = 'fresh' | 'stale' | 'absent'

export interface ModelCatalogEntry {
  provider_id: string
  provider_name: string
  model_id: string
  model_name: string
  context_window: number | null
  output_tokens: number | null
  reasoning: string
  temperature: boolean
}

export interface ModelCatalogResponse {
  total: number
  returned: number
  catalog: ModelCatalogState
  fetched_at_ms: number
  models: ModelCatalogEntry[]
  /** The last background sync's failure, when it failed. ABSENT when the last
   * attempt succeeded or none has run yet — so its presence is itself the news. */
  last_sync_error?: string
  last_sync_at_ms?: number
}

export interface ModelResolve {
  model: string
  catalog: ModelCatalogState
  /** `catalog` = we know this model; `builtin` = pabrik's fallback guess. */
  source: 'catalog' | 'builtin'
  context_window: number
  output_tokens?: number | null
  provider_id?: string
  provider_name?: string
  model_name?: string
  base_url?: string
  url_style?: string
  reasoning?: string
  /** The model's own effort values, e.g. `low · high · max`. */
  effort_values?: string[]
  /** The subset of those pabrik can actually send. */
  effort_values_sendable?: string[]
  budget_min?: number | null
  temperature?: boolean
  cost?: { input: number; output: number } | null
  fetched_at_ms?: number
  /** Present only when the model could not be resolved. */
  reason?: string
  /** The last sync attempt failed with this error name (e.g. `InvalidPayloadJson`).
   * Absent otherwise. Without it the UI can only report a state, never a cause —
   * which is how "no catalog yet" stayed unexplained. */
  last_sync_error?: string
  last_sync_at_ms?: number
}

/** `GET /api/models/catalog` — the model picker's data. Filtered server-side. */
export async function getModelCatalog(
  q?: string,
  provider?: string,
  limit?: number,
): Promise<ModelCatalogResponse> {
  const params = new URLSearchParams()
  if (q) params.set('q', q)
  if (provider) params.set('provider', provider)
  if (limit) params.set('limit', String(limit))
  const qs = params.toString()
  return await apiFetch<ModelCatalogResponse>(`/models/catalog${qs ? `?${qs}` : ''}`)
}

/** `GET /api/models/resolve` — what a (model, provider) pair resolves to. */
export async function resolveModel(model: string, provider?: string): Promise<ModelResolve> {
  const params = new URLSearchParams({ model })
  if (provider) params.set('provider', provider)
  return await apiFetch<ModelResolve>(`/models/resolve?${params.toString()}`)
}

/** `POST /api/models/refresh` — fetch models.dev now instead of waiting an hour. */
export async function refreshModelCatalog(): Promise<{
  ok: boolean
  providers: number
  models: number
  fetched_at_ms: number
  bytes_raw: number
  bytes_trimmed: number
}> {
  return await apiFetch('/models/refresh', { method: 'POST' })
}

/** Best-effort `resolveModel`. The failure is a DISCRIMINATED RESULT, not a swallowed value:
 * `{kind:'error', message}` is not something a caller can mistake for `context_window: 0`, which is
 * exactly the bug the Effect-style rule exists to prevent. */
export type ModelResolveOutcome =
  | { kind: 'ok'; value: ModelResolve }
  | { kind: 'error'; message: string }

export async function resolveModelOutcome(
  model: string,
  provider?: string,
): Promise<ModelResolveOutcome> {
  try {
    return { kind: 'ok', value: await resolveModel(model, provider) }
  } catch (err) {
    return { kind: 'error', message: err instanceof Error ? err.message : String(err) }
  }
}
