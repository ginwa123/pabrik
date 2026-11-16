package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The markdown parse, on the shapes an assistant actually writes. */
class MarkdownTest {

    private fun blocks(source: String) = Markdown.parse(stripContentEnvelope(source))

    private fun text(spans: List<MdSpan>) = spans.joinToString("") { it.text }

    // ── The reported shape ──────────────────────────────────────────────────

    @Test
    fun `the reported answer parses into headings and emphasis`() {
        // Verbatim the shape from the bug report: a `**PR:**` line, an `##` heading, and a `**bold**` phrase in a paragraph.
        val source = """
            **PR:** https://github.com/ginwa123/ginwaaitoolbox/pull/663

            ## What I built

            The Android transcript drew every tool result as a plain bubble.

            **Model layer** is pure Kotlin, so its JVM-testable.
        """.trimIndent()

        val parsed = blocks(source)

        assertEquals(4, parsed.size)
        assertTrue(parsed[0] is MdBlock.Paragraph)
        val firstLine = parsed[0] as MdBlock.Paragraph
        assertTrue(firstLine.spans.any { it.bold && it.text == "PR:" })
        assertTrue(
            parsed[1] is MdBlock.Heading &&
                (parsed[1] as MdBlock.Heading).level == 2 &&
                text((parsed[1] as MdBlock.Heading).spans) == "What I built",
        )
        assertEquals("The Android transcript drew every tool result as a plain bubble.", text((parsed[2] as MdBlock.Paragraph).spans))
    }

    @Test
    fun `no block ever contains a leftover hash or asterisk`() {
        // The bug is precisely "the markup is still on screen", so the test is that the markup is not in the parsed output at all.
        val source = "# Title\n\n- **a** `b`\n- [link](https://x.dev)\n\n> quoted\n\n---\n"

        val everything = blocks(source).joinToString(" ") { block ->
            when (block) {
                is MdBlock.Heading -> text(block.spans)
                is MdBlock.Paragraph -> text(block.spans)
                is MdBlock.ListBlock -> block.items.joinToString("") { text(it) }
                is MdBlock.Quote -> "quoted"
                else -> ""
            }
        }

        assertFalse("leftover markup: $everything", everything.contains("#"))
        assertFalse("leftover markup: $everything", everything.contains("**"))
        assertFalse("leftover markup: $everything", everything.contains("`"))
    }

    // ── Blocks ──────────────────────────────────────────────────────────────

    @Test
    fun `headings carry their level`() {
        val parsed = blocks("# One\n\n## Two\n\n#### Four")

        assertEquals(3, parsed.size)
        assertEquals(1, (parsed[0] as MdBlock.Heading).level)
        assertEquals(2, (parsed[1] as MdBlock.Heading).level)
        assertEquals(4, (parsed[2] as MdBlock.Heading).level)
    }

    @Test
    fun `seven hashes is a paragraph, not a heading`() {
        // The CommonMark cap. Past six, `#` is just a character.
        val parsed = blocks("####### seven")

        assertTrue(parsed.single() is MdBlock.Paragraph)
    }

    @Test
    fun `a hashtag with no space is not a heading`() {
        val parsed = blocks("#hashtag")

        assertTrue(parsed.single() is MdBlock.Paragraph)
    }

    @Test
    fun `a bullet list keeps its items`() {
        val parsed = blocks("- one\n- two\n- three")

        val list = parsed.single() as MdBlock.ListBlock
        assertFalse(list.ordered)
        assertEquals(3, list.items.size)
        assertEquals("one", text(list.items[0]))
    }

    @Test
    fun `an ordered list keeps its start number`() {
        // A plan that starts at 3 renumbering itself to 1 is a plan you cannot tick off against what you were told.
        val parsed = blocks("3. third\n4. fourth")

        val list = parsed.single() as MdBlock.ListBlock
        assertTrue(list.ordered)
        assertEquals(3, list.start)
        assertEquals(2, list.items.size)
    }

    @Test
    fun `a fenced code block keeps its language and its body verbatim`() {
        val parsed = blocks("```bash\ncd /tmp\nls -a\n```")

        val code = parsed.single() as MdBlock.Code
        assertEquals("bash", code.language)
        assertEquals("cd /tmp\nls -a", code.code)
    }

    @Test
    fun `a code block with no language still parses`() {
        val code = blocks("```\nplain\n```").single() as MdBlock.Code

        assertEquals(null, code.language)
        assertEquals("plain", code.code)
    }

    @Test
    fun `an unterminated fence still renders its body`() {
        // A streaming answer is a fence that has not closed yet.
        val code = blocks("```\nhalf a fence").single() as MdBlock.Code

        assertEquals("half a fence", code.code)
    }

