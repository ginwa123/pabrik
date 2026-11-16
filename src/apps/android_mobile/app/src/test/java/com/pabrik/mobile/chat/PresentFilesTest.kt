package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The decisions a presented file's card makes, with no `Context`, no socket and no device. */
class PresentFilesTest {

    // ── kindOf ───────────────────────────────────────────────────────────────

    @Test
    fun `a png is an image`() {
        assertEquals(PresentFileKind.IMAGE, PresentFiles.kindOf("/a/shot.png", "image/png"))
    }

    @Test
    fun `a jpeg is an image whatever the case of the mime`() {
        assertEquals(
            PresentFileKind.IMAGE,
            PresentFiles.kindOf("/a/PHOTO.JPG", "IMAGE/JPEG"),
        )
    }

    /** The trap this whole file exists for. */
    @Test
    fun `an svg is external, not an image`() {
        assertEquals(PresentFileKind.EXTERNAL, PresentFiles.kindOf("/a/logo.svg", "image/svg+xml"))
    }

    @Test
    fun `a webp is an image`() {
        assertEquals(PresentFileKind.IMAGE, PresentFiles.kindOf("/a/x.webp", "image/webp"))
    }

    @Test
    fun `markdown is markdown`() {
        assertEquals(PresentFileKind.MARKDOWN, PresentFiles.kindOf("/a/README.md", "text/markdown"))
    }

    @Test
    fun `markdown wins over the text branch the mime would otherwise pick`() {
        // The backend maps .md to text/markdown, but an older row in the offline cache can carry text/plain for the same file.
        assertEquals(PresentFileKind.MARKDOWN, PresentFiles.kindOf("/a/R.md", "text/plain"))
    }

    @Test
    fun `json and javascript are code`() {
        assertEquals(PresentFileKind.CODE, PresentFiles.kindOf("/a/p.json", "application/json"))
        assertEquals(
            PresentFileKind.CODE,
            PresentFiles.kindOf("/a/m.mjs", "application/javascript"),
        )
    }

    @Test
    fun `plain text is text`() {
        assertEquals(PresentFileKind.TEXT, PresentFiles.kindOf("/a/notes.txt", "text/plain; charset=utf-8"))
    }

    @Test
    fun `the charset parameter does not change the branch`() {
        assertEquals(
            PresentFileKind.TEXT,
            PresentFiles.kindOf("/a/log.log", "text/plain; charset=utf-8"),
        )
    }

    @Test
    fun `html is external, because there is no webview in a transcript`() {
        assertEquals(PresentFileKind.EXTERNAL, PresentFiles.kindOf("/a/page.html", "text/html; charset=utf-8"))
    }

    @Test
    fun `pdf is external`() {
        assertEquals(PresentFileKind.EXTERNAL, PresentFiles.kindOf("/a/doc.pdf", "application/pdf"))
    }

    @Test
    fun `a zip is external`() {
        assertEquals(PresentFileKind.EXTERNAL, PresentFiles.kindOf("/a/bundle.zip", "application/zip"))
    }

    /** A file type the backend has no table row for comes back as `application/octet-stream`, and the extension is then the only evidence there is. */
    @Test
    fun `octet-stream falls back to the extension`() {
        assertEquals(PresentFileKind.IMAGE, PresentFiles.kindOf("/a/x.png", "application/octet-stream"))
        assertEquals(PresentFileKind.CODE, PresentFiles.kindOf("/a/m.zig", "application/octet-stream"))
        assertEquals(PresentFileKind.TEXT, PresentFiles.kindOf("/a/t.txt", "application/octet-stream"))
    }

    @Test
    fun `octet-stream with no known extension is external`() {
        assertEquals(PresentFileKind.EXTERNAL, PresentFiles.kindOf("/a/blob", "application/octet-stream"))
    }

    @Test
    fun `no mime at all still classifies by extension`() {
        assertEquals(PresentFileKind.IMAGE, PresentFiles.kindOf("/a/x.gif", ""))
        assertEquals(PresentFileKind.MARKDOWN, PresentFiles.kindOf("/a/NOTES.md", ""))
    }

    /** A specific mime beats a contradicting extension. */
    @Test
    fun `a known mime overrides the extension`() {
        assertEquals(PresentFileKind.TEXT, PresentFiles.kindOf("/a/photo.png", "text/plain"))
    }

    // ── extensionOf / baseNameOf / displayName ──────────────────────────────

    @Test
    fun `extensionOf handles dirs, case, and dotfiles`() {
        assertEquals(".png", PresentFiles.extensionOf("/a/b/photo.PNG"))
        assertEquals(".md", PresentFiles.extensionOf("notes.md"))
        assertEquals("", PresentFiles.extensionOf("/a/Makefile"))
        // A leading dot is a dotfile, not an extension.
        assertEquals("", PresentFiles.extensionOf("/a/.gitignore"))
        // A trailing dot is not an extension either.
        assertEquals("", PresentFiles.extensionOf("/a/weird."))
        // The last dot after the last slash wins, so a dotted directory does not turn `/a.b/c` into a `.b/c` extension.
        assertEquals("", PresentFiles.extensionOf("/a.b/c"))
    }

    @Test
    fun `baseNameOf strips both separators`() {
        assertEquals("report.md", PresentFiles.baseNameOf("/home/me/report.md"))
        assertEquals("report.md", PresentFiles.baseNameOf("C:\\me\\report.md"))
    }

    @Test
    fun `displayName prefers the label and falls back to the file name`() {
        assertEquals("notes", PresentFiles.displayName("notes", "/a/b.txt"))
        assertEquals("b.txt", PresentFiles.displayName("", "/a/b.txt"))
        assertEquals("b.txt", PresentFiles.displayName("   ", "/a/b.txt"))
        // A path with no name at all still has to render something.
        assertEquals("/a/", PresentFiles.displayName("", "/a/"))
    }

