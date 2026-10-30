// Pinia store for workspace members. The list is per workspace and refetched after every write, so
// the server's ordering (owners first) stays the only ordering there is.
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { Cause, Data, Effect, Exit } from 'effect'
import * as api from '../api'
import type { WorkspaceMember, WorkspaceRole } from '../api'
import { tryParseJsonErrorField } from '../api/internal'

/** This store's error channel, the same shape `stores/secrets.ts` uses: the failure is in the TYPE,
 * so every call site decides what to do with it. */
export class MembersRequestError extends Data.TaggedError('MembersRequestError')<{
  readonly op: string
  /** Operator-facing message. Never parsed for control flow. */
  readonly reason: string
}> {}

export function describeMembersError(error: MembersRequestError): string {
  return `members ${error.op} failed: ${error.reason}`
}

/** The server answers its refusals as `{"error": "no active account with the email '…'"}`. THAT
 * sentence is the useful one — `HTTP 404 Not Found` tells the user nothing about what to fix. */
function reasonOf(e: unknown): string {
  if (e instanceof api.ApiError) {
    return tryParseJsonErrorField(e.body) ?? e.message
  }
  return e instanceof Error ? e.message : String(e)
}

function request<A>(op: string, run: () => Promise<A>): Effect.Effect<A, MembersRequestError> {
  return Effect.tryPromise({
    try: run,
    catch: (e) => new MembersRequestError({ op, reason: reasonOf(e) }),
  })
}

/** Keep BOTH outcomes distinguishable: a failed fetch must not render as "no members". */
async function runRequest<A>(
  effect: Effect.Effect<A, MembersRequestError>,
): Promise<{ ok: true; value: A } | { ok: false; reason: string }> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value }
  const squashed = Cause.squash(exit.cause) as MembersRequestError
  return { ok: false, reason: describeMembersError(squashed) }
}

export const useMembersStore = defineStore('members', () => {
  const members = ref<WorkspaceMember[]>([])
  const loading = ref(false)
  const saving = ref(false)
  /** Last failure message, or null. Rendered by the view — never write-only. */
  const error = ref<string | null>(null)
  /** True once a list has been fetched for SOME workspace. */
  const loaded = ref(false)

  const count = computed(() => members.value.length)

  /** Re-read the list without touching `loading`, so a write's refresh does not flash the panel. */
  async function reload(workspaceId: string): Promise<boolean> {
    const result = await runRequest(request('list', () => api.listMembers(workspaceId)))
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    members.value = result.value.members ?? []
    loaded.value = true
    return true
  }

  async function fetchMembers(workspaceId: string): Promise<void> {
    if (!workspaceId) return
    loading.value = true
    error.value = null
    await reload(workspaceId)
    loading.value = false
  }

  /** Add an existing account by email. The server defaults an omitted role to `viewer`, so the
   * panel always sends one. */
  async function inviteMember(
    workspaceId: string,
    email: string,
    role: WorkspaceRole,
  ): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('invite', () => api.inviteMember(workspaceId, email, role)),
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await reload(workspaceId)
    return true
  }

  async function setRole(
    workspaceId: string,
    userId: string,
    role: WorkspaceRole,
  ): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('update', () => api.updateMemberRole(workspaceId, userId, role)),
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await reload(workspaceId)
    return true
  }

  async function removeMember(workspaceId: string, userId: string): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('remove', () => api.removeMember(workspaceId, userId)),
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    await reload(workspaceId)
    return true
  }

  /** Called on mount and on workspace switch, so one workspace's members — and its error banner —
   * never paint under another workspace's header. */
  function reset(): void {
    members.value = []
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
  }

  return {
    members,
    loading,
    saving,
    error,
    loaded,
    count,
    fetchMembers,
    inviteMember,
    setRole,
    removeMember,
    reset,
  }
})