    @Test
    fun `markup inside a code block is not markup`() {
        // The one rule that matters most for a code block: `**` inside it is two asterisks, not bold.
        val code = blocks("```\n**not bold** and # not a heading\n```").single() as MdBlock.Code

        assertEquals("**not bold** and # not a heading", code.code)
    }

    @Test
    fun `a blockquote keeps its text`() {
        val quote = blocks("> first line\n> second line").single() as MdBlock.Quote

        val paragraph = quote.blocks.single() as MdBlock.Paragraph
        assertEquals("first line second line", text(paragraph.spans))
    }

    @Test
    fun `a horizontal rule is its own block`() {
        assertTrue(blocks("a\n\n---\n\nb").any { it is MdBlock.Rule })
    }

    @Test
    fun `a table parses its header and rows`() {
        val table = blocks(
            """
            | Tool | What |
            | --- | --- |
            | read_file | reads |
            | write_file | writes |
            """.trimIndent(),
        ).single() as MdBlock.Table

        assertEquals(2, table.header.size)
        assertEquals("Tool", text(table.header[0]))
        assertEquals(2, table.rows.size)
        assertEquals("write_file", text(table.rows[1][0]))
    }

    @Test
    fun `a line with pipes but no delimiter row is a paragraph`() {
        // A sentence about `a | b` is a sentence, not a table.
        assertTrue(blocks("use a | b here").single() is MdBlock.Paragraph)
    }

    // ── Inline ──────────────────────────────────────────────────────────────

    @Test
    fun `bold, italic and code spans are recognised`() {
        val spans = Markdown.parseInline("plain **bold** *em* `code`")

        assertEquals("plain ", text(spans.take(1)))
        assertTrue(spans.any { it.bold && it.text == "bold" })
        assertTrue(spans.any { it.italic && it.text == "em" })
        assertTrue(spans.any { it.code && it.text == "code" })
    }

    @Test
    fun `an unclosed marker is literal text`() {
        val spans = Markdown.parseInline("2 ** 3 is arithmetic")

        assertEquals("2 ** 3 is arithmetic", text(spans))
        assertTrue(spans.none { it.bold })
    }

    @Test
    fun `an underscore inside a word is not emphasis`() {
        // `some_file_name` is one word.
        val spans = Markdown.parseInline("open some_file_name now")

        assertEquals("open some_file_name now", text(spans))
        assertTrue(spans.none { it.italic })
    }

    @Test
    fun `a link keeps its label and its url`() {
        val spans = Markdown.parseInline("see [the PR](https://example.dev/pull/1) now")

        val link = spans.single { it.link != null }
        assertEquals("the PR", link.text)
        assertEquals("https://example.dev/pull/1", link.link)
    }

    @Test
    fun `an unmatched bracket is literal`() {
        val spans = Markdown.parseInline("array[0] stays")

        assertEquals("array[0] stays", text(spans))
        assertTrue(spans.none { it.link != null })
    }

    @Test
    fun `strikethrough and bold-italic are recognised`() {
        val spans = Markdown.parseInline("~~gone~~ and ***loud***")

        assertTrue(spans.any { it.strike && it.text == "gone" })
        assertTrue(spans.any { it.bold && it.italic && it.text == "loud" })
    }

    @Test
    fun `a backslash escapes the next character`() {
        val spans = Markdown.parseInline("""not \*emphasis\* here""")

        assertEquals("not *emphasis* here", text(spans))
        assertTrue(spans.none { it.italic })
    }

    // ── Robustness ──────────────────────────────────────────────────────────

    @Test
    fun `blank input is no blocks`() {
        assertTrue(Markdown.parse("").isEmpty())
        assertTrue(Markdown.parse("   \n  ").isEmpty())
    }

    @Test
    fun `a very long answer parses without throwing`() {
        val source = (1..500).joinToString("\n\n") { "## Section $it\n\nBody **$it** with `code`." }

        val parsed = Markdown.parse(source)

        // A heading and a paragraph per section.
        assertEquals(1000, parsed.size)
        assertEquals(500, parsed.count { it is MdBlock.Heading })
    }

    @Test
    fun `consecutive blank lines do not produce empty blocks`() {
        val parsed = blocks("one\n\n\n\n\ntwo")

        assertEquals(2, parsed.size)
        assertTrue(parsed.all { it is MdBlock.Paragraph })
    }

    @Test
    fun `a soft-wrapped paragraph is one block`() {
        // Prose arrives wrapped; a newline inside a paragraph is not a break.
        val parsed = blocks("this sentence was\nwrapped by the model\nacross lines")

        val paragraph = parsed.single() as MdBlock.Paragraph
        assertEquals("this sentence was wrapped by the model across lines", text(paragraph.spans))
    }
}
