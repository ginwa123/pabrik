// Pinia store for workspace-scoped secrets (Migration 101).
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { Cause, Data, Effect, Exit } from 'effect'
import * as api from '../api'
import type { Secret } from '../api'

/** This store's error channel. */
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

/** Lift a rejecting promise into an Effect that fails in its error channel. */
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

/** Run an Effect and keep BOTH outcomes distinguishable. */
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
  /** Plaintexts the user asked to see, keyed by secret id. */
  const revealed = ref<Record<string, string>>({})
  /** Id of the secret whose reveal is in flight, or null. */
  const revealing = ref<string | null>(null)
  const loading = ref(false)
  const saving = ref(false)
  /** Last failure message, or null. Rendered by the view — never write-only. */
  const error = ref<string | null>(null)
  /** True once a list has been fetched for SOME workspace. */
  const loaded = ref(false)

  const count = computed(() => secrets.value.length)

  /** Fetch the list for a workspace. */
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

  /** Create a secret. */
  async function createSecret(
    workspaceId: string,
    name: string,
    value: string,
    description = '',
  ): Promise<Secret | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('create', () => api.createSecret(workspaceId, name, value, description)),
      'create',
    )
    saving.value = false
    if (!result.ok) {
      error.value = result.reason
      return null
    }
    // Prepend rather than refetch: a brand-new secret is the most recent, which saves a round-trip on the click that created it.
    secrets.value = [result.value.secret, ...secrets.value]
    loaded.value = true
    return result.value.secret
  }

  /** Rename a secret. */
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

  /** Replace a secret's credential in place ("rotate"). */
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

  /** Write or clear a secret's description. */
  async function describeSecret(
    workspaceId: string,
    secretId: string,
    description: string,
  ): Promise<Secret | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    const result = await runRequest(
      request('update', () => api.updateSecret(workspaceId, secretId, { description })),
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
    hideSecret(secretId)
    return true
  }

  /** Ask the server to unseal ONE value. */
  async function revealSecret(workspaceId: string, secretId: string): Promise<string | null> {
    if (!workspaceId || !secretId) return null
    revealing.value = secretId
    error.value = null
    const result = await runRequest(
      request('reveal', () => api.revealSecret(workspaceId, secretId)),
      'reveal',
    )
    revealing.value = null
    if (!result.ok) {
      // A value that could not be unsealed must not look like one that is already on screen, so nothing is added to the map.
      error.value = result.reason
      return null
    }
    revealed.value = { ...revealed.value, [secretId]: result.value.secret.value }
    return result.value.secret.value
  }

  /** Drop one plaintext from the page. */
  function hideSecret(secretId: string): void {
    if (!(secretId in revealed.value)) return
    const next = { ...revealed.value }
    delete next[secretId]
    revealed.value = next
  }

  /** Called on workspace switch so one workspace's secrets are never shown under another workspace's header — and so a stale failure banner does not survive the … */
  function reset(): void {
    secrets.value = []
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
    revealed.value = {}
    revealing.value = null
  }

  return {
    secrets,
    revealed,
    revealing,
    loading,
    saving,
    error,
    loaded,
    count,
    fetchSecrets,
    createSecret,
    renameSecret,
    describeSecret,
    rotateSecret,
    deleteSecret,
    revealSecret,
    hideSecret,
    reset,
  }
})
