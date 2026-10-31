// Pinia store for workspace invitations. Two lists that must not be confused: `mine` is what I am
// asked to answer, `pending` is what I have asked others. Both come from the server, never sorted
// here.
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { Cause, Data, Effect, Exit } from 'effect'
import * as api from '../api'
import type { WorkspaceInvitation, WorkspaceRole } from '../api'
import { tryParseJsonErrorField } from '../api/internal'

export class InvitationsRequestError extends Data.TaggedError('InvitationsRequestError')<{
  readonly op: string
  readonly reason: string
  /** HTTP status, or 0 for a network failure. A 403 is not a broken fetch — it
   * is "you may not manage this workspace", which the panel renders as a note. */
  readonly status: number
}> {}

export function describeInvitationsError(error: InvitationsRequestError): string {
  return `invitations ${error.op} failed: ${error.reason}`
}

/** The server answers its refusals as `{"error": "…"}`. That sentence is the one the user can act
 * on; `HTTP 409 Conflict` is not. */
function reasonOf(e: unknown): string {
  if (e instanceof api.ApiError) {
    return tryParseJsonErrorField(e.body) ?? e.message
  }
  return e instanceof Error ? e.message : String(e)
}

function request<A>(op: string, run: () => Promise<A>): Effect.Effect<A, InvitationsRequestError> {
  return Effect.tryPromise({
    try: run,
    catch: (e) =>
      new InvitationsRequestError({
        op,
        reason: reasonOf(e),
        status: e instanceof api.ApiError ? e.status : 0,
      }),
  })
}

async function runRequest<A>(
  effect: Effect.Effect<A, InvitationsRequestError>,
): Promise<{ ok: true; value: A } | { ok: false; reason: string; status: number }> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value }
  const squashed = Cause.squash(exit.cause) as InvitationsRequestError
  return { ok: false, reason: describeInvitationsError(squashed), status: squashed.status }
}

export const useInvitationsStore = defineStore('invitations', () => {
  /** Invitations addressed to ME, across every workspace. */
  const mine = ref<WorkspaceInvitation[]>([])
  /** Invitations THIS workspace has sent that nobody has answered. */
  const pending = ref<WorkspaceInvitation[]>([])
  const loading = ref(false)
  const saving = ref(false)
  const error = ref<string | null>(null)
  const loaded = ref(false)
  /** False once the server says this caller is not an owner/admin. Drives the
   * invite form and the pending block — an editor may read the roster and
   * nothing else. */
  const canManage = ref(true)

  const mineCount = computed(() => mine.value.length)
  const pendingCount = computed(() => pending.value.length)

  async function loadMine(): Promise<void> {
    const result = await runRequest(request('inbox', () => api.listMyInvitations()))
    if (!result.ok) {
      error.value = result.reason
      return
    }
    mine.value = result.value.invitations ?? []
    loaded.value = true
  }

  async function loadPending(workspaceId: string): Promise<void> {
    const result = await runRequest(
      request('pending', () => api.listWorkspaceInvitations(workspaceId)),
    )
    if (!result.ok) {
      // 403 here is an ANSWER, not a failure: this account is a member but not
      // an owner/admin, so there is no list to show and nothing went wrong.
      if (result.status === 403) {
        canManage.value = false
        pending.value = []
        return
      }
      error.value = result.reason
      return
    }
    canManage.value = true
    pending.value = result.value.invitations ?? []
  }

  /** The inbox is fetched on its own so the sidebar can show a pending ask without knowing which
   * workspace the user is looking at. */
  async function fetchMine(): Promise<void> {
    loading.value = true
    error.value = null
    await loadMine()
    loading.value = false
  }

  async function fetchPending(workspaceId: string): Promise<void> {
    if (!workspaceId) return
    loading.value = true
    error.value = null
    await loadPending(workspaceId)
    loading.value = false
  }

  /** Ask somebody to join. Returns false and records why on any refusal — the invitee is NOT a
   * member when this succeeds, which is why the caller must not treat it as an add. */
  async function invite(
    workspaceId: string,
    email: string,
    role: WorkspaceRole,
  ): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('invite', () => api.createInvitation(workspaceId, email, role)),
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await loadPending(workspaceId)
    return true
  }

  async function revoke(workspaceId: string, invitationId: string): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('revoke', () => api.revokeInvitation(workspaceId, invitationId)),
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await loadPending(workspaceId)
    return true
  }

  /** Say yes. This is the only client call that can put a new workspace in the sidebar, so the
   * inbox is re-read afterwards and the caller refreshes the workspace list. */
  async function accept(invitationId: string): Promise<string | null> {
    saving.value = true
    error.value = null
    const result = await runRequest(request('accept', () => api.acceptInvitation(invitationId)))
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return null
    }
    await loadMine()
    return result.value.member.workspace_id
  }

  async function decline(invitationId: string): Promise<boolean> {
    saving.value = true
    error.value = null
    const result = await runRequest(request('decline', () => api.declineInvitation(invitationId)))
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await loadMine()
    return true
  }

  function reset(): void {
    mine.value = []
    pending.value = []
    canManage.value = true
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
  }

  return {
    mine,
    pending,
    loading,
    saving,
    error,
    loaded,
    canManage,
    mineCount,
    pendingCount,
    fetchMine,
    fetchPending,
    invite,
    revoke,
    accept,
    decline,
    reset,
  }
})
