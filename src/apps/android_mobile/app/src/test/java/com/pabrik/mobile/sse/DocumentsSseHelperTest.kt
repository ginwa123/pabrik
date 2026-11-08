package com.pabrik.mobile.sse

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentsSseHelperTest {

    @Test
    fun anEventForTheActiveWorkspaceIsHandled() {
        assertTrue(DocumentsSseHelper.shouldHandle("ws1", "ws1"))
    }

    @Test
    fun anEventForAnotherWorkspaceIsDropped() {
        assertFalse(DocumentsSseHelper.shouldHandle("ws2", "ws1"))
    }

    @Test
    fun theFirstRefreshIsAlwaysAllowed() {
        assertTrue(DocumentsSseHelper.shouldRefresh(lastFetchAt = 0, nowMillis = 1_000))
    }

    @Test
    fun aRefreshInsideTheThrottleWindowIsSkipped() {
        assertFalse(DocumentsSseHelper.shouldRefresh(lastFetchAt = 1_000, nowMillis = 5_000))
    }

    @Test
    fun aRefreshAtTheThrottleBoundaryIsAllowed() {
        assertTrue(DocumentsSseHelper.shouldRefresh(lastFetchAt = 1_000, nowMillis = 11_000))
    }

    @Test
    fun aCustomThrottleIsHonoured() {
        assertTrue(DocumentsSseHelper.shouldRefresh(lastFetchAt = 1_000, nowMillis = 2_000, throttleMs = 500))
    }
}
