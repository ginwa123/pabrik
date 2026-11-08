package com.pabrik.mobile.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceMemoriesHelperTest {

    private fun memory(id: String, content: String, tags: List<String> = emptyList(), updated: Long = 0) =
        WorkspaceMemory(id, content, tags, updated)

    @Test
    fun blankContentIsInvalid() {
        assertFalse(WorkspaceMemoriesHelper.isValidContent("   "))
    }

    @Test
    fun nonBlankContentIsValid() {
        assertTrue(WorkspaceMemoriesHelper.isValidContent("remember this"))
    }

    @Test
    fun contentOverTheCapIsInvalid() {
        assertFalse(WorkspaceMemoriesHelper.isValidContent("a".repeat(100_001)))
    }

    @Test
    fun tagsAreSplitOnCommasAndWhitespace() {
        assertEquals(listOf("a", "b", "c"), WorkspaceMemoriesHelper.parseTags("a, b  c"))
    }

    @Test
    fun duplicateTagsAreDropped() {
        assertEquals(listOf("a", "b"), WorkspaceMemoriesHelper.parseTags("a,b,a"))
    }

    @Test
    fun emptyTagInputYieldsNoTags() {
        assertTrue(WorkspaceMemoriesHelper.parseTags("  ,  ").isEmpty())
    }

    @Test
    fun tagsJoinWithCommas() {
        assertEquals("a,b", WorkspaceMemoriesHelper.joinTags(listOf("a", "b")))
    }

    @Test
    fun emptyQueryReturnsEveryMemory() {
        val all = listOf(memory("1", "a"), memory("2", "b"))
        assertEquals(all, WorkspaceMemoriesHelper.filterByQuery(all, "  "))
    }

    @Test
    fun queryMatchesTheContent() {
        val all = listOf(memory("1", "deploy notes"), memory("2", "other"))
        assertEquals(listOf("1"), WorkspaceMemoriesHelper.filterByQuery(all, "deploy").map { it.id })
    }

    @Test
    fun queryMatchesATag() {
        val all = listOf(memory("1", "x", listOf("release")), memory("2", "y"))
        assertEquals(listOf("1"), WorkspaceMemoriesHelper.filterByQuery(all, "release").map { it.id })
    }

    @Test
    fun sortingPutsTheMostRecentlyUpdatedFirst() {
        val all = listOf(memory("old", "a", updated = 10), memory("new", "b", updated = 30))
        assertEquals(listOf("new", "old"), WorkspaceMemoriesHelper.sortByUpdatedDesc(all).map { it.id })
    }

    @Test
    fun dedupeKeepsTheFirstOfEachContent() {
        val all = listOf(memory("1", "same"), memory("2", "same"), memory("3", "other"))
        assertEquals(listOf("1", "3"), WorkspaceMemoriesHelper.dedupe(all).map { it.id })
    }

    @Test
    fun dedupeIgnoresSurroundingWhitespace() {
        val all = listOf(memory("1", "same"), memory("2", "  same  "))
        assertEquals(listOf("1"), WorkspaceMemoriesHelper.dedupe(all).map { it.id })
    }
}
