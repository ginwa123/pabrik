import { apiFetch } from './client'

// ─── Workspace secrets (Migration 101) ─────────────────────────────────── Named credentials
// scoped to one workspace. Values are sealed at rest and no list response contains one; only
// `revealSecret` returns a plaintext, and only to a member of that workspace.
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

/** The one shape on this surface that carries a plaintext credential. */
export interface RevealedSecret {
  id: string
  name: string
  value: string
}

/** GET /api/workspaces/:workspaceId/secrets/:secretId/reveal Asks the server to unseal ONE value.
 * Member-only: a non-member gets 404, the same answer as an id that does not exist. Never call this
 * in a list or a loop — one explicit user action, one request. */
export async function revealSecret(
  workspaceId: string,
  secretId: string,
): Promise<{ secret: RevealedSecret }> {
  return await apiFetch<{ secret: RevealedSecret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}/reveal`,
    { track: false },
  )
}
