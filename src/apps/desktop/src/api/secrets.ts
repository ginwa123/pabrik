import { apiFetch } from './core'

// ─── Workspace secrets (Migration 101) ─────────────────────────────────── Named credentials
// scoped to one workspace: an API key the agent's tools can substitute into a request, never
// displayed back to the browser. NO RESPONSE EVER CONTAINS THE VALUE.
export interface Secret {
  id: string
  name: string
  created_at: string
  updated_at: string
}

/**  * GET /api/workspaces/:workspaceId/secrets Metadata only. A workspace with no secrets returns `{
 * secrets: [], count: 0 }` — which is a different answer from a failed request, and callers must
 * keep the two apart. */
export async function listSecrets(
  workspaceId: string,
): Promise<{ secrets: Secret[]; count: number }> {
  return await apiFetch<{ secrets: Secret[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/secrets Body: `{ name, value }`. `name` must be non-blank and
 * unique within the workspace; `value` is write-only — the response carries the created row WITHOUT
 * it. */
export async function createSecret(
  workspaceId: string,
  name: string,
  value: string,
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { method: 'POST', body: { name, value } },
  )
}

/** PATCH /api/workspaces/:workspaceId/secrets/:secretId Body: `{ name?, value? }`. Both fields are
 * partial — send `{ value }` to rotate a credential without touching its name, or `{ name }` to
 * rename without re-supplying a value. */
export async function updateSecret(
  workspaceId: string,
  secretId: string,
  patch: { name?: string; value?: string },
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'PATCH', body: patch },
  )
}

/**  * DELETE /api/workspaces/:workspaceId/secrets/:secretId Returns 404 for another workspace's id, and
 * deletes nothing in that case. */
export async function deleteSecret(
  workspaceId: string,
  secretId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'DELETE' },
  )
}
