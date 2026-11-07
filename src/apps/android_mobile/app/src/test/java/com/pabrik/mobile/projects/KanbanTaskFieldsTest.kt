package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KanbanTaskFieldsTest {

    @Test
    fun validTitle() {
        assertTrue(KanbanTaskFields.isValidTitle("Hello"))
        assertFalse(KanbanTaskFields.isValidTitle("   "))
        assertFalse(KanbanTaskFields.isValidTitle(""))
    }

    @Test
    fun parseTagsComma() {
        assertEquals(listOf("a", "b"), KanbanTaskFields.parseTags("a, b"))
    }

    @Test
    fun parseTagsSpace() {
        assertEquals(listOf("a", "b"), KanbanTaskFields.parseTags("a b"))
    }

    @Test
    fun parseTagsDedup() {
        assertEquals(listOf("a", "b"), KanbanTaskFields.parseTags("a, a, b"))
    }

    @Test
    fun parseTagsEmpty() {
        assertEquals(emptyList<String>(), KanbanTaskFields.parseTags("   "))
    }

    @Test
    fun joinTags() {
        assertEquals("a, b", KanbanTaskFields.joinTags(listOf("a", "b")))
    }

    @Test
    fun validPrLink() {
        assertTrue(KanbanTaskFields.isValidPrLink(""))
        assertTrue(KanbanTaskFields.isValidPrLink("https://github.com/x/y/pull/1"))
        assertFalse(KanbanTaskFields.isValidPrLink("not a url"))
    }
}
