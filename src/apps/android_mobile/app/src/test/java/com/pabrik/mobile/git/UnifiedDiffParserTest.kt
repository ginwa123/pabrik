package com.pabrik.mobile.git

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedDiffParserTest {

    private val diff = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         keep
        -old
        +new
         tail
    """.trimIndent()

    @Test
    fun anEmptyDiffParsesToNothing() {
        val parsed = UnifiedDiffParser.parse("")
        assertTrue(parsed.lines.isEmpty())
        assertEquals(0, parsed.added)
        assertEquals(0, parsed.removed)
    }

    @Test
    fun theHunkHeaderIsKeptAsAHunkLine() {
        val parsed = UnifiedDiffParser.parse(diff)
        assertEquals("hunk", parsed.lines.first().type)
    }

    @Test
    fun fileHeadersAreDropped() {
        val parsed = UnifiedDiffParser.parse(diff)
        assertTrue(parsed.lines.none { it.content.startsWith("diff --git") })
        assertTrue(parsed.lines.none { it.content.startsWith("index ") })
        assertTrue(parsed.lines.none { it.content.startsWith("---") })
        assertTrue(parsed.lines.none { it.content.startsWith("+++") })
    }

    @Test
    fun anAddedLineIsCountedAndNumberedOnTheNewSide() {
        val parsed = UnifiedDiffParser.parse(diff)
        val add = parsed.lines.single { it.type == "add" }
        assertEquals("new", add.content)
        assertEquals(2, add.newLineNum)
        assertEquals(null, add.oldLineNum)
        assertEquals(1, parsed.added)
    }

    @Test
    fun aRemovedLineIsCountedAndNumberedOnTheOldSide() {
        val parsed = UnifiedDiffParser.parse(diff)
        val remove = parsed.lines.single { it.type == "remove" }
        assertEquals("old", remove.content)
        assertEquals(2, remove.oldLineNum)
        assertEquals(null, remove.newLineNum)
        assertEquals(1, parsed.removed)
    }

    @Test
    fun aContextLineAdvancesBothSides() {
        val parsed = UnifiedDiffParser.parse(diff)
        val context = parsed.lines.filter { it.type == "context" }
        assertEquals(listOf("keep", "tail"), context.map { it.content })
        assertEquals(listOf(1, 3), context.map { it.oldLineNum })
        assertEquals(listOf(1, 3), context.map { it.newLineNum })
    }

    @Test
    fun lineIndexesAreSequential() {
        val parsed = UnifiedDiffParser.parse(diff)
        assertEquals(parsed.lines.indices.toList(), parsed.lines.map { it.lineIndex })
    }

    @Test
    fun aBlankLineInsideAHunkIsAnEmptyLine() {
        val parsed = UnifiedDiffParser.parse("@@ -1,1 +1,1 @@\n\n")
        assertTrue(parsed.lines.any { it.type == "empty" })
    }

    @Test
    fun contentBeforeTheFirstHunkIsIgnored() {
        val parsed = UnifiedDiffParser.parse("random preamble\n@@ -1,1 +1,1 @@\n+x")
        assertEquals(1, parsed.added)
        assertTrue(parsed.lines.none { it.content == "random preamble" })
    }

    @Test
    fun aHunkHeaderWithoutCountsStartsAtLineOne() {
        val parsed = UnifiedDiffParser.parse("@@ -1 +1 @@\n+x")
        assertEquals(1, parsed.lines.single { it.type == "add" }.newLineNum)
    }
}
