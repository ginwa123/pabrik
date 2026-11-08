package com.pabrik.mobile.git

data class GitFileChange(
    val indexStatus: String,
    val worktreeStatus: String,
    val path: String,
)

object GitChangesHelper {

    fun statusText(status: String): String = when (status) {
        "M" -> "Modified"
        "A" -> "Added"
        "D" -> "Deleted"
        "R" -> "Renamed"
        "C" -> "Copied"
        "??" -> "Untracked"
        else -> "Changed"
    }

    fun isUntracked(indexStatus: String): Boolean = indexStatus == "??"

    fun isStaged(indexStatus: String): Boolean =
        indexStatus.isNotBlank() && indexStatus != "??"

    fun displayStatus(indexStatus: String, worktreeStatus: String): String = when {
        isUntracked(indexStatus) -> "Untracked"
        indexStatus.isNotBlank() -> statusText(indexStatus)
        worktreeStatus.isNotBlank() -> statusText(worktreeStatus)
        else -> "Changed"
    }

    fun branchLabel(branch: String?): String =
        if (branch.isNullOrBlank()) "no branch" else branch

    fun totalChanges(staged: List<GitFileChange>, modified: List<GitFileChange>, untracked: List<GitFileChange>): Int =
        staged.size + modified.size + untracked.size
}
