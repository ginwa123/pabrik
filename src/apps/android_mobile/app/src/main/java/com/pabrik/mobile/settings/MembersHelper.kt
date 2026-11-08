package com.pabrik.mobile.settings

object MembersHelper {
    private val RANK = mapOf("viewer" to 0, "editor" to 1, "admin" to 2, "owner" to 3)

    fun rank(role: String): Int = RANK[role] ?: -1

    fun canManage(role: String): Boolean = rank(role) >= rank("admin")

    fun canEdit(role: String): Boolean = rank(role) >= rank("editor")

    fun isValidEmail(email: String): Boolean {
        val e = email.trim()
        if (e.contains(' ')) return false
        val at = e.indexOf('@')
        if (at <= 0 || at != e.lastIndexOf('@') || at == e.length - 1) return false
        val domain = e.substring(at + 1)
        return domain.contains('.') && !domain.startsWith('.') && !domain.endsWith('.')
    }

    fun invitationStatus(accepted: Boolean, declined: Boolean): String = when {
        accepted -> "accepted"
        declined -> "declined"
        else -> "pending"
    }
}
