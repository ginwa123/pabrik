package com.pabrik.mobile.chat

/** Finds the `<html>` payloads inside one assistant turn and splits the rest out as prose. */
internal object HtmlResponse {

    /** How many live frames one turn may hold. */
    const val MAX_LIVE_FRAMES = 3

    /** True when this turn carries at least one finished HTML payload. */
    fun isHtmlTurn(content: String, isComplete: Boolean = true): Boolean {
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return false
        if (!isCandidate(trimmed)) return false
        return segments(trimmed, isComplete).any { it is ResponseSegment.Document }
    }

    /** The turn as an ordered run of prose and documents. */
    fun segments(content: String, isComplete: Boolean = true): List<ResponseSegment> {
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return emptyList()

        // Reasoning is not part of the payload, and a turn that thinks out loud then renders a page carries the `<think>` block *outside* the html wrapper.
        val withoutThink = THINK_BLOCK.replace(trimmed, "").trim()
        if (withoutThink.isEmpty()) return emptyList()

        // A whole-message fence, tried first because a fence is the strongest evidence there is: it can only be closed at the end of the turn, so the document inside it …
        unfence(withoutThink)?.let { fenced ->
            if (isCandidate(fenced)) {
                return listOf(ResponseSegment.Document(fenced.trim()))
            }
            // A ```markdown fence is prose, not a document.
        }

        val blocks = HTML_BLOCK.findAll(withoutThink).toList()
        if (blocks.isNotEmpty()) {
            val segments = mutableListOf<ResponseSegment>()
            var cursor = 0
            blocks.forEach { match ->
                addProse(segments, withoutThink.substring(cursor, match.range.first))
                val inner = match.groupValues[1].trim()
                if (inner.isNotEmpty()) {
                    // A closed `<html>…</html>` is finished by construction, exactly like a closed fence.
                    segments += ResponseSegment.Document(inner)
                }
                cursor = match.range.last + 1
            }
            addProse(segments, withoutThink.substring(cursor))
            return segments
        }

        val bare = unwrapPlain(withoutThink)
        if (!isCandidate(bare)) return listOf(ResponseSegment.Prose(withoutThink))

        return if (isDrawableDocument(bare, isComplete)) {
            listOf(ResponseSegment.Document(bare.trim()))
        } else {
            // Still arriving.
            listOf(ResponseSegment.Prose(withoutThink))
        }
    }

    /** Whether the [documentIndex]-th document in one turn gets a live frame. */
    fun getsLiveFrame(documentIndex: Int): Boolean = documentIndex < MAX_LIVE_FRAMES

    // ── Detection ───────────────────────────────────────────────────────────

    /** The first non-blank line opens a document. */
    private val DOCUMENT_OPENER = Regex(
        "^\\s*<(?:!doctype\\s+html|html|head|body|style|script|div|section|main|article|" +
            "header|footer|nav|aside|span|p|table|meta|link|template|figure|svg|canvas|" +
            "form|iframe|ul|ol|dl|h[1-6])\\b",
        RegexOption.IGNORE_CASE,
    )

    /** Whether this text could possibly hold a document. */
    private fun isCandidate(text: String): Boolean {
        if (text.indexOf('<') < 0) return false
        return DOCUMENT_OPENER.containsMatchIn(text) ||
            HTML_BLOCK.containsMatchIn(text) ||
            UNFENCED.containsMatchIn(text)
    }

    /** True when [document] is finished. */
    private fun isDrawableDocument(document: String, isComplete: Boolean): Boolean =
        isComplete ||
            CLOSING_HTML.containsMatchIn(document) ||
            CLOSING_BODY.containsMatchIn(document)

    /** The body of a fence that wraps the *whole* turn, or null. */
    private fun unfence(text: String): String? {
        val match = WHOLE_FENCE.find(text) ?: return null
        val language = match.groups["lang"]?.value.orEmpty()
        if (language.isNotEmpty() && !language.equals("html", ignoreCase = true)) return null
        return match.groups["body"]?.value
    }

    /** `<plain>…</plain>` off, so a wrapped document is seen bare. */
    private fun unwrapPlain(text: String): String = text
        .replace(PLAIN_OPEN, "")
        .replace(PLAIN_CLOSE, "")
        .trim()

    /** Append a prose run, unless it is only whitespace. */
    private fun addProse(into: MutableList<ResponseSegment>, raw: String) {
        val text = raw.trim()
        if (text.isNotEmpty()) into += ResponseSegment.Prose(text)
    }

    private val THINK_BLOCK = Regex("<think>([\\s\\S]*?)<\\/?think\\s*>", RegexOption.IGNORE_CASE)
    private val HTML_BLOCK =
        Regex("<html(?:\\s[^>]*)?>([\\s\\S]*?)</html\\s*>", RegexOption.IGNORE_CASE)
    private val UNFENCED = Regex("^\\s*<!doctype\\s+html", RegexOption.IGNORE_CASE)
    private val CLOSING_HTML = Regex("</html\\s*>", RegexOption.IGNORE_CASE)
    private val CLOSING_BODY = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
    private val PLAIN_OPEN = Regex("<plain\\s*>", RegexOption.IGNORE_CASE)
    private val PLAIN_CLOSE = Regex("</plain\\s*>", RegexOption.IGNORE_CASE)
    private val WHOLE_FENCE = Regex(
        "^[ \\t]*(?<fence>`{3,}|~{3,})[ \\t]*(?<lang>[A-Za-z0-9_+.-]*)[ \\t]*\\r?\\n" +
            "(?<body>[\\s\\S]*?)\\r?\\n?[ \\t]*\\k<fence>[ \\t]*$",
    )
}

