package com.pabrik.mobile.git

data class ParsedDiffLine(
    val type: String,
    val content: String,
    val oldLineNum: Int?,
    val newLineNum: Int?,
    val lineIndex: Int,
)

data class ParsedDiff(
    val lines: List<ParsedDiffLine>,
    val added: Int,
    val removed: Int,
)

object UnifiedDiffParser {
    private val HUNK_HEADER = Regex("^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@(.*)?$")

    fun parse(diffText: String): ParsedDiff {
        val parsed = mutableListOf<ParsedDiffLine>()
        var added = 0
        var removed = 0
        var lineIndex = 0
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        for (line in diffText.split("\n")) {
            if (line.startsWith("diff --git") || line.startsWith("index ")) continue

            val hunk = HUNK_HEADER.find(line)
            if (hunk != null) {
                inHunk = true
                oldLine = hunk.groupValues[1].toIntOrNull() ?: 1
                newLine = hunk.groupValues[2].toIntOrNull() ?: 1
                parsed.add(ParsedDiffLine("hunk", line, null, null, lineIndex++))
                continue
            }

            if (!inHunk) continue

            if (line.isEmpty()) {
                parsed.add(ParsedDiffLine("empty", "", oldLine, newLine, lineIndex++))
                continue
            }

            when (line[0]) {
                '+' -> {
                    parsed.add(ParsedDiffLine("add", line.substring(1), null, newLine, lineIndex++))
                    added++
                    newLine++
                }
                '-' -> {
                    parsed.add(ParsedDiffLine("remove", line.substring(1), oldLine, null, lineIndex++))
                    removed++
                    oldLine++
                }
                ' ' -> {
                    parsed.add(ParsedDiffLine("context", line.substring(1), oldLine, newLine, lineIndex++))
                    oldLine++
                    newLine++
                }
                else -> {
                    parsed.add(ParsedDiffLine("context", line, oldLine, newLine, lineIndex++))
                    oldLine++
                    newLine++
                }
            }
        }

        return ParsedDiff(parsed, added, removed)
    }
}
