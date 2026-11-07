package com.pabrik.mobile.projects

// Members helpers. Pure logic so they are unit-testable without a ViewModel
// or a network.
object MembersHelper {

    fun isValidEmail(email: String): Boolean =
        email.trim().contains("@") && email.trim().contains(".")

    fun isDuplicate(email: String, existing: List<String>): Boolean =
        existing.any { it.equals(email.trim(), ignoreCase = true) }

    fun validateInvite(email: String, existing: List<String>): String? {
        if (!isValidEmail(email)) return "InvalidEmail"
        if (isDuplicate(email, existing)) return "AlreadyMember"
        return null
    }
}