/** One piece of an assistant turn. */
internal sealed interface ResponseSegment {

    /** Text the reader reads as prose — everything outside an html block. */
    data class Prose(val text: String) : ResponseSegment

    /** A finished html payload, drawn in a `WebView`. */
    data class Document(val html: String) : ResponseSegment
}

/** The transcript's dark palette, as CSS. */
private object HtmlFramePalette {
    /** `PabrikCard` — the surface a frame sits on, so the page has no seam. */
    const val BG = "#1D1C19"

    /** `PabrikText`. */
    const val FG = "#c5c9c5"

    /** `PabrikMuted` — quotes, captions, de-emphasised meta. */
    const val MUTED = "#a6a69c"

    /** `PabrikBorder` — table rules and horizontal rules. */
    const val BORDER = "#393836"

    /** `PabrikAccentSoft` — links. */
    const val LINK = "#B7C0D8"

    /** `PabrikField` — the chip behind `code`, `pre` and table cells. */
    const val CHIP = "#24221F"

    /** `PabrikAqua` — inline `code` ink, matching the markdown renderer. */
    const val CODE_INK = "#8EA4A2"
}

/** No scrollbars inside the frame. */
private const val NO_SCROLLBAR_STYLE =
    "html,body{overflow:hidden!important;scrollbar-width:none!important}" +
        "html::-webkit-scrollbar,body::-webkit-scrollbar{display:none!important}"

/** True when [html] is a whole document rather than a fragment. */
internal fun isFullHtmlDocument(html: String): Boolean =
    Regex("^\\s*(?:<!doctype\\s+html|<html[\\s>])", RegexOption.IGNORE_CASE).containsMatchIn(html)

/** The document handed to the `WebView`. */
internal fun htmlPreviewDocument(html: String): String {
    val trimmed = html.trim()
    if (isFullHtmlDocument(trimmed)) {
        val shell = "<style>$NO_SCROLLBAR_STYLE</style>"
        val closingBody = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
        if (closingBody.containsMatchIn(trimmed)) {
            return closingBody.replaceFirst(trimmed, "$shell</body>")
        }
        return trimmed + shell
    }
    val p = HtmlFramePalette
    return buildString {
        append("<!DOCTYPE html><html><head><meta charset=\"utf-8\">")
        append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
        append("<style>:root{color-scheme:dark}")
        append("html,body{margin:0;padding:0}")
        append("body{font-family:system-ui,sans-serif;background:${p.BG};color:${p.FG};margin:8px}")
        append("a{color:${p.LINK}}")
        append("img{max-width:100%}")
        append("pre,code,th,td{background:${p.CHIP}!important;color:${p.FG}!important}")
        append("code{font-family:ui-monospace,monospace;padding:.1em .3em;border-radius:3px}")
        append("code{color:${p.CODE_INK}!important}")
        append("pre{font-family:ui-monospace,monospace;padding:.6em .8em;")
        append("border-radius:4px;overflow-x:auto}")
        append("pre code{background:transparent!important;padding:0}")
        append("pre code{color:${p.FG}!important}")
        append("table{border-collapse:collapse}")
        append("th,td{border:1px solid ${p.BORDER};padding:4px 8px}")
        append("hr{border:none;border-top:1px solid ${p.BORDER}}")
        append("blockquote{margin:.6em 0;padding-left:.8em;border-left:3px solid ${p.BORDER};")
        append("color:${p.MUTED}}")
        append(NO_SCROLLBAR_STYLE)
        append("</style></head><body>")
        append(trimmed)
        append("</body></html>")
    }
}

/** The name a frame's page calls in. */
internal const val HEIGHT_BRIDGE = "PabrikHtmlPreview"

/** Append the height reporter to a document. */
internal fun withHeightReporter(document: String): String {
    val script = "<script>$HEIGHT_REPORTER_SCRIPT</script>"
    val closingBody = Regex("</body\\s*>", RegexOption.IGNORE_CASE)
    return if (closingBody.containsMatchIn(document)) {
        closingBody.replaceFirst(document, "$script</body>")
    } else {
        document + script
    }
}

/** The reporter itself. */
private val HEIGHT_REPORTER_SCRIPT = """
(function () {
  function report() {
    try {
      var root = document.documentElement;
      var body = document.body;
      var height = Math.max(
        root ? root.scrollHeight : 0,
        root ? root.offsetHeight : 0,
        body ? body.scrollHeight : 0,
        body ? body.offsetHeight : 0
      );
      if (height > 0) $HEIGHT_BRIDGE.reportHeight(Math.ceil(height));
    } catch (e) {}
  }
  report();
  window.addEventListener('load', report);
  if (window.ResizeObserver) {
    try { new ResizeObserver(report).observe(document.documentElement); } catch (e) {}
  }
  setTimeout(report, 250);
  setTimeout(report, 1500);
})();
""".trimIndent()

/** The exact bytes a frame is loaded with: themed shell, then reporter. */
internal fun htmlFrameSource(html: String): String =
    withHeightReporter(htmlPreviewDocument(html))
