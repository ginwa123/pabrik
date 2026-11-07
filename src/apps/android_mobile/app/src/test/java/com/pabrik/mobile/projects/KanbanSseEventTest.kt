package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KanbanSseEventTest {

    @Test
    fun parseColumnEvent() {
        val json = """{"action":"created","workspace_id":"w1","item_id":"i1","column_id":"c1","new_name":"Col","new_position":2}"""
        val e = KanbanSseEvent.parse(json) as KanbanSseEvent.Column
        assertEquals("created", e.action)
        assertEquals("w1", e.workspaceId)
        assertEquals("i1", e.itemId)
        assertEquals("c1", e.columnId)
        assertEquals("Col", e.newName)
        assertEquals(2, e.newPosition)
    }

    @Test
    fun parseTaskEvent() {
        val json = """{"action":"moved","workspace_id":"w1","item_id":"i1","task_id":"t1","new_column_id":"c2","new_position":3,"needs_human_review":true}"""
        val e = KanbanSseEvent.parse(json) as KanbanSseEvent.Task
        assertEquals("moved", e.action)
        assertEquals("t1", e.taskId)
        assertEquals("c2", e.newColumnId)
        assertEquals(3, e.newPosition)
        assertEquals(true, e.needsHumanReview)
    }

    @Test
    fun parseHumanTouchedNullReview() {
        val json = """{"action":"human_touched","workspace_id":"w1","item_id":"i1","task_id":"t1"}"""
        val e = KanbanSseEvent.parse(json) as KanbanSseEvent.Task
        assertEquals("human_touched", e.action)
        assertEquals(null, e.needsHumanReview)
    }

    @Test
    fun parseReturnsNullOnBadJson() {
        assertEquals(null, KanbanSseEvent.parse("not json"))
    }

    @Test
    fun parseColumnWithoutPosition() {
        val json = """{"action":"deleted","workspace_id":"w1","item_id":"i1","column_id":"c1"}"""
        val e = KanbanSseEvent.parse(json) as KanbanSseEvent.Column
        assertEquals("deleted", e.action)
        assertEquals(null, e.newPosition)
        assertEquals(null, e.newName)
    }
}
