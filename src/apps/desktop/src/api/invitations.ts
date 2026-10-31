import { apiFetch } from './client'
import type { WorkspaceRole } from './members'

// ─── Workspace invitations (Migration 123) ────────────────────────────── An invite is a PENDING
// ask: the server writes no membership until the invitee accepts, so nothing can appear in
// someone's sidebar because a stranger typed their address.
export interface WorkspaceInvitation {
  id: string
  workspace_id: string
  /** The invited workspace's name, so an inbox row reads without a second lookup. */
  workspace_name: string
  invitee_user_id: string
  invitee_email: string
  invitee_name: string
  role: WorkspaceRole
  /** The inviter's user id, or '' when the row predates the column. */
  invited_by: string
  created_at: string
}

/** GET /api/workspaces/:workspaceId/invitations — pending asks for ONE workspace. Owner/admin
 * only: each row carries an email address. */
export async function listWorkspaceInvitations(
  workspaceId: string,
): Promise<{ invitations: WorkspaceInvitation[]; count: number }> {
  return await apiFetch<{ invitations: WorkspaceInvitation[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/invitations`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/invitations Body: `{ email, role }`. 201 with the PENDING
 * row — not a member. 404 names an address no account carries; 409 when the account is already a
 * member or already has an unanswered invitation. */
export async function createInvitation(
  workspaceId: string,
  email: string,
  role: WorkspaceRole,
): Promise<{ invitation: WorkspaceInvitation }> {
  return await apiFetch<{ invitation: WorkspaceInvitation }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/invitations`,
    { method: 'POST', body: { email, role } },
  )
}

/** DELETE /api/workspaces/:workspaceId/invitations/:invitationId — withdraw an unanswered ask. */
export async function revokeInvitation(
  workspaceId: string,
  invitationId: string,
): Promise<{ success: boolean; id: string }> {
  return await apiFetch<{ success: boolean; id: string }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/invitations/${encodeURIComponent(invitationId)}`,
    { method: 'DELETE' },
  )
}

/** GET /api/invitations — the caller's own inbox across every workspace. */
export async function listMyInvitations(): Promise<{
  invitations: WorkspaceInvitation[]
  count: number
}> {
  return await apiFetch<{ invitations: WorkspaceInvitation[]; count: number }>('/invitations', {
    track: false,
  })
}

/** POST /api/invitations/:invitationId/accept — THIS call is what creates the membership. 404 when
 * the invitation is somebody else's, 409 when the account is already a member. */
export async function acceptInvitation(
  invitationId: string,
): Promise<{ member: { workspace_id: string; user_id: string; role: WorkspaceRole } }> {
  return await apiFetch<{ member: { workspace_id: string; user_id: string; role: WorkspaceRole } }>(
    `/invitations/${encodeURIComponent(invitationId)}/accept`,
    { method: 'POST' },
  )
}

/** POST /api/invitations/:invitationId/decline — the ask is deleted and nothing is granted. */
export async function declineInvitation(
  invitationId: string,
): Promise<{ success: boolean; id: string }> {
  return await apiFetch<{ success: boolean; id: string }>(
    `/invitations/${encodeURIComponent(invitationId)}/decline`,
    { method: 'POST' },
  )
}
