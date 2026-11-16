package com.pabrik.mobile.chat

/** A line of a two-sided diff, in transcript order. */
data class DiffRow(
    val kind: DiffRowKind,
    val beforeLine: Int?,
    val afterLine: Int?,
    val text: String,
)

enum class DiffRowKind {
    Context,
    Added,
    Removed,
}

/** Line diff for `text_replace` results and the generic `diffview_before` /`diffview_after` fallback. */
object ToolDiff {
    /** 250k cells ≈ 500×500 lines. 1 MB of `IntArray`, well inside one frame. */
    const val MAX_CELLS = 250_000L

    /** The file body is not truncated: a truncated diff is a lie about the file. */
    fun compute(before: String, after: String): List<DiffRow> {
        val beforeLines = splitLines(before)
        val afterLines = splitLines(after)

        if (beforeLines.isEmpty() && afterLines.isEmpty()) return emptyList()
        if (beforeLines.isEmpty()) {
            return afterLines.mapIndexed { index, text ->
                DiffRow(DiffRowKind.Added, null, index + 1, text)
            }
        }
        if (afterLines.isEmpty()) {
            return beforeLines.mapIndexed { index, text ->
                DiffRow(DiffRowKind.Removed, index + 1, null, text)
            }
        }
        if (beforeLines == afterLines) {
            return beforeLines.mapIndexed { index, text ->
                DiffRow(DiffRowKind.Context, index + 1, index + 1, text)
            }
        }

        if (beforeLines.size.toLong() * afterLines.size.toLong() > MAX_CELLS) {
            return buildList {
                beforeLines.forEachIndexed { index, text ->
                    add(DiffRow(DiffRowKind.Removed, index + 1, null, text))
                }
                afterLines.forEachIndexed { index, text ->
                    add(DiffRow(DiffRowKind.Added, null, index + 1, text))
                }
            }
        }

        return lcsDiff(beforeLines, afterLines)
    }

    private fun lcsDiff(before: List<String>, after: List<String>): List<DiffRow> {
        val rows = before.size
        val columns = after.size

        // table[i][j] = length of the longest common subsequence of before[i..] and after[j..].
        val table = Array(rows + 1) { IntArray(columns + 1) }
        for (i in rows - 1 downTo 0) {
            for (j in columns - 1 downTo 0) {
                table[i][j] = if (before[i] == after[j]) {
                    table[i + 1][j + 1] + 1
                } else {
                    maxOf(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        val out = ArrayList<DiffRow>(rows + columns)
        var i = 0
        var j = 0
        while (i < rows && j < columns) {
            when {
                before[i] == after[j] -> {
                    out.add(DiffRow(DiffRowKind.Context, i + 1, j + 1, before[i]))
                    i++
                    j++
                }

                // Deletions are emitted before insertions so a replacement reads as "old line, new line" rather than "new line, old line", which is the order a reader scanning a …
                table[i + 1][j] >= table[i][j + 1] -> {
                    out.add(DiffRow(DiffRowKind.Removed, i + 1, null, before[i]))
                    i++
                }

                else -> {
                    out.add(DiffRow(DiffRowKind.Added, null, j + 1, after[j]))
                    j++
                }
            }
        }
        while (i < rows) {
            out.add(DiffRow(DiffRowKind.Removed, i + 1, null, before[i]))
            i++
        }
        while (j < columns) {
            out.add(DiffRow(DiffRowKind.Added, null, j + 1, after[j]))
            j++
        }
        return out
    }

    /** Splits on newlines, dropping the single empty trailing entry a final `\n` produces. */
    fun splitLines(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val lines = text.split("\n").toMutableList()
        if (lines.isNotEmpty() && lines.last().isEmpty()) lines.removeAt(lines.lastIndex)
        return lines
    }
}
