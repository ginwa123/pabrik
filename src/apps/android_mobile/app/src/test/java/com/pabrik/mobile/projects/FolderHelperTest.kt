package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

data class FItem(val id: String, val type: String, val parent: String?)

class FolderHelperTest {

    private val items = listOf(
        FItem("f1", "folder", null),
        FItem("f2", "folder", null),
        FItem("i1", "kanban", "f1"),
        FItem("i2", "chat", "f1"),
        FItem("i3", "kanban", null),
    )

    @Test
    fun isFolder() {
        assertTrue(FolderHelper.isFolder("folder"))
        assertEquals(false, FolderHelper.isFolder("kanban"))
    }

    @Test
    fun childrenOfFolder() {
        val children = FolderHelper.childrenOf(items, "f1") { it.parent }
        assertEquals(listOf("i1", "i2"), children.map { it.id })
    }

    @Test
    fun childrenOfEmptyFolder() {
        val children = FolderHelper.childrenOf(items, "f2") { it.parent }
        assertTrue(children.isEmpty())
    }

    @Test
    fun topLevelItems() {
        val top = FolderHelper.topLevel(items) { it.parent }
        assertEquals(listOf("f1", "f2", "i3"), top.map { it.id })
    }
}
