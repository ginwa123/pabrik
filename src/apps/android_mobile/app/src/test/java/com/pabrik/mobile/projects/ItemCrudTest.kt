package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

data class Item(val id: String, val name: String)

class ItemCrudTest {

    private val items = listOf(Item("a", "A"), Item("b", "B"), Item("c", "C"))

    @Test
    fun removeExistingReturnsNewListAndItem() {
        val (next, removed) = ItemCrud.remove(items, { it.id }, "b")
        assertEquals(listOf("a", "c"), next.map { it.id })
        assertEquals("b", removed?.id)
    }

    @Test
    fun removeMissingReturnsSameListAndNull() {
        val (next, removed) = ItemCrud.remove(items, { it.id }, "z")
        assertEquals(items, next)
        assertNull(removed)
    }

    @Test
    fun restoreAddsRemovedItem() {
        val (next, removed) = ItemCrud.remove(items, { it.id }, "b")
        val restored = ItemCrud.restore(next, removed, { it.id })
        assertEquals(listOf("a", "c", "b"), restored.map { it.id })
    }

    @Test
    fun restoreDoesNotDuplicate() {
        val restored = ItemCrud.restore(items, Item("b", "B"), { it.id })
        assertEquals(items, restored)
    }

    @Test
    fun restoreNullIsNoop() {
        assertEquals(items, ItemCrud.restore(items, null, { it.id }))
    }

    @Test
    fun renameUpdatesName() {
        val next = ItemCrud.rename(items, { it.id }, "b", "Renamed") { it, n -> it.copy(name = n) }
        assertEquals("Renamed", next.first { it.id == "b" }.name)
        assertEquals("A", next.first { it.id == "a" }.name)
    }

    @Test
    fun renameMissingIsNoop() {
        val next = ItemCrud.rename(items, { it.id }, "z", "X") { it, n -> it.copy(name = n) }
        assertEquals(items, next)
    }
}
