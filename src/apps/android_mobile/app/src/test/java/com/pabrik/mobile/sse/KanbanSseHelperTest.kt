package com.pabrik.mobile.sse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KanbanSseHelperTest {

    @Test
    fun anEventForTheActiveWorkspaceIsHandled() {
        assertTrue(KanbanSseHelper.shouldHandle("ws1", "ws1"))
    }

    @Test
    fun anEventForAnotherWorkspaceIsDropped() {
        assertFalse(KanbanSseHelper.shouldHandle("ws2", "ws1"))
    }

    @Test
    fun aColumnEventIsAColumnFamily() {
        assertEquals("column", KanbanSseHelper.eventFamily(hasColumnId = true, hasTaskId = false))
    }

    @Test
    fun aTaskEventIsATaskFamily() {
        assertEquals("task", KanbanSseHelper.eventFamily(hasColumnId = false, hasTaskId = true))
    }

    @Test
    fun anEventWithNeitherIdIsUnknown() {
        assertEquals("unknown", KanbanSseHelper.eventFamily(hasColumnId = false, hasTaskId = false))
    }

    @Test
    fun theHumanTouchedActionIsRecognised() {
        assertTrue(KanbanSseHelper.isHumanTouched("human_touched"))
    }

    @Test
    fun anotherActionIsNotHumanTouched() {
        assertFalse(KanbanSseHelper.isHumanTouched("moved"))
    }

    @Test
    fun aCachedTaskWithNoSearchOrSortRefetchesItsColumn() {
        assertTrue(KanbanSseHelper.shouldRefetchColumn(hasSearch = false, hasCustomSort = false, isCached = true))
    }

    @Test
    fun anActiveSearchForcesAFullRefetch() {
        assertFalse(KanbanSseHelper.shouldRefetchColumn(hasSearch = true, hasCustomSort = false, isCached = true))
    }

    @Test
    fun aCustomSortForcesAFullRefetch() {
        assertFalse(KanbanSseHelper.shouldRefetchColumn(hasSearch = false, hasCustomSort = true, isCached = true))
    }

    @Test
    fun anUncachedTaskForcesAFullRefetch() {
        assertFalse(KanbanSseHelper.shouldRefetchColumn(hasSearch = false, hasCustomSort = false, isCached = false))
    }

    @Test
    fun aMutationInsideTheTtlIsRecent() {
        assertTrue(KanbanSseHelper.isRecentLocalMutation(lastMutationAt = 1_000, nowMillis = 2_000))
    }

    @Test
    fun aMutationAtTheTtlBoundaryIsNoLongerRecent() {
        assertFalse(KanbanSseHelper.isRecentLocalMutation(lastMutationAt = 1_000, nowMillis = 2_500))
    }

    @Test
    fun aMissingMutationIsNotRecent() {
        assertFalse(KanbanSseHelper.isRecentLocalMutation(lastMutationAt = 0, nowMillis = 2_000))
    }
}
