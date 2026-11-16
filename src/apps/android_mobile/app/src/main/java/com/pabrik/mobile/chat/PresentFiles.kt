package com.pabrik.mobile.chat

import java.net.URLEncoder

/** How a `present_files` entry should be shown, and the URL its bytes come from. */
internal enum class PresentFileKind {
    /** Renders as a bitmap in-app. */
    IMAGE,

    /** Fetched and rendered through `Markdown`. */
    MARKDOWN,

    /** Fetched and rendered in the monospace block. */
    CODE,

    /** Fetched and rendered as plain wrapped text. */
    TEXT,

    /** Not previewable in-app; the "Open" action hands it to a viewer app. */
    EXTERNAL,
}

internal object PresentFiles {

    /** Inline fetch budget, mirroring the web's `MAX_INLINE_TEXT_BYTES`. */
    const val MAX_INLINE_TEXT_BYTES: Long = 512L * 1024L

    /** How much decoded text is drawn inline. */
    const val MAX_INLINE_TEXT_CHARS: Int = 20_000

    /** The endpoint that serves the bytes, from `src/http_handlers/files_download.zig`. */
    const val DOWNLOAD_PATH: String = "/api/files/download"

    // Extensions the web treats as code even when the server guessed `application/octet-stream` — see `CODE_LANG_BY_EXT` in `PresentFiles.vue`.
    private val CODE_EXTENSIONS = setOf(
        ".zig", ".ts", ".tsx", ".js", ".mjs", ".jsx", ".py", ".json", ".css",
        ".sh", ".rs", ".go", ".java", ".vue", ".sql", ".yaml", ".yml", ".toml",
        ".xml", ".c", ".h", ".cpp", ".hpp", ".rb", ".php",
    )

    private val HTML_EXTENSIONS = setOf(".html", ".htm")

    /** The mime extensions the backend maps to `text/plain` and the browser happily renders, so a code card and a plain-text card are the same renderer. */
    private val TEXT_EXTENSIONS = setOf(
        ".txt", ".csv", ".log", ".md", ".text",
    )

    private val MARKDOWN_EXTENSIONS = setOf(".md", ".markdown")

    /** `image/svg+xml` is XML, not a bitmap — `BitmapFactory` cannot decode it. */
    private val BITMAP_IMAGE_EXTENSIONS = setOf(".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")

    /** `@2x` in a filename is not an extension, so the suffix is compared separately. */
    private val IMAGE_MIME_SUBTYPE_ALLOW_LIST = setOf("png", "jpeg", "jpg", "gif", "webp", "bmp")

    /** The file's extension, lowercased, or `""` when it has none. */
    fun extensionOf(path: String): String {
        val base = path.substringAfterLast('/').substringAfterLast('\\')
        val dot = base.lastIndexOf('.')
        // A leading dot is a dotfile (`.gitignore`), not an extension.
        if (dot <= 0 || dot == base.lastIndex) return ""
        return base.substring(dot).lowercase()
    }

    /** The file's name without its directory, the way a file manager shows it. */
    fun baseNameOf(path: String): String =
        path.substringAfterLast('/').substringAfterLast('\\')

    /** The name to put on the card: the tool's `label` when it set one, the file's own name otherwise. */
    fun displayName(label: String, path: String): String {
        val trimmed = label.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return baseNameOf(path).ifEmpty { path }
    }

    /** Which renderer a file gets. */
    fun kindOf(path: String, mime: String): PresentFileKind {
        val normalizedMime = mime.trim().lowercase().substringBefore(';').trim()
        val extension = extensionOf(path)

        if (isBitmapImage(normalizedMime, extension)) return PresentFileKind.IMAGE
        if (isHtml(normalizedMime, extension)) return PresentFileKind.EXTERNAL
        if (isMarkdown(normalizedMime, extension)) return PresentFileKind.MARKDOWN

        val known = normalizedMime.isNotEmpty() && normalizedMime != OCTET_STREAM
        if (known) {
            if (normalizedMime == "application/json" || normalizedMime == "application/javascript") {
                return PresentFileKind.CODE
            }
            if (normalizedMime.startsWith("text/")) return PresentFileKind.TEXT
            // video, audio, application/pdf, image/svg+xml, application/zip — all "hand it to a viewer app".
            return PresentFileKind.EXTERNAL
        }

        return when (extension) {
            in CODE_EXTENSIONS -> PresentFileKind.CODE
            in TEXT_EXTENSIONS -> PresentFileKind.TEXT
            else -> PresentFileKind.EXTERNAL
        }
    }

