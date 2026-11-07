package com.pabrik.mobile.projects

// Secrets helpers. Pure logic so they are unit-testable without a ViewModel
// or a network.
object SecretsHelper {

    fun isValidName(name: String): Boolean = name.trim().isNotEmpty()

    // Whether [name] already exists among [existing] names.
    fun isDuplicate(name: String, existing: List<String>): Boolean =
        existing.any { it.equals(name.trim(), ignoreCase = true) }

    // Validate a new secret. Returns null on success, error code on failure.
    fun validateNew(name: String, existing: List<String>): String? {
        if (!isValidName(name)) return "NameRequired"
        if (isDuplicate(name, existing)) return "NameTaken"
        return null
    }
}
