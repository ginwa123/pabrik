import { ApiError, apiFetch } from './client'
import { tryParseJsonErrorField } from './internal'

// ─── Account: change your own password ──────────────────────────────────────
export const CHANGE_PASSWORD_MIN_LENGTH = 8
export const CHANGE_PASSWORD_MAX_LENGTH = 72

export interface ChangePasswordResult {
  ok: boolean
  /** How many OTHER sessions the change signed out. */
  sessions_revoked: number
}

/** `POST /api/auth/password` — verify the current password, then rotate it. */
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

/** The server's `{"error": "..."}` code from a failed `changePassword`. */
export function changePasswordErrorCode(err: unknown): string | null {
  if (!(err instanceof ApiError)) return null
  return tryParseJsonErrorField(err.body)
}
