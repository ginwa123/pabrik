package com.pabrik.mobile.projects

// Secrets rotate/reveal helpers. Pure logic so they are unit-testable
// without a ViewModel or a network.
object SecretsRotate {

    fun isValidValue(value: String): Boolean = value.isNotEmpty()

    // Whether the new value differs from the current one.
    fun isChanged(current: String, next: String): Boolean = current != next

    // Validate a rotate request. Returns null on success, error code on failure.
    fun validateRotate(current: String, next: String): String? {
        if (!isValidValue(next)) return "ValueRequired"
        if (!isChanged(current, next)) return "ValueUnchanged"
        return null
    }
}
