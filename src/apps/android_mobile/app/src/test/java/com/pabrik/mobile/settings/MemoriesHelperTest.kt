package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoriesHelperTest {

    private fun memory(name: String, title: String = "", updated: Long = 0) =
        MemoryItem(name, title, updated)

    @Test
    fun blankNameIsInvalid() {
        assertFalse(MemoriesHelper.isValidName("   "))
    }

    @Test
    fun nameWithAPathSeparatorIsInvalid() {
        assertFalse(MemoriesHelper.isValidName("a/b"))
    }

    @Test
    fun plainNameIsValid() {
        assertTrue(MemoriesHelper.isValidName("notes"))
    }

    @Test
    fun blankContentIsInvalid() {
        assertFalse(MemoriesHelper.isValidContent("  \n "))
    }

    @Test
    fun nonBlankContentIsValid() {
        assertTrue(MemoriesHelper.isValidContent("hello"))
    }

    @Test
    fun newMemoryWithInvalidNameIsRejected() {
        assertEquals("NameInvalid", MemoriesHelper.validateNew("", "body", emptyList()))
    }

    @Test
    fun newMemoryWithATakenNameIsRejected() {
        assertEquals("NameTaken", MemoriesHelper.validateNew("Notes", "body", listOf("notes")))
    }

    @Test
    fun newMemoryWithEmptyContentIsRejected() {
        assertEquals("ContentRequired", MemoriesHelper.validateNew("notes", "  ", emptyList()))
    }

    @Test
    fun validNewMemoryPassesValidation() {
        assertNull(MemoriesHelper.validateNew("notes", "body", listOf("other")))
    }

    @Test
    fun emptyQueryReturnsEveryMemory() {
        val all = listOf(memory("a"), memory("b"))
        assertEquals(all, MemoriesHelper.filter(all, "  "))
    }

    @Test
    fun queryMatchesTheNameCaseInsensitively() {
        val all = listOf(memory("Alpha"), memory("beta"))
        assertEquals(listOf("Alpha"), MemoriesHelper.filter(all, "alp").map { it.name })
    }

    @Test
    fun queryMatchesTheTitle() {
        val all = listOf(memory("a", "Release notes"), memory("b", "Other"))
        assertEquals(listOf("a"), MemoriesHelper.filter(all, "release").map { it.name })
    }

    @Test
    fun sortingPutsTheMostRecentlyUpdatedFirst() {
        val all = listOf(memory("old", updated = 10), memory("new", updated = 30), memory("mid", updated = 20))
        assertEquals(listOf("new", "mid", "old"), MemoriesHelper.sortByUpdatedDesc(all).map { it.name })
    }
}
