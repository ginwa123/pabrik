import { apiFetch } from './client'

// ─── Workspace members (Migration 100) ───────────────────────────────────
export type WorkspaceRole = 'owner' | 'admin' | 'editor' | 'viewer'

export interface WorkspaceMember {
  /** The workspace this membership is in — an accepted invitation's response carries it so the caller knows which workspace just became available. */
  workspace_id: string
  user_id: string
  email: string
  name: string
  role: WorkspaceRole
  joined_at: string
  /** The inviter's user id, or '' for a member that predates invites. */
  invited_by: string
}

/** GET /api/workspaces/:workspaceId/members — owners first. */
export async function listMembers(
  workspaceId: string,
): Promise<{ members: WorkspaceMember[]; count: number }> {
  return await apiFetch<{ members: WorkspaceMember[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members`,
    { track: false },
  )
}

/** PATCH /api/workspaces/:workspaceId/members/:userId Body: `{ role }`. 409 when the change would leave the workspace with no owner. */
export async function updateMemberRole(
  workspaceId: string,
  userId: string,
  role: WorkspaceRole,
): Promise<{ member: WorkspaceMember }> {
  return await apiFetch<{ member: WorkspaceMember }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members/${encodeURIComponent(userId)}`,
    { method: 'PATCH', body: { role } },
  )
}

/** DELETE /api/workspaces/:workspaceId/members/:userId — 409 for the last owner, 404 for an account that is not a member. */
export async function removeMember(
  workspaceId: string,
  userId: string,
): Promise<{ success: boolean; user_id: string }> {
  return await apiFetch<{ success: boolean; user_id: string }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members/${encodeURIComponent(userId)}`,
    { method: 'DELETE' },
  )
}
