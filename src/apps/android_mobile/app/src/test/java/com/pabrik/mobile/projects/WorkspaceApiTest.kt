package com.pabrik.mobile.projects

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceApiTest {

    @Test
    fun createPath() {
        assertEquals("/api/workspaces", WorkspaceApi.createPath())
    }

    @Test
    fun createBodyContainsName() {
        val body = JSONObject(WorkspaceApi.createBody("My WS"))
        assertEquals("My WS", body.getString("name"))
    }

    @Test
    fun deletePathEncodesId() {
        assertEquals("/api/workspaces/ws%201", WorkspaceApi.deletePath("ws 1"))
    }

    @Test
    fun reorderBodyContainsOrderedIds() {
        val body = JSONObject(WorkspaceApi.reorderBody(listOf("a", "b")))
        val arr = body.getJSONArray("ordered_ids")
        assertEquals(2, arr.length())
        assertEquals("a", arr.getString(0))
        assertEquals("b", arr.getString(1))
    }

    @Test
    fun createItemBodyDefaultsToFolder() {
        val body = JSONObject(WorkspaceApi.createItemBody("n", "/p"))
        assertEquals("folder", body.getString("item_type"))
        assertEquals("n", body.getString("name"))
        assertEquals("/p", body.getString("path"))
    }

    @Test
    fun deleteItemPath() {
        assertEquals("/api/workspaces/ws/items/it", WorkspaceApi.deleteItemPath("ws", "it"))
    }

    @Test
    fun parseWorkspaceReturnsId() {
        assertEquals("w1", WorkspaceApi.parseWorkspace("""{"id":"w1","name":"x"}"""))
    }

    @Test
    fun parseWorkspaceReturnsNullOnBadJson() {
        assertEquals(null, WorkspaceApi.parseWorkspace("not json"))
    }

    @Test
    fun listPath() {
        assertTrue(WorkspaceApi.listPath().contains("is_include_items=false"))
    }
}
