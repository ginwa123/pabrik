package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The envelope strip, which is the actual reported bug. */
class StripContentEnvelopeTest {

    @Test
    fun `a markdown wrapper comes off`() {
        val content = "<markdown>\n## What I built\n\nMoved the card.\n</markdown>"

        assertEquals("## What I built\n\nMoved the card.", stripContentEnvelope(content))
    }

    @Test
    fun `a plain wrapper comes off`() {
        assertEquals("Just prose.", stripContentEnvelope("<plain>Just prose.</plain>"))
    }

    @Test
    fun `an html wrapper comes off`() {
        assertEquals("<div>hi</div>", stripContentEnvelope("<html><div>hi</div></html>"))
    }

    @Test
    fun `the reported shape - a fenced markdown wrapper - comes off whole`() {
        // The two habits compound: the answer is wrapped AND fenced.
        val content = "<markdown>\n```markdown\n**PR:** https://example/pull/1\n```\n</markdown>"

        assertEquals("**PR:** https://example/pull/1", stripContentEnvelope(content))
    }

    @Test
    fun `a bare html fence with no wrapper comes off`() {
        val content = "```html\n<h1>Report</h1>\n```"

        assertEquals("<h1>Report</h1>", stripContentEnvelope(content))
    }

    @Test
    fun `a think block is dropped when a wrapper is also present`() {
        val content = "<think>weighing the options</think><markdown>**done**</markdown>"

        assertEquals("**done**", stripContentEnvelope(content))
    }

    @Test
    fun `a think-only turn is left alone rather than emptied`() {
        // The model thinking out loud is content the reader wants.
        val content = "<think>the user wants markdown, so I will use headings</think>"

        assertEquals(content, stripContentEnvelope(content))
    }

    @Test
    fun `a code fence inside the body survives`() {
        // Only the OUTER fence is the envelope's.
        val content = "Run it:\n\n```bash\n./gradlew test\n```\n\nthen done."

        val stripped = stripContentEnvelope(content)

        assertTrue(stripped.contains("```bash"))
        assertTrue(stripped.contains("./gradlew test"))
    }

    @Test
    fun `markdown with no wrapper is returned unchanged`() {
        val content = "## Heading\n\n- one\n- two\n\n**bold** and `code`"

        assertEquals(content, stripContentEnvelope(content))
    }

    @Test
    fun `empty and blank content come back empty`() {
        assertEquals("", stripContentEnvelope(""))
        assertEquals("", stripContentEnvelope("   \n  "))
    }

    @Test
    fun `hasContent sees through a wrapper that holds nothing`() {
        // Non-blank as a string, nothing to draw.
        assertFalse(Markdown.hasContent("<markdown>\n\n</markdown>"))
        assertTrue(Markdown.hasContent("<markdown>real</markdown>"))
        assertTrue(Markdown.hasContent("plain"))
    }
}
