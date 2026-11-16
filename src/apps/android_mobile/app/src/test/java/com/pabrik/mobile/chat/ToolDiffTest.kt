package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The diff behind a `text_replace` card. */
class ToolDiffTest {

    @Test
    fun `a trailing newline does not invent a blank line`() {
        val lines = ToolDiff.splitLines("a\nb\n")

        assertEquals(listOf("a", "b"), lines)
    }

    @Test
    fun `a file ending without a newline keeps its last line`() {
        assertEquals(listOf("a", "b"), ToolDiff.splitLines("a\nb"))
    }

    @Test
    fun `empty text is zero lines, not one blank line`() {
        assertTrue(ToolDiff.splitLines("").isEmpty())
    }

    @Test
    fun `identical sides are all context`() {
        val rows = ToolDiff.compute("a\nb\n", "a\nb\n")

        assertEquals(2, rows.size)
        assertTrue(rows.all { it.kind == DiffRowKind.Context })
    }

    @Test
    fun `a pure insertion`() {
        val rows = ToolDiff.compute("a\nc\n", "a\nb\nc\n")

        assertEquals(listOf(DiffRowKind.Context, DiffRowKind.Added, DiffRowKind.Context), rows.map { it.kind })
        assertEquals("b", rows[1].text)
        assertEquals(2, rows[1].afterLine)
        assertEquals(null, rows[1].beforeLine)
    }

    @Test
    fun `a pure deletion`() {
        val rows = ToolDiff.compute("a\nb\nc\n", "a\nc\n")

        assertEquals(listOf(DiffRowKind.Context, DiffRowKind.Removed, DiffRowKind.Context), rows.map { it.kind })
        assertEquals(2, rows[1].beforeLine)
        assertEquals(null, rows[1].afterLine)
    }

    @Test
    fun `a replacement reads as old line then new line`() {
        val rows = ToolDiff.compute("a\nOLD\nc\n", "a\nNEW\nc\n")

        // A reader scanning a diff expects to meet the removed line before the added one; the other order reads as if the file gained the old line.
        assertEquals(
            listOf(DiffRowKind.Context, DiffRowKind.Removed, DiffRowKind.Added, DiffRowKind.Context),
            rows.map { it.kind },
        )
        assertEquals("OLD", rows[1].text)
        assertEquals("NEW", rows[2].text)
    }

    @Test
    fun `an empty before is all additions`() {
        val rows = ToolDiff.compute("", "x\ny\n")

        assertEquals(listOf(DiffRowKind.Added, DiffRowKind.Added), rows.map { it.kind })
        assertEquals(1, rows[0].afterLine)
    }

    @Test
    fun `an empty after is all removals`() {
        val rows = ToolDiff.compute("x\ny\n", "")

        assertEquals(listOf(DiffRowKind.Removed, DiffRowKind.Removed), rows.map { it.kind })
    }

    @Test
    fun `two empty sides are no rows at all`() {
        assertTrue(ToolDiff.compute("", "").isEmpty())
    }

    @Test
    fun `a final-newline-only change is one removed blank line`() {
        val rows = ToolDiff.compute("a", "a\n")

        // Without the trailing-empty drop in splitLines this renders as a removal of an empty line, which is a difference that does not exist.
        assertEquals(listOf(DiffRowKind.Context), rows.map { it.kind })
    }

    @Test
    fun `line numbers are one-based on the side each line appears on`() {
        val rows = ToolDiff.compute("a\nb\nc\n", "a\nB\nc\n")

        val removed = rows.single { it.kind == DiffRowKind.Removed }
        val added = rows.single { it.kind == DiffRowKind.Added }
        assertEquals(2, removed.beforeLine)
        assertEquals(2, added.afterLine)
    }

    /** Past the cell budget the LCS table would allocate ~16 MB on a phone. */
    @Test
    fun `an oversized diff degrades to a wholesale replacement`() {
        val side = (1..3000).joinToString("\n") { "line $it" }
        val other = (1..3000).joinToString("\n") { "line ${it + 1}" }

        val rows = ToolDiff.compute(side, other)

        assertEquals(6000, rows.size)
        assertEquals(3000, rows.count { it.kind == DiffRowKind.Removed })
        assertEquals(3000, rows.count { it.kind == DiffRowKind.Added })
    }

    @Test
    fun `a diff just under the budget still diffs exactly`() {
        val side = (1..100).joinToString("\n") { "line $it" }
        val other = (1..100).joinToString("\n") { if (it == 50) "changed" else "line $it" }

        val rows = ToolDiff.compute(side, other)

        assertEquals(1, rows.count { it.kind == DiffRowKind.Removed })
        assertEquals(1, rows.count { it.kind == DiffRowKind.Added })
        // 100 lines in, one of which was replaced, leaves 99 untouched.
        assertEquals(99, rows.count { it.kind == DiffRowKind.Context })
    }

    @Test
    fun `formatBytes uses decimal units`() {
        assertEquals("512 B", formatBytes(512))
        assertEquals("1.0 KB", formatBytes(1000))
        assertEquals("1.5 KB", formatBytes(1500))
        assertEquals("2.0 MB", formatBytes(2_000_000))
    }
}
