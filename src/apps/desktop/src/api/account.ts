import { ApiError, apiFetch } from './client'
import { tryParseJsonErrorField } from './internal'

// ─── Account: change your own password ──────────────────────────────────────
/** Mirrors `auth_password.zig`'s policy so the form can refuse locally what
 * the server would refuse anyway. */
export const CHANGE_PASSWORD_MIN_LENGTH = 8
export const CHANGE_PASSWORD_MAX_LENGTH = 72

export interface ChangePasswordResult {
  ok: boolean
  /** How many OTHER sessions the change signed out. */
  sessions_revoked: number
}

/** `POST /api/auth/password` — verify the current password, then rotate it.
 * `silent` because the form renders the rejection inline, next to the field. */
export async function changePassword(body: {
  current_password: string
  new_password: string
}): Promise<ChangePasswordResult> {
  return await apiFetch<ChangePasswordResult>('/auth/password', {
    method: 'POST',
    body,
    silent: true,
  })
}

/** The server's `{"error": "..."}` code from a failed `changePassword`.
 * Delegates the parse to `tryParseJsonErrorField` so this file adds no new
 * try/catch beyond the ones the lint baseline already carries. */
export function changePasswordErrorCode(err: unknown): string | null {
  if (!(err instanceof ApiError)) return null
  return tryParseJsonErrorField(err.body)
}
