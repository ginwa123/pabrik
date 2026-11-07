package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KanbanSettingsTest {

    @Test
    fun validColumnName() {
        assertTrue(KanbanSettings.isValidColumnName("Todo"))
        assertFalse(KanbanSettings.isValidColumnName("   "))
        assertFalse(KanbanSettings.isValidColumnName(""))
    }

    @Test
    fun moveColumnForward() {
        val cols = listOf("a", "b", "c", "d")
        val moved = KanbanSettings.moveColumn(cols, 0, 2)
        assertEquals(listOf("b", "c", "a", "d"), moved)
    }

    @Test
    fun moveColumnBackward() {
        val cols = listOf("a", "b", "c", "d")
        val moved = KanbanSettings.moveColumn(cols, 3, 1)
        assertEquals(listOf("a", "d", "b", "c"), moved)
    }

    @Test
    fun moveColumnSameIndex() {
        val cols = listOf("a", "b", "c")
        assertEquals(cols, KanbanSettings.moveColumn(cols, 1, 1))
    }

    @Test
    fun moveColumnOutOfBounds() {
        val cols = listOf("a", "b", "c")
        assertEquals(cols, KanbanSettings.moveColumn(cols, 5, 1))
        assertEquals(cols, KanbanSettings.moveColumn(cols, 1, 5))
    }

    @Test
    fun validProfileName() {
        assertTrue(KanbanSettings.isValidProfileName("gpt-4"))
        assertFalse(KanbanSettings.isValidProfileName(""))
    }
}
