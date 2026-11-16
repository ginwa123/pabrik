import { apiFetch } from './client'

// ─── Workspace secrets (Migration 101) ───────────────────────────────────
export interface Secret {
  id: string
  name: string
  /** What this credential is for, in the words the person who stored it chose. */
  description: string
  created_at: string
  updated_at: string
}

/** GET /api/workspaces/:workspaceId/secrets Metadata only. */
export async function listSecrets(
  workspaceId: string,
): Promise<{ secrets: Secret[]; count: number }> {
  return await apiFetch<{ secrets: Secret[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/secrets Body: `{ name, value }`. */
export async function createSecret(
  workspaceId: string,
  name: string,
  value: string,
  description = '',
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { method: 'POST', body: { name, value, description } },
  )
}

/** PATCH /api/workspaces/:workspaceId/secrets/:secretId Body: `{ name?, value? }`. */
export async function updateSecret(
  workspaceId: string,
  secretId: string,
  patch: { name?: string; value?: string; description?: string },
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'PATCH', body: patch },
  )
}

/** DELETE /api/workspaces/:workspaceId/secrets/:secretId Returns 404 for another workspace's id, and deletes nothing in that case. */
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

/** GET /api/workspaces/:workspaceId/secrets/:secretId/reveal Asks the server to unseal ONE value. */
export async function revealSecret(
  workspaceId: string,
  secretId: string,
): Promise<{ secret: RevealedSecret }> {
  return await apiFetch<{ secret: RevealedSecret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}/reveal`,
    { track: false },
  )
}
