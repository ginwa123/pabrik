package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The document split, which is the actual reported bug. */
class HtmlResponseTest {

    // ── The reported shape ──────────────────────────────────────────────────

    @Test
    fun `the reported turn - a style-led page - is a document`() {
        // The first line of the screenshot.
        val content = """
            <style>bmw-wrap{font-family:ui-sans-system,-apple-system,"Segoe
            UI",Roboto,Inter,sans-serif;background:#1D1C19;color:#c5c9c5}
            .bmw-kicker{font-size:12px}</style>
            <main class="bmw-wrap"><h1>BMW M4 Competition</h1></main>
        """.trimIndent()

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        assertTrue(segments[0] is ResponseSegment.Document)
        assertTrue(HtmlResponse.isHtmlTurn(content))
    }

    @Test
    fun `a wrapper-led page is a document, and the wrapper is not part of it`() {
        val content = "<html><head><style>h1{color:red}</style></head>" +
            "<body><h1>Report</h1></body></html>"

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        val document = segments[0] as ResponseSegment.Document
        assertEquals(
            "<head><style>h1{color:red}</style></head><body><h1>Report</h1></body>",
            document.html,
        )
    }

    @Test
    fun `a fenced document is a document and the fence is not part of it`() {
        val content = "```html\n<!doctype html>\n<html><body><h1>Hi</h1></body></html>\n```"

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        val document = segments[0] as ResponseSegment.Document
        assertTrue(document.html.startsWith("<!doctype html>"))
        assertFalse(document.html.contains("```"))
    }

    // ── What must NOT become a document ─────────────────────────────────────

    @Test
    fun `an ordinary markdown answer is prose`() {
        val content = "## What I built\n\nMoved the card to the `in progress` column."

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        assertTrue(segments[0] is ResponseSegment.Prose)
        assertFalse(HtmlResponse.isHtmlTurn(content))
    }

    @Test
    fun `prose that mentions a tag in the middle is prose`() {
        // The rule that keeps the first-line heuristic honest: the tag is in the sentence, never at the start of the turn.
        val content = "Wrap the body in <div class=\"wrap\"> and it lays out fine."

        assertFalse(HtmlResponse.isHtmlTurn(content))
        assertEquals(1, HtmlResponse.segments(content).size)
    }

    @Test
    fun `a fenced markdown answer is prose, not a document`() {
        // The language alternation is the whole test.
        val content = "```markdown\n## Heading\n\n**bold**\n```"

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        assertTrue(segments[0] is ResponseSegment.Prose)
    }

    @Test
    fun `a fenced code block inside a markdown answer survives`() {
        // Anchored at both ends, or the trailing fence is matched, the block re-opens, and the answer renders as a paragraph of shell commands.
        val content = """
            Here is the script:

            ```bash
            echo hello
            ```
        """.trimIndent()

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        assertTrue(segments[0] is ResponseSegment.Prose)
    }

    @Test
    fun `empty content has no segments`() {
        assertEquals(emptyList<ResponseSegment>(), HtmlResponse.segments("   \n  "))
        assertFalse(HtmlResponse.isHtmlTurn(""))
    }

    // ── Mixed turns ─────────────────────────────────────────────────────────

    @Test
    fun `prose around a document stays prose, in order`() {
        val content = "Here is the page.\n<html><body><h1>Report</h1></body></html>\nAny questions?"

        val segments = HtmlResponse.segments(content)

        assertEquals(3, segments.size)
        assertEquals("Here is the page.", (segments[0] as ResponseSegment.Prose).text)
        assertTrue(segments[1] is ResponseSegment.Document)
        assertEquals("Any questions?", (segments[2] as ResponseSegment.Prose).text)
    }

    @Test
    fun `two documents in one turn are two frames`() {
        val content = "<html><body><h1>One</h1></body></html>" +
            "<html><body><h1>Two</h1></body></html>"

        val segments = HtmlResponse.segments(content)

        assertEquals(2, segments.filterIsInstance<ResponseSegment.Document>().size)
    }

    @Test
    fun `a think block is not part of the document`() {
        val content = "<think>the model is designing a page</think>" +
            "<html><body><h1>Done</h1></body></html>"

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        val document = segments[0] as ResponseSegment.Document
        assertEquals("<body><h1>Done</h1></body>", document.html)
    }

