package com.pabrik.mobile.auth

// Password change helpers. Pure logic so they are unit-testable without a
// ViewModel or a network. Mirrors Vue's CHANGE_PASSWORD_MIN/MAX_LENGTH.
object PasswordChange {
    const val MIN_LENGTH = 8
    const val MAX_LENGTH = 72

    fun isValidLength(password: String): Boolean =
        password.length in MIN_LENGTH..MAX_LENGTH

    fun isUnchanged(current: String, next: String): Boolean = current == next

    // Validate a change request. Returns null on success, error code on failure.
    fun validate(current: String, next: String): String? {
        if (!isValidLength(next)) {
            return if (next.length < MIN_LENGTH) "PasswordTooShort" else "PasswordTooLong"
        }
        if (isUnchanged(current, next)) return "PasswordUnchanged"
        return null
    }
}
