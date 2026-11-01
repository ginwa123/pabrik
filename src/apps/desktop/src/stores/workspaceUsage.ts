import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { Cause, Data, Effect, Exit } from 'effect'
import * as api from '../api'
import type { WorkspaceUsage, WorkspaceUsageRange } from '../api'
import { tryParseJsonErrorField } from '../api/internal'

/** This store's error channel, the shape `stores/members.ts` uses: the failure is in the type, so
 * every call site decides whether to show it. */
export class WorkspaceUsageRequestError extends Data.TaggedError('WorkspaceUsageRequestError')<{
  readonly op: string
  readonly reason: string
}> {}

export function describeWorkspaceUsageError(error: WorkspaceUsageRequestError): string {
  return `usage ${error.op} failed: ${error.reason}`
}

function reasonOf(e: unknown): string {
  if (e instanceof api.ApiError) {
    return tryParseJsonErrorField(e.body) ?? e.message
  }
  return e instanceof Error ? e.message : String(e)
}

function request<A>(
  op: string,
  run: () => Promise<A>,
): Effect.Effect<A, WorkspaceUsageRequestError> {
  return Effect.tryPromise({
    try: run,
    catch: (e) => new WorkspaceUsageRequestError({ op, reason: reasonOf(e) }),
  })
}

/** Keep both outcomes distinguishable: a failed fetch must never render as "no calls". */
async function runRequest<A>(
  effect: Effect.Effect<A, WorkspaceUsageRequestError>,
): Promise<{ ok: true; value: A } | { ok: false; reason: string }> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value }
  const squashed = Cause.squash(exit.cause) as WorkspaceUsageRequestError
  return { ok: false, reason: describeWorkspaceUsageError(squashed) }
}

export const useWorkspaceUsageStore = defineStore('workspaceUsage', () => {
  const usage = ref<WorkspaceUsage | null>(null)
  const range = ref<WorkspaceUsageRange>('30d')
  const loading = ref(false)
  /** Last failure message, or null. Rendered by the section — never write-only. */
  const error = ref<string | null>(null)

  /** The workspace whose numbers are in `usage`. A switch must not paint one workspace's totals
   * under another's header, so readers compare this before rendering. */
  const loadedWorkspace = computed<string>(() => usage.value?.workspace_id ?? '')

  async function load(
    workspaceId: string,
    next: WorkspaceUsageRange = range.value,
  ): Promise<boolean> {
    if (!workspaceId) return false
    range.value = next
    loading.value = true
    error.value = null
    const result = await runRequest(
      request('load', () => api.fetchWorkspaceUsage(workspaceId, next)),
    )
    loading.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    usage.value = result.value
    return true
  }

  function reset(): void {
    usage.value = null
    error.value = null
    loading.value = false
  }

  return { usage, range, loading, error, loadedWorkspace, load, reset }
})
