// Pinia store for workspace-scoped secrets (Migration 101). Two things this store deliberately does
// NOT do: 1. No client-side workspace filter.
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { Cause, Data, Effect, Exit } from 'effect'
import * as api from '../api'
import type { Secret } from '../api'

/** This store's error channel. Every network call below returns `Effect<A, SecretsRequestError>`
 * rather than a promise that may reject, so the failure is in the TYPE and each call site has to
 * decide what to do with it. */
export class SecretsRequestError extends Data.TaggedError('SecretsRequestError')<{
  /** Store action that triggered the request, e.g. `list`, `create`. */
  readonly op: string
  /** Underlying message, for display. Never parsed for control flow. */
  readonly reason: string
}> {}

/** Short, log-safe one-liner for an error on this store's error channel. */
export function describeSecretsError(error: SecretsRequestError): string {
  return `secrets ${error.op} failed: ${error.reason}`
}

/**  * Lift a rejecting promise into an Effect that fails in its error channel. This is the same
 * `Effect.tryPromise` wrapper `sync/DocumentEngineDb.ts` uses for its remote fetch; the difference
 * is only the error type, which here describes a network call rather than a cache. */
function request<A>(op: string, run: () => Promise<A>): Effect.Effect<A, SecretsRequestError> {
  return Effect.tryPromise({
    try: run,
    catch: (e) =>
      new SecretsRequestError({
        op,
        reason: e instanceof Error ? e.message : String(e),
      }),
  })
}

/** Run an Effect and keep BOTH outcomes distinguishable. Deliberately NOT `runSyncEffectOr(effect,
 * [], op)`: that helper degrades to an empty row list, which is precisely the "a failed fetch
 * renders as 'no rows'" collapse this store exists to avoid. */
async function runRequest<A>(
  effect: Effect.Effect<A, SecretsRequestError>,
  op: string,
): Promise<{ ok: true; value: A } | { ok: false; reason: string }> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value }
  const squashed = Cause.squash(exit.cause) as SecretsRequestError
  if (import.meta.env?.DEV) {
    console.warn(`[secrets] ${op}: ${describeSecretsError(squashed)}`)
  }
  return { ok: false, reason: describeSecretsError(squashed) }
}

export const useSecretsStore = defineStore('secrets', () => {
  const secrets = ref<Secret[]>([])
  const loading = ref(false)
  const saving = ref(false)
  /** Last failure message, or null. Rendered by the view — never write-only. */
  const error = ref<string | null>(null)
  /** True once a list has been fetched for SOME workspace. */
  const loaded = ref(false)

  const count = computed(() => secrets.value.length)

  /** Fetch the list for a workspace. A failure leaves whatever was last painted on screen and
   * records `error`; it never blanks the list. */
  async function fetchSecrets(workspaceId: string): Promise<void> {
    if (!workspaceId) return
    loading.value = true
    error.value = null
    const result = await runRequest(
      request('list', () => api.listSecrets(workspaceId)),
      'list',
    )
    if (result.ok) {
      secrets.value = result.value.secrets ?? []
      loaded.value = true
    } else {
      error.value = result.reason
    }
    loading.value = false
  }

  /** Create a secret. `value` is consumed here and nowhere else: it goes into the request body and
   * is not copied into any state. The returned `Secret` — the only thing this store keeps — has no
   * value field, so there is nothing downstream that could render one. */
  async function createSecret(
    workspaceId: string,
    name: string,
    value: string,
  ): Promise<Secret | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('create', () => api.createSecret(workspaceId, name, value)),
      'create',
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return null
    }
    // Prepend rather than refetch: a brand-new secret is the most recent,
    // which saves a round-trip on the click that created it.
    secrets.value = [result.value.secret, ...secrets.value]
    loaded.value = true
    return result.value.secret
  }

  /** Rename a secret. Sends only the name, so the stored credential is
   * untouched and never has to be re-supplied. */
  async function renameSecret(
    workspaceId: string,
    secretId: string,
    name: string,
  ): Promise<Secret | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('update', () => api.updateSecret(workspaceId, secretId, { name })),
      'update',
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return null
    }
    secrets.value = secrets.value.map((s) =>
      s.id === result.value.secret.id ? result.value.secret : s,
    )
    return result.value.secret
  }

  /**    * Replace a secret's credential in place ("rotate"). Same discipline as `createSecret`: the new
   * value goes into the PATCH body and is dropped. The response replaces the row, so the UI shows
   * the new `updated_at` and never the new value. */
  async function rotateSecret(
    workspaceId: string,
    secretId: string,
    value: string,
  ): Promise<Secret | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('update', () => api.updateSecret(workspaceId, secretId, { value })),
      'update',
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return null
    }
    secrets.value = secrets.value.map((s) =>
      s.id === result.value.secret.id ? result.value.secret : s,
    )
    return result.value.secret
  }

  /** Delete by id, keeping the confirmation at the call site. */
  async function deleteSecret(workspaceId: string, secretId: string): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('delete', () => api.deleteSecret(workspaceId, secretId)),
      'delete',
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return false
    }
    secrets.value = secrets.value.filter((s) => s.id !== secretId)
    return true
  }

  /**    * Called on workspace switch so one workspace's secrets are never shown under another workspace's
   * header — and so a stale failure banner does not survive the switch. */
  function reset(): void {
    secrets.value = []
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
  }

  return {
    secrets,
    loading,
    saving,
    error,
    loaded,
    count,
    fetchSecrets,
    createSecret,
    renameSecret,
    rotateSecret,
    deleteSecret,
    reset,
  }
})
