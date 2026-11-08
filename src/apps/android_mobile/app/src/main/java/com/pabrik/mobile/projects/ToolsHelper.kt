package com.pabrik.mobile.projects

// Tools helpers. Pure logic so they are unit-testable without a ViewModel
// or a network.
object ToolsHelper {

    fun isValidName(name: String): Boolean = name.trim().isNotEmpty()

    fun isDuplicate(name: String, existing: List<String>): Boolean =
        existing.any { it.equals(name.trim(), ignoreCase = true) }

    fun validateNew(name: String, existing: List<String>): String? {
        if (!isValidName(name)) return "NameRequired"
        if (isDuplicate(name, existing)) return "NameTaken"
        return null
    }
}
