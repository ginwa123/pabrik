package com.pabrik.mobile.git

object PullRequestHelper {

    fun isOpen(state: String): Boolean = state == "open"

    fun stateLabel(state: String): String = when (state) {
        "open" -> "Open"
        "closed" -> "Closed"
        "merged" -> "Merged"
        "draft" -> "Draft"
        else -> "Unknown"
    }

    fun numberLabel(number: Int): String = "#$number"

    fun openCountBadge(count: Int?): String = count?.toString() ?: ""

    fun isValidBranchName(name: String): Boolean {
        val n = name.trim()
        if (n.isEmpty()) return false
        if (n.startsWith("-") || n.startsWith("/") || n.endsWith("/")) return false
        if (n.contains("..") || n.contains(" ") || n.contains("~")) return false
        return n.none { it in "^:?*[\\" }
    }

    fun titleFromBranch(branch: String): String =
        branch.substringAfterLast('/')
            .replace('-', ' ')
            .replace('_', ' ')
            .trim()
            .replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
}