    // ── downloadUrl ─────────────────────────────────────────────────────────

    @Test
    fun `downloadUrl carries the session, the path and the disposition`() {
        val url = PresentFiles.downloadUrl(
            baseUrl = "https://agent.ginwa.site",
            sessionId = "sess-1",
            path = "/w/README.md",
            inline = true,
        )
        assertEquals(
            "https://agent.ginwa.site/api/files/download" +
                "?session_id=sess-1" +
                "&path=%2Fw%2FREADME.md" +
                "&disposition=inline",
            url,
        )
    }

    @Test
    fun `downloadUrl asks for an attachment when it is not a preview`() {
        val url = PresentFiles.downloadUrl("https://host", "s", "/a.zip", inline = false)
        assertTrue(url.endsWith("&disposition=attachment"))
    }

    @Test
    fun `downloadUrl does not double the base url's trailing slash`() {
        val url = PresentFiles.downloadUrl("https://host/", "s", "/a", inline = true)
        assertTrue(url.startsWith("https://host/api/files/download"))
    }

    /**
     * A space is the single most common character in a presented file name, and
     * `URLEncoder` encodes it as `+` — a form convention, not a path one. The
     * backend would then look for a file literally named `my+file.md`.
     */
    @Test
    fun `downloadUrl writes a space as percent-twenty, never as a plus`() {
        val url = PresentFiles.downloadUrl("https://host", "s", "/a/my file.md", inline = true)
        assertTrue(url.contains("my%20file.md"))
        assertFalse(url.contains("+"))
    }

    /**
     * `urlEncode` rewrites every `+` it finds, so a literal plus in a file name
     * has to survive as `%2B` and not be mistaken for one of those rewrites.
     * A presented `a+b.txt` is entirely ordinary — a version stamp, a formula,
     * a diff — and it would 404 as `a b.txt` otherwise.
     *
     * Pinned here rather than on the wire because a *session* id can never
     * contain a plus (`generateSessionId` in src/helpers/random.zig emits
     * `sess_<digits>_<hex>`), so the path is the only place this is reachable
     * and a functional test for it would be asserting on an impossible id.
     */
    @Test
    fun `a plus in the path survives as percent-two-B`() {
        val url = PresentFiles.downloadUrl("https://host", "s", "/a/v1+2.txt", inline = true)
        assertTrue(url.contains("v1%2B2.txt"))
        // The rewrite must not have produced a second, space-shaped reading.
        assertFalse(url.contains("v1%202.txt"))
    }

    @Test
    fun `downloadUrl escapes a path that would otherwise break the query`() {
        val url = PresentFiles.downloadUrl("https://host", "s", "/a/x?y=1&z=2#frag", inline = true)
        // Exactly one real `?`, the one that opens the query string.
        assertEquals(1, url.count { it == '?' })
        assertFalse(url.contains("#frag"))
    }

    // ── viewerMime ──────────────────────────────────────────────────────────

    @Test
    fun `viewerMime uses a specific server mime as-is`() {
        assertEquals("application/pdf", PresentFiles.viewerMime("/a/d.pdf", "application/pdf"))
    }

    @Test
    fun `viewerMime strips the charset so the intent is well formed`() {
        assertEquals("text/html", PresentFiles.viewerMime("/a/p.html", "text/html; charset=utf-8"))
    }

    @Test
    fun `viewerMime resolves octet-stream by extension`() {
        assertEquals("image/png", PresentFiles.viewerMime("/a/x.png", "application/octet-stream"))
        assertEquals("video/mp4", PresentFiles.viewerMime("/a/clip.mp4", "application/octet-stream"))
        // A phone camera writes .mov more often than .mp4.
        assertEquals("video/quicktime", PresentFiles.viewerMime("/a/clip.mov", "application/octet-stream"))
    }

    @Test
    fun `viewerMime falls back to the wildcard so a chooser appears`() {
        assertEquals("*/*", PresentFiles.viewerMime("/a/mystery", "application/octet-stream"))
    }

    // ── budgets ─────────────────────────────────────────────────────────────

    @Test
    fun `the byte budget matches the web's`() {
        assertEquals(512L * 1024L, PresentFiles.MAX_INLINE_TEXT_BYTES)
    }

    /** Deliberately *not* the web's 200,000. */
    @Test
    fun `the drawn character cap is low enough to stay interactive`() {
        assertEquals(20_000, PresentFiles.MAX_INLINE_TEXT_CHARS)
    }

    @Test
    fun `isTooLargeToPreviewInline is exclusive at the cap`() {
        assertFalse(PresentFiles.isTooLargeToPreviewInline(PresentFiles.MAX_INLINE_TEXT_BYTES))
        assertTrue(PresentFiles.isTooLargeToPreviewInline(PresentFiles.MAX_INLINE_TEXT_BYTES + 1))
    }

    @Test
    fun `decodeText round-trips utf8`() {
        val decoded = PresentFiles.decodeText("# Ünïcode — ✅\n".toByteArray())
        assertEquals("# Ünïcode — ✅\n", decoded.text)
        assertFalse(decoded.truncated)
    }

    @Test
    fun `decodeText reports truncation and slices to the cap`() {
        val decoded = PresentFiles.decodeText(ByteArray(PresentFiles.MAX_INLINE_TEXT_CHARS + 50) { 'a'.code.toByte() })
        assertTrue(decoded.truncated)
        assertEquals(PresentFiles.MAX_INLINE_TEXT_CHARS, decoded.text.length)
    }
}
