package com.pabrik.mobile.projects

// Git changes helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object GitChangesHelper {

    // Parse a git status code into a human-readable label.
    fun statusLabel(code: String): String = when (code.trim().uppercase()) {
        "M" -> "Modified"
        "A" -> "Added"
        "D" -> "Deleted"
        "R" -> "Renamed"
        "C" -> "Copied"
        "U" -> "Unmerged"
        "??" -> "Untracked"
        else -> "Unknown"
    }

    // Whether a status code indicates a modified (not new) file.
    fun isModified(code: String): Boolean = code.trim().uppercase() == "M"

    // Count files by status.
    fun countByStatus(codes: List<String>): Map<String, Int> =
        codes.groupingBy { statusLabel(it) }.eachCount()
}
