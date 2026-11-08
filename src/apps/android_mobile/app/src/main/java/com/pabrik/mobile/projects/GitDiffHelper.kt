package com.pabrik.mobile.projects

// Git diff helpers. Pure logic so they are unit-testable without a ViewModel
// or a network.
object GitDiffHelper {

    // Whether a diff line is an addition.
    fun isAdded(line: String): Boolean = line.startsWith("+") && !line.startsWith("+++")

    // Whether a diff line is a deletion.
    fun isDeleted(line: String): Boolean = line.startsWith("-") && !line.startsWith("---")

    // Whether a diff line is a hunk header.
    fun isHunkHeader(line: String): Boolean = line.startsWith("@@")

    // Count additions and deletions in a diff.
    fun countChanges(diff: String): Pair<Int, Int> {
        var added = 0
        var deleted = 0
        for (line in diff.lines()) {
            if (isAdded(line)) added++
            else if (isDeleted(line)) deleted++
        }
        return added to deleted
    }
}