    @Test
    fun `a plain wrapper around a document comes off`() {
        val content = "<plain><div class=\"card\"><h1>Card</h1></div></plain>"

        val segments = HtmlResponse.segments(content)

        assertEquals(1, segments.size)
        assertEquals(
            "<div class=\"card\"><h1>Card</h1></div>",
            (segments[0] as ResponseSegment.Document).html,
        )
    }

    // ── A document that has not finished arriving ───────────────────────────

    @Test
    fun `a document still streaming is prose, so no frame is rebuilt per delta`() {
        val partial = "<!doctype html>\n<html><body><h1>Half a pag"

        assertFalse(HtmlResponse.isHtmlTurn(partial, isComplete = false))
        assertEquals(1, HtmlResponse.segments(partial, isComplete = false).size)
        assertTrue(
            HtmlResponse.segments(partial, isComplete = false)[0] is ResponseSegment.Prose
        )
    }

    @Test
    fun `the same document is drawable once the turn stops streaming`() {
        val partial = "<!doctype html>\n<html><body><h1>Half a pag"

        assertTrue(HtmlResponse.isHtmlTurn(partial, isComplete = true))
    }

    @Test
    fun `a bare document persisted mid-write is still drawable from its own close tag`() {
        // `</body>` is the fallback for a turn that is not streaming and has neither a fence nor an `<html>` wrapper to prove it finished.
        val persisted = "<style>b{color:red}</style><div>Report</body>"

        assertTrue(HtmlResponse.isHtmlTurn(persisted, isComplete = false))
    }

    // ── The frame budget ────────────────────────────────────────────────────

    @Test
    fun `the frame budget keeps the first documents and falls back to text after`() {
        val blocks = (1..5).joinToString("") {
            "<html><body><h1>Block $it</h1></body></html>"
        }
        val documents = HtmlResponse.segments(blocks)
            .filterIsInstance<ResponseSegment.Document>()

        assertEquals(5, documents.size)
        (0 until HtmlResponse.MAX_LIVE_FRAMES).forEach { index ->
            assertTrue(HtmlResponse.getsLiveFrame(index))
        }
        assertFalse(HtmlResponse.getsLiveFrame(HtmlResponse.MAX_LIVE_FRAMES))
        assertFalse(HtmlResponse.getsLiveFrame(HtmlResponse.MAX_LIVE_FRAMES + 1))
    }

    @Test
    fun `the frame budget counts position, so five identical documents are still capped`() {
        // A turn that repeats one document five times compares equal five times, so an identity-based budget would hand out five frames to a turn that is supposed to be …
        val blocks = "<html><body><h1>Same</h1></body></html>".repeat(5)
        val documents = HtmlResponse.segments(blocks)
            .filterIsInstance<ResponseSegment.Document>()

        assertEquals(5, documents.size)
        val live = documents.indices.count { HtmlResponse.getsLiveFrame(it) }
        assertEquals(HtmlResponse.MAX_LIVE_FRAMES, live)
    }

    @Test
    fun `a turn with no documents has no live frames`() {
        val segments = HtmlResponse.segments("just an answer")

        assertEquals(0, segments.filterIsInstance<ResponseSegment.Document>().size)
    }

    // ── The frame document ──────────────────────────────────────────────────

    @Test
    fun `a fragment is wrapped in the dark shell, not left bare`() {
        val shell = htmlPreviewDocument("<h1>Report</h1>")

        assertTrue(shell.startsWith("<!DOCTYPE html>"))
        // `color-scheme: dark` or the frame's own scrollbars and form controls render light inside a dark transcript.
        assertTrue(shell.contains("color-scheme:dark"))
        assertTrue(shell.contains("background:#1D1C19"))
        assertTrue(shell.contains("<h1>Report</h1>"))
    }

    @Test
    fun `a fragment's text surfaces are forced over the payload's own light chips`() {
        // Real payload from this project: `style="background:#f6f8fa"` on every `<pre>`, written by a model that had no idea the transcript is dark.
        val shell = htmlPreviewDocument("<pre style=\"background:#f6f8fa\">x</pre>")

        assertTrue(shell.contains("pre,code,th,td{background:#24221F!important"))
        assertTrue(shell.contains("color:#8EA4A2!important"))
    }

