package com.pabrik.mobile.projects

// Pull request helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object PullRequestHelper {

    // Whether a PR state is open.
    fun isOpen(state: String): Boolean = state.equals("open", ignoreCase = true)

    // Whether a PR state is merged.
    fun isMerged(state: String): Boolean = state.equals("merged", ignoreCase = true)

    // Format a PR title with its number.
    fun formatTitle(number: Int, title: String): String = "#$number $title"

    // Whether a PR is mergeable (open and not draft).
    fun isMergeable(state: String, draft: Boolean): Boolean = isOpen(state) && !draft
}
