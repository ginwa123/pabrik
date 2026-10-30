import { apiFetch } from './client'

// ─── Workspace members (Migration 100) ─────────────────────────────────── Who belongs to one
// workspace and with which role. An invite names an existing account by email; there is no signup,
// so an address with no account is a 404 the form has to show.
export type WorkspaceRole = 'owner' | 'admin' | 'editor' | 'viewer'

export interface WorkspaceMember {
  user_id: string
  email: string
  name: string
  role: WorkspaceRole
  joined_at: string
  /** The inviter's user id, or '' for a member that predates invites. */
  invited_by: string
}

/** GET /api/workspaces/:workspaceId/members — owners first. A workspace with no members returns
 * `{ members: [], count: 0 }`, which is a different answer from a failed request. */
export async function listMembers(
  workspaceId: string,
): Promise<{ members: WorkspaceMember[]; count: number }> {
  return await apiFetch<{ members: WorkspaceMember[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/members Body: `{ email, role }`. The server defaults an
 * omitted role to `viewer`; this call always sends one. 404 when no active account carries that
 * email; 409 when the account is already a member. */
export async function inviteMember(
  workspaceId: string,
  email: string,
  role: WorkspaceRole,
): Promise<{ member: WorkspaceMember }> {
  return await apiFetch<{ member: WorkspaceMember }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members`,
    { method: 'POST', body: { email, role } },
  )
}

/** PATCH /api/workspaces/:workspaceId/members/:userId Body: `{ role }`. 409 when the change would
 * leave the workspace with no owner. */
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

/** DELETE /api/workspaces/:workspaceId/members/:userId — 409 for the last owner, 404 for an account
 * that is not a member. */
export async function removeMember(
  workspaceId: string,
  userId: string,
): Promise<{ success: boolean; user_id: string }> {
  return await apiFetch<{ success: boolean; user_id: string }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/members/${encodeURIComponent(userId)}`,
    { method: 'DELETE' },
  )
}