    @Test
    fun `a whole document passes through with only the no-scrollbar rule added`() {
        val document = "<!doctype html><html><head><title>t</title></head>" +
            "<body><h1>Keep my own head</h1></body></html>"

        val built = htmlPreviewDocument(document)

        assertTrue(built.contains("<title>t</title>"))
        assertTrue(built.contains("<h1>Keep my own head</h1>"))
        // Rewriting a working page's own head is how it stops working.
        assertFalse(built.contains("color-scheme:dark"))
        assertTrue(built.contains("overflow:hidden"))
    }

    @Test
    fun `a whole document without a body still gets the rule`() {
        val built = htmlPreviewDocument("<!doctype html><html><head></head><p>x</p></html>")

        assertTrue(built.contains("overflow:hidden"))
        assertTrue(built.contains("<p>x</p>"))
    }

    @Test
    fun `a fragment is not mistaken for a whole document`() {
        assertTrue(isFullHtmlDocument("<!doctype html><html></html>"))
        assertTrue(isFullHtmlDocument("<html lang=\"en\">"))
        assertTrue(isFullHtmlDocument("\n  <!DOCTYPE HTML>"))
        assertFalse(isFullHtmlDocument("<div class=\"card\">"))
        assertFalse(isFullHtmlDocument("<style>b{}</style>"))
    }

    // ── The height reporter ─────────────────────────────────────────────────

    @Test
    fun `the reporter is injected before the closing body`() {
        val built = withHeightReporter("<!doctype html><html><body><h1>x</h1></body></html>")

        assertTrue(built.contains("reportHeight"))
        assertTrue(built.indexOf("reportHeight") < built.indexOf("</body>"))
    }

    @Test
    fun `the reporter survives a document with no body`() {
        val built = withHeightReporter("<div>x</div>")

        assertTrue(built.contains("reportHeight"))
    }

    @Test
    fun `a frame gets the theme and the reporter in one document`() {
        // What the `WebView` is handed, asserted whole.
        val frame = htmlFrameSource("<h1>Report</h1>")

        assertTrue(frame.contains("color-scheme:dark"))
        assertTrue(frame.contains("$HEIGHT_BRIDGE.reportHeight"))
        assertTrue(frame.contains("<h1>Report</h1>"))
    }
}

/** A document turn has to be *visible*, not merely renderable. */
class HtmlTurnVisibilityTest {

    @Test
    fun `a turn that is only a document is still renderable`() {
        val message = ChatMessage(
            id = "m1",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "<html><body><h1>Report</h1></body></html>",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
        )

        assertTrue(message.hasRenderableContent)
        assertTrue(message.hasVisibleContent)
        assertEquals(1, groupMessages(listOf(message)).size)
    }

    @Test
    fun `the benchmark turn is visible and is the only row in its group`() {
        val content = "<style>bmw-wrap{background:#1D1C19}</style>" +
            "<main class=\"bmw-wrap\"><h1>BMW M4</h1></main>"

        val message = ChatMessage(
            id = "m1",
            role = ChatMessage.ROLE_ASSISTANT,
            content = content,
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
        )

        assertTrue(HtmlResponse.isHtmlTurn(content))
        assertTrue(message.hasVisibleContent)
    }

    @Test
    fun `an envelope-only turn is still not renderable`() {
        // The gate the change must not weaken: `<markdown></markdown>` has no answer in it, document or otherwise.
        val message = ChatMessage(
            id = "m1",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "<markdown>  </markdown>",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
        )

        assertFalse(message.hasRenderableContent)
    }

    @Test
    fun `an empty html envelope is still not renderable`() {
        // The gate the change must not weaken.
        val message = ChatMessage(
            id = "m1",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "<html></html>",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
        )

        assertFalse(HtmlResponse.isHtmlTurn("<html></html>"))
        assertFalse(message.hasRenderableContent)
        assertEquals(0, groupMessages(listOf(message)).size)
    }

    @Test
    fun `a think-only turn keeps the contract it had before documents existed`() {
        // Deliberate, and unchanged by this work: a turn that is only `<think>…</think>` is the model's thinking the reader asked to see, so the envelope strip leaves it …
        val message = ChatMessage(
            id = "m1",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "<think>weighing it up</think>",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
        )

        assertTrue(message.hasRenderableContent)
    }
}
