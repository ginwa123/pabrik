import { useNotificationStore } from '../stores/notifications'
import { getActivePinia } from 'pinia'
import { useLoadingStore } from '../stores/loading'
import { tryParseJsonErrorField } from './internal'

export const API_BASE = '/api'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`HTTP ${status} ${statusText}`)
    this.name = 'ApiError'
  }
}

export interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown
  /** When true, skip the error notification (caller handles UI inline). */
  silent?: boolean
  /**    * When false, skip the top loading bar. Defaults to true — the bar tracks network activity,
   * orthogonal to error visibility. Pass false for background pollers so the bar can idle while
   * they keep polling. */
  track?: boolean
  /** Timeout in ms. Default 15_000; 0 disables. A caller-provided `signal` is
   * respected and no timeout signal is added. */
  timeoutMs?: number
}

/**  * Centralized HTTP wrapper. Toasts on 4xx/5xx unless `silent: true`, and throws `ApiError` on
 * non-OK so callers can implement fallback UI. Network failures propagate without a toast —
 * SseStatusBadge covers SSE. */
export async function apiFetch<T = unknown>(url: string, opts: ApiFetchOptions = {}): Promise<T> {
  const { body, silent, track = true, timeoutMs = 15_000, ...init } = opts

  // Top loading bar: count this request while in flight. Guarded by
  // getActivePinia so specs importing the api module without an
  // installed pinia keep working — untracked in that case.
  const loading = track && getActivePinia() ? useLoadingStore() : null
  loading?.startApi()

  // Idle-freeze fix: hung backend must not park the UI forever.
  // Respect a caller-provided signal; otherwise arm a timeout signal.
  let signal: AbortSignal | undefined = init.signal as AbortSignal | undefined
  let timeoutId: ReturnType<typeof setTimeout> | undefined
  // Fallback controller when `AbortSignal.timeout` is unavailable
  // (older WebKit / jsdom). Only created when we need a timeout and
  // the caller did not provide their own signal.
  let fallbackController: AbortController | undefined
  if (!signal && timeoutMs > 0) {
    const withTimeout = (globalThis as { AbortSignal?: typeof AbortSignal }).AbortSignal
    if (withTimeout && typeof withTimeout.timeout === 'function') {
      signal = withTimeout.timeout(timeoutMs)
    } else if (typeof AbortController !== 'undefined') {
      fallbackController = new AbortController()
      signal = fallbackController.signal
      timeoutId = setTimeout(() => fallbackController?.abort(), timeoutMs)
    }
  }

  const fetchInit: RequestInit = {
    ...init,
    signal,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> | undefined),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }

  try {
    const response = await fetch(`${API_BASE}${url}`, fetchInit)

    if (!response.ok) {
      const responseBody = await response.text().catch(() => '')
      // Auth enforcement: expired/revoked session mid-use → bounce to /login?redirect=<current>
      // (router guard covers boot; this covers in-app expiry). Skip for auth endpoints themselves
      // and when already on /login to avoid loops.
      if (response.status === 401 && !url.startsWith('/auth/')) {
        try {
          const loc = globalThis.location
          if (loc && !loc.pathname.startsWith('/login')) {
            loc.href = `/login?redirect=${encodeURIComponent(loc.pathname + loc.search)}`
          }
        } catch {
          /* non-browser (vitest) — no redirect */
        }
      }

      if (!silent) {
        const parsedError = tryParseJsonErrorField(responseBody)
        const message = parsedError ?? `HTTP ${response.status} ${response.statusText}`
        const details = parsedError ? responseBody : responseBody || undefined
        useNotificationStore().notifyError(message, details)
      }

      throw new ApiError(response.status, response.statusText, responseBody)
    }

    // 204 No Content — return undefined cast to T
    if (response.status === 204) {
      return undefined as T
    }

    return (await response.json()) as T
  } finally {
    if (timeoutId !== undefined) clearTimeout(timeoutId)
    loading?.finishApi()
  }
}

// Re-export SseClient so call sites that hold a reference (e.g. `const workersSse: api.SseClient |
// null = null`) can import it from the same place they import the factory functions.
export type { SseClient } from '../helpers/sseClient'

// Health check
export async function healthCheck(): Promise<{
  status: string
  timestamp: number
}> {
  return await apiFetch<{ status: string; timestamp: number }>('/health')
}
