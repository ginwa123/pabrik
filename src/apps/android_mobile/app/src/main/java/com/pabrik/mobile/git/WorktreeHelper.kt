package com.pabrik.mobile.git

object WorktreeHelper {
    private val BASENAME = Regex("[A-Za-z0-9._-]{1,100}")

    fun fullPath(parentDir: String, basename: String): String {
        val base = if (parentDir.endsWith("/")) parentDir.dropLast(1) else parentDir
        val trimmed = basename.trim()
        return if (trimmed.isEmpty()) "$base/" else "$base/$trimmed"
    }

    fun isValidBasename(name: String): Boolean = BASENAME.matches(name.trim())

    fun canSubmit(basename: String, parentDir: String, submitting: Boolean): Boolean =
        !submitting && basename.trim().isNotEmpty() && parentDir.trim().isNotEmpty()

    fun branchName(basename: String): String = "worktree/${basename.trim()}"
}
