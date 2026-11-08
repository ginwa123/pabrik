package com.pabrik.mobile.projects

// Worktree helpers. Pure logic so they are unit-testable without a ViewModel
// or a network.
object WorktreeHelper {

    // Whether a branch name is valid (non-empty, no spaces, no special chars).
    fun isValidBranchName(name: String): Boolean =
        name.trim().isNotEmpty() && !name.contains(' ') && !name.contains("..")

    // Format a worktree path from a base dir and branch name.
    fun formatPath(baseDir: String, branch: String): String =
        "$baseDir/${branch.replace('/', '-')}"

    // Whether a worktree is the main worktree (no branch suffix).
    fun isMainWorktree(branch: String?): Boolean = branch.isNullOrEmpty()
}
