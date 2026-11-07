package com.pabrik.mobile.projects

// Git commits helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object GitCommitsHelper {

    // Shorten a SHA to 7 characters.
    fun shortSha(sha: String): String = sha.take(7)

    // Format a commit message: first line only, trimmed.
    fun firstLine(message: String): String =
        message.trim().lines().firstOrNull()?.trim().orEmpty()

    // Whether a commit message is empty.
    fun isEmptyMessage(message: String): Boolean = message.trim().isEmpty()
}
