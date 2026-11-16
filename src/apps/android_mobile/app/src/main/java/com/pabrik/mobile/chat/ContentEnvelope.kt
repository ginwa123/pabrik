package com.pabrik.mobile.chat

/** Peels the transport envelope off an assistant turn's content. */
private val THINK_BLOCK = Regex("<think>([\\s\\S]*?)<\\/think>", RegexOption.IGNORE_CASE)
private val OPEN_PLAIN = Regex("<plain>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_PLAIN = Regex("\\s*</plain>", RegexOption.IGNORE_CASE)
private val OPEN_MARKDOWN = Regex("<markdown>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_MARKDOWN = Regex("\\s*</markdown>", RegexOption.IGNORE_CASE)
private val OPEN_HTML = Regex("<html>\\s*", RegexOption.IGNORE_CASE)
private val CLOSE_HTML = Regex("\\s*</html>", RegexOption.IGNORE_CASE)

/** The whole body fenced in a language that names a *document*, not code. */
private val FENCED_DOCUMENT = Regex(
    "```[ \\t]*(?:html|markdown|md|xml|svg|plain|text)[ \\t]*\\n(?<body>.*?)\\n?```[ \\t]*\\s*$",
    setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
)

/** Every wrapper above needs a `<`, and the document fence needs the turn to open with one. */
private fun canCarryEnvelope(trimmed: String): Boolean =
    trimmed.indexOf('<') >= 0 || trimmed.startsWith("```")

/** [pattern].replace, but only when there is something to replace. */
private fun String.withoutIfPresent(pattern: Regex, replacement: String): String =
    if (pattern.containsMatchIn(this)) pattern.replace(this, replacement) else this

/** The content a renderer should actually show. */
fun stripContentEnvelope(content: String): String {
    val trimmed = content.trim()
    if (trimmed.isEmpty()) return ""
    if (!canCarryEnvelope(trimmed)) return trimmed

    val hasThink = THINK_BLOCK.containsMatchIn(trimmed)
    val hasWrapper = hasAnyWrapper(trimmed)
    if (hasThink && !hasWrapper) return trimmed

    val result = trimmed
        .withoutIfPresent(THINK_BLOCK, "")
        .withoutIfPresent(OPEN_PLAIN, "")
        .withoutIfPresent(CLOSE_PLAIN, "")
        .withoutIfPresent(OPEN_MARKDOWN, "")
        .withoutIfPresent(CLOSE_MARKDOWN, "")
        .withoutIfPresent(OPEN_HTML, "")
        .withoutIfPresent(CLOSE_HTML, "")
        .trim()
    // Named group, not `$1`: the language alternation is non-capturing precisely so the body is the only group, and a stray `$1` here replaces the answer with the …
    return result.withoutIfPresent(FENCED_DOCUMENT, "\${body}").trim()
}

private fun hasAnyWrapper(text: String): Boolean =
    OPEN_PLAIN.containsMatchIn(text) ||
        CLOSE_PLAIN.containsMatchIn(text) ||
        OPEN_MARKDOWN.containsMatchIn(text) ||
        CLOSE_MARKDOWN.containsMatchIn(text) ||
        OPEN_HTML.containsMatchIn(text) ||
        CLOSE_HTML.containsMatchIn(text)
