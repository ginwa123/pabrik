package com.pabrik.mobile.chat

/** Markdown → blocks, for the chat transcript. */
internal object Markdown {

    /** Parse a whole message body into blocks. */
    fun parse(source: String): List<MdBlock> {
        if (source.isBlank()) return emptyList()
        return try {
            parseBlocks(source.replace("\r\n", "\n").replace('\r', '\n').split('\n'))
        } catch (_: Exception) {
            val fallback = paragraph(source.trim())
            if (fallback.spans.isEmpty()) emptyList() else listOf(fallback)
        }
    }

    /** True when the source has something to draw once the envelope is off. */
    fun hasContent(source: String): Boolean = stripContentEnvelope(source).isNotBlank()

    // ── Block level ─────────────────────────────────────────────────────────

    private fun parseBlocks(lines: List<String>): List<MdBlock> {
        val blocks = mutableListOf<MdBlock>()
        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            when {
                line.isBlank() -> index++

                isFence(line) != null -> {
                    val fence = isFence(line)!!
                    val info = line.trimStart('`', '~').trim()
                    val body = mutableListOf<String>()
                    index++
                    while (index < lines.size && !closesFence(lines[index], fence)) {
                        body.add(lines[index])
                        index++
                    }
                    // Skip the closing fence when there is one; an unterminated block still renders, because half a code block beats none.
                    if (index < lines.size) index++
                    blocks += MdBlock.Code(
                        language = info.substringBefore(' ').takeIf { it.isNotBlank() },
                        code = body.joinToString("\n"),
                    )
                }

                isRule(line) -> {
                    blocks += MdBlock.Rule
                    index++
                }

                headingLevel(line) != null -> {
                    val level = headingLevel(line)!!
                    blocks += MdBlock.Heading(
                        level = level,
                        spans = parseInline(line.trimStart().drop(level).trimStart()),
                    )
                    index++
                }

                line.trimStart().startsWith('>') -> {
                    val quoted = mutableListOf<String>()
                    while (index < lines.size && lines[index].trimStart().startsWith('>')) {
                        quoted += lines[index].trimStart().removePrefix(">").removePrefix(" ")
                        index++
                    }
                    blocks += MdBlock.Quote(parseBlocks(quoted))
                }

                listMarker(line) != null -> index = readList(lines, index, blocks)

                tableAt(lines, index) != null -> {
                    val (header, rows) = tableAt(lines, index)!!
                    blocks += MdBlock.Table(header, rows)
                    index += 2 + rows.size
                }

                else -> {
                    val paragraph = mutableListOf<String>()
                    while (index < lines.size) {
                        val current = lines[index]
                        if (current.isBlank() || isFence(current) != null || isRule(current) ||
                            headingLevel(current) != null || current.trimStart().startsWith('>') ||
                            listMarker(current) != null || tableAt(lines, index) != null
                        ) {
                            break
                        }
                        paragraph += current.trim()
                        index++
                    }
                    paragraph(paragraph.joinToString(" "))
                        .takeIf { it.spans.isNotEmpty() }
                        ?.let { blocks += it }
                }
            }
        }
        return blocks
    }

    /** Read a whole bullet or ordered list, including one nesting level. */
    private fun readList(lines: List<String>, start: Int, blocks: MutableList<MdBlock>): Int {
        val first = listMarker(lines[start])!!
        val ordered = first.ordered
        val startNumber = first.number
        val items = mutableListOf<List<MdSpan>>()
        var index = start
        while (index < lines.size) {
            val marker = listMarker(lines[index]) ?: break
            if (marker.ordered != ordered) break
            val indent = (lines[index].length - lines[index].trimStart().length).coerceAtLeast(0)
            val body = mutableListOf(marker.rest)
            index++
            // Lazy continuation: a following non-blank, non-marker line belongs to the item above, so a wrapped bullet is not split in two.
            while (index < lines.size) {
                val next = lines[index]
                if (next.isBlank() || listMarker(next) != null || isFence(next) != null) break
                body += next.trim()
                index++
            }
            items += if (indent >= 2) {
                listOf(MdSpan("•  ")) + parseInline(body.joinToString(" "))
            } else {
                parseInline(body.joinToString(" "))
            }
        }
        if (items.isNotEmpty()) blocks += MdBlock.ListBlock(ordered, startNumber, items)
        return index
    }

    /** `---`, `***`, `___` on a line of their own, or the setext `===` under a paragraph. */
    private fun isRule(line: String): Boolean {
        val trimmed = line.trim()
        if (trimmed.length < 3) return false
        val c = trimmed[0]
        if (c != '-' && c != '*' && c != '_') return false
        return trimmed.all { it == c || it == ' ' }
    }

    private fun headingLevel(line: String): Int? {
        val trimmed = line.trimStart()
        if (!trimmed.startsWith('#')) return null
        val hashes = trimmed.takeWhile { it == '#' }
        // Seven or more `#` is a paragraph, not a heading, and a heading needs a space after the run — `#tag` is not a heading.
        if (hashes.length !in 1..6) return null
        if (trimmed.length == hashes.length || !trimmed[hashes.length].isWhitespace()) return null
        return hashes.length
    }

    private data class Marker(val ordered: Boolean, val number: Int, val rest: String)

    private fun listMarker(line: String): Marker? {
        val trimmed = line.trimStart()
        if (trimmed.isEmpty()) return null
        val c = trimmed[0]
        if (c == '-' || c == '*' || c == '+') {
            val rest = trimmed.drop(1)
            if (rest.isNotEmpty() && !rest[0].isWhitespace()) return null
            return Marker(ordered = false, number = 0, rest = rest.trim())
        }
        val digits = trimmed.takeWhile { it.isDigit() }
        if (digits.isEmpty() || digits.length > 9) return null
        val afterDigits = trimmed.drop(digits.length)
        if (!afterDigits.startsWith('.') && !afterDigits.startsWith(')')) return null
        val rest = afterDigits.drop(1)
        if (rest.isNotEmpty() && !rest[0].isWhitespace()) return null
        return Marker(ordered = true, number = digits.toInt(), rest = rest.trim())
    }

    private fun isFence(line: String): Char? {
        val trimmed = line.trimStart()
        return when {
            trimmed.startsWith("```") -> '`'
            trimmed.startsWith("~~~") -> '~'
            else -> null
        }
    }

    private fun closesFence(line: String, fence: Char): Boolean {
        val trimmed = line.trim()
        val marker = if (fence == '`') "```" else "~~~"
        return trimmed.startsWith(marker) && trimmed.all { it == fence }
    }

    /** A table needs a header row AND a delimiter row under it, which is the only reliable signal — a paragraph mentioning pipes is not a table. */
    private fun tableAt(lines: List<String>, index: Int): Pair<List<List<MdSpan>>, List<List<List<MdSpan>>>>? {
        val header = lines.getOrNull(index) ?: return null
        val delimiter = lines.getOrNull(index + 1) ?: return null
        if (!header.contains('|')) return null
        if (!isDelimiterRow(delimiter)) return null
        val headerCells = splitRow(header)
        if (headerCells.isEmpty()) return null
        val rows = mutableListOf<List<List<MdSpan>>>()
        var cursor = index + 2
        while (cursor < lines.size && lines[cursor].isNotBlank() && lines[cursor].contains('|')) {
            rows += splitRow(lines[cursor]).map { parseInline(it) }
            cursor++
        }
        return headerCells.map { parseInline(it) } to rows
    }

    private fun isDelimiterRow(line: String): Boolean {
        val cells = splitRow(line)
        if (cells.isEmpty()) return false
        return cells.all { cell ->
            cell.isNotEmpty() && cell.all { it == '-' || it == ':' || it == ' ' }
        }
    }

    /** Split one `| a | b |` row, dropping the empty cells the leading and trailing pipes create. */
    private fun splitRow(line: String): List<String> {
        val trimmed = line.trim().removePrefix("|").removeSuffix("|")
        if (trimmed.isBlank()) return emptyList()
        return trimmed.split('|').map { it.trim() }
    }

    // ── Inline level ────────────────────────────────────────────────────────

    /** Parse one line's inline markup into styled spans. */
    fun parseInline(text: String): List<MdSpan> {
        if (text.isEmpty()) return emptyList()
        val spans = mutableListOf<MdSpan>()
        val buffer = StringBuilder()
        var index = 0

        fun flush() {
            if (buffer.isNotEmpty()) {
                spans += MdSpan(buffer.toString())
                buffer.setLength(0)
            }
        }

        while (index < text.length) {
            val c = text[index]

            // A backslash escapes the next character, which is how a model writes a literal `\*` without meaning to emphasise anything.
            if (c == '\\' && index + 1 < text.length) {
                buffer.append(text[index + 1])
                index += 2
                continue
            }

            if (c == '`') {
                val end = text.indexOf('`', index + 1)
                if (end > index + 1) {
                    flush()
                    spans += MdSpan(text.substring(index + 1, end), code = true)
                    index = end + 1
                    continue
                }
            }

            if (c == '[') {
                val link = readLink(text, index)
                if (link != null) {
                    flush()
                    parseInline(link.first).forEach { spans += it.copy(link = link.second) }
                    index = link.third
                    continue
                }
            }

            val marker = EMPHASIS_MARKERS.firstOrNull { text.startsWith(it, index) }
            if (marker != null) {
                val emphasis = readEmphasis(text, index, marker)
                if (emphasis != null) {
                    val (inner, next) = emphasis
                    flush()
                    parseInline(inner).forEach { spans += merge(it, marker) }
                    index = next
                    continue
                }
            }

            buffer.append(c)
            index++
        }
        flush()
        return spans
    }

    private fun merge(span: MdSpan, marker: String): MdSpan = when (marker) {
        "***", "___" -> span.copy(bold = true, italic = true)
        "**", "__" -> span.copy(bold = true)
        "~~" -> span.copy(strike = true)
        else -> span.copy(italic = true)
    }

    private val EMPHASIS_MARKERS = listOf("***", "___", "**", "__", "~~", "*", "_")

    /** A matched `[label](url)` at [start], or null. */
    private fun readLink(text: String, start: Int): Triple<String, String, Int>? {
        val labelEnd = text.indexOf(']', start + 1)
        if (labelEnd < 0) return null
        if (labelEnd + 1 >= text.length || text[labelEnd + 1] != '(') return null
        val urlEnd = text.indexOf(')', labelEnd + 2)
        if (urlEnd < 0) return null
        val label = text.substring(start + 1, labelEnd)
        val url = text.substring(labelEnd + 2, urlEnd).trim()
        // An empty label is a shortcut reference link, not an inline one.
        if (label.isEmpty()) return null
        return Triple(label, url, urlEnd + 1)
    }

    /** A matched emphasis marker at [start], or null when there is no closer. */
    private fun readEmphasis(text: String, start: Int, marker: String): Pair<String, Int>? {
        if (marker[0] == '_') {
            val before = text.getOrNull(start - 1)
            if (before != null && (before.isLetterOrDigit() || before == '_')) return null
        }
        // A marker glued to the preceding character is punctuation, not emphasis: `(**bold**)` opens on `(`, and `2**3` is arithmetic.
        val bodyStart = start + marker.length
        if (bodyStart >= text.length) return null
        var cursor = bodyStart
        while (cursor < text.length && text[cursor] == ' ') cursor++
        if (cursor >= text.length) return null
        val closer = text.indexOf(marker, cursor)
        if (closer <= cursor) return null
        if (marker.length == 1 && text.substring(cursor, closer).isBlank()) return null
        // Whitespace cannot sit at an emphasis boundary, so `a * b * c` is not emphasised — same rule the CommonMark spec applies.
        if (text[cursor].isWhitespace()) return null
        val inner = text.substring(cursor, closer)
        if (inner.isBlank()) return null
        if (text.getOrNull(closer + marker.length)?.isWhitespace() == false &&
            marker.length == 1 &&
            text.getOrNull(closer + 1)?.isLetterOrDigit() == true
        ) {
            return null
        }
        return inner to (closer + marker.length)
    }
}

/** One styled run of text within a line. */
internal data class MdSpan(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    val strike: Boolean = false,
    /** Non-null when this run is inside a `[label](url)`. */
    val link: String? = null,
)

/** One block of a parsed message. */
internal sealed interface MdBlock {

    /** `#` through `######`. */
    data class Heading(val level: Int, val spans: List<MdSpan>) : MdBlock

    data class Paragraph(val spans: List<MdSpan>) : MdBlock

    /** A bullet or ordered list. */
    data class ListBlock(
        val ordered: Boolean,
        val start: Int,
        val items: List<List<MdSpan>>,
    ) : MdBlock

    /** A fenced or indented code block, verbatim. */
    data class Code(val language: String?, val code: String) : MdBlock

    data class Quote(val blocks: List<MdBlock>) : MdBlock

    data class Table(
        val header: List<List<MdSpan>>,
        val rows: List<List<List<MdSpan>>>,
    ) : MdBlock

    data object Rule : MdBlock
}

/** A paragraph from raw text, so one code path builds the spans. */
private fun paragraph(raw: String): MdBlock.Paragraph = MdBlock.Paragraph(Markdown.parseInline(raw))