    /** A document that is served as text but is not text. */
    private fun isHtml(normalizedMime: String, extension: String): Boolean =
        normalizedMime == "text/html" || extension in HTML_EXTENSIONS

    /** True only for the mimes `BitmapFactory` can actually decode. */
    private fun isBitmapImage(normalizedMime: String, extension: String): Boolean {
        if (normalizedMime.startsWith("image/")) {
            return normalizedMime.removePrefix("image/") in IMAGE_MIME_SUBTYPE_ALLOW_LIST
        }
        if (normalizedMime.isNotEmpty() && normalizedMime != OCTET_STREAM) return false
        return extension in BITMAP_IMAGE_EXTENSIONS
    }

    /** Extension first, deliberately — see [kindOf]. */
    private fun isMarkdown(normalizedMime: String, extension: String): Boolean =
        extension in MARKDOWN_EXTENSIONS || normalizedMime.contains("markdown")

    /** The mime to hand `ACTION_VIEW`. */
    fun viewerMime(path: String, mime: String): String {
        val normalizedMime = mime.trim().lowercase().substringBefore(';').trim()
        if (normalizedMime.isNotEmpty() && normalizedMime != OCTET_STREAM) return normalizedMime
        val extension = extensionOf(path)
        return EXTENSION_MIME[extension] ?: WILDCARD_MIME
    }

    /** The download URL for one file. */
    fun downloadUrl(
        baseUrl: String,
        sessionId: String,
        path: String,
        inline: Boolean,
    ): String {
        val root = baseUrl.trimEnd('/')
        return buildString {
            append(root)
            append(DOWNLOAD_PATH)
            append("?session_id=").append(urlEncode(sessionId))
            append("&path=").append(urlEncode(path))
            append("&disposition=").append(if (inline) "inline" else "attachment")
        }
    }

    /** Percent-encode one query value, with `+` rewritten out of it. */
    fun urlEncode(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    /** Decode a fetched body as UTF-8 text, sliced to [MAX_INLINE_TEXT_CHARS] and reporting whether the slice lost anything — the caller draws a "truncated for inline … */
    fun decodeText(bytes: ByteArray): DecodedText {
        val text = String(bytes, Charsets.UTF_8)
        val truncated = text.length > MAX_INLINE_TEXT_CHARS
        return DecodedText(
            text = if (truncated) text.substring(0, MAX_INLINE_TEXT_CHARS) else text,
            truncated = truncated,
        )
    }

    /** Whether a file is too big to pull into memory just to draw it. */
    fun isTooLargeToPreviewInline(bytes: Long): Boolean = bytes > MAX_INLINE_TEXT_BYTES

    private const val OCTET_STREAM = "application/octet-stream"
    private const val WILDCARD_MIME = "*/*"

    /** The extension table for the "Open" action, kept to what the backend itself knows (`files_download.zig:mime_table`) plus the few it does not but a phone has a … */
    private val EXTENSION_MIME = mapOf(
        ".png" to "image/png",
        ".jpg" to "image/jpeg",
        ".jpeg" to "image/jpeg",
        ".gif" to "image/gif",
        ".webp" to "image/webp",
        ".bmp" to "image/bmp",
        ".svg" to "image/svg+xml",
        ".html" to "text/html",
        ".htm" to "text/html",
        ".css" to "text/css",
        ".js" to "application/javascript",
        ".mjs" to "application/javascript",
        ".json" to "application/json",
        ".md" to "text/markdown",
        ".txt" to "text/plain",
        ".csv" to "text/csv",
        ".log" to "text/plain",
        ".pdf" to "application/pdf",
        ".zip" to "application/zip",
        ".mp3" to "audio/mpeg",
        ".wav" to "audio/wav",
        ".m4a" to "audio/mp4",
        ".oga" to "audio/ogg",
        ".mp4" to "video/mp4",
        ".mov" to "video/quicktime",
        ".webm" to "video/webm",
    )
}

/** A decoded body plus whether the decode had to cut it. */
internal data class DecodedText(
    val text: String,
    val truncated: Boolean,
)
