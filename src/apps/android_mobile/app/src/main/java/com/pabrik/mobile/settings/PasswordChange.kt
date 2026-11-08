package com.pabrik.mobile.settings

object PasswordChange {
    const val MIN_LENGTH = 8
    const val MAX_LENGTH = 72

    fun newPasswordError(current: String, next: String): String? {
        if (next.isEmpty()) return null
        if (next.length < MIN_LENGTH) return "TooShort"
        if (next.length > MAX_LENGTH) return "TooLong"
        if (next == current) return "Unchanged"
        return null
    }

    fun confirmError(next: String, confirm: String): String? =
        if (confirm.isNotEmpty() && confirm != next) "Mismatch" else null

    fun canSubmit(current: String, next: String, confirm: String): Boolean =
        current.isNotEmpty() &&
            next.length in MIN_LENGTH..MAX_LENGTH &&
            next != current &&
            confirm == next

    fun successNote(revoked: Int): String = when {
        revoked <= 0 -> "Password changed. No other device was signed in."
        revoked == 1 -> "Password changed. One other device was signed out."
        else -> "Password changed. $revoked other devices were signed out."
    }
}
