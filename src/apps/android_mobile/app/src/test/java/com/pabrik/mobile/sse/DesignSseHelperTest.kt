package com.pabrik.mobile.sse

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DesignSseHelperTest {

    @Test
    fun anEventForTheActiveWorkspaceIsHandled() {
        assertTrue(DesignSseHelper.shouldHandle("ws1", "ws1"))
    }

    @Test
    fun anEventForAnotherWorkspaceIsDropped() {
        assertFalse(DesignSseHelper.shouldHandle("ws2", "ws1"))
    }

    @Test
    fun aSingleElementIdIsExtracted() {
        assertEquals(listOf("e1"), DesignSseHelper.extractElementIds("e1", null))
    }

    @Test
    fun AListOfElementIdsIsExtracted() {
        assertEquals(listOf("e1", "e2"), DesignSseHelper.extractElementIds(null, listOf("e1", "e2")))
    }

    @Test
    fun theSingleIdAndTheListAreMergedWithoutDuplicates() {
        assertEquals(listOf("e1", "e2"), DesignSseHelper.extractElementIds("e1", listOf("e1", "e2")))
    }

    @Test
    fun blankIdsAreDropped() {
        assertEquals(listOf("e1"), DesignSseHelper.extractElementIds("  ", listOf("e1", "")))
    }

    @Test
    fun noIdsExtractToNothing() {
        assertTrue(DesignSseHelper.extractElementIds(null, null).isEmpty())
    }

    @Test
    fun everyIdInsideTheTtlIsLocal() {
        val mutations = mapOf("e1" to 1_000L, "e2" to 1_200L)
        assertTrue(DesignSseHelper.allLocal(listOf("e1", "e2"), mutations, nowMillis = 2_000))
    }

    @Test
    fun oneStaleIdMakesTheBatchNonLocal() {
        val mutations = mapOf("e1" to 1_000L, "e2" to 100L)
        assertFalse(DesignSseHelper.allLocal(listOf("e1", "e2"), mutations, nowMillis = 2_000))
    }

    @Test
    fun anUnknownIdMakesTheBatchNonLocal() {
        assertFalse(DesignSseHelper.allLocal(listOf("e1"), emptyMap(), nowMillis = 2_000))
    }

    @Test
    fun anEmptyBatchIsNotLocal() {
        assertFalse(DesignSseHelper.allLocal(emptyList(), emptyMap(), nowMillis = 2_000))
    }
}
