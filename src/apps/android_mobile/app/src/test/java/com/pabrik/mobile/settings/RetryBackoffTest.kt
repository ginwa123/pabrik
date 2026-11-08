package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetryBackoffTest {

    @Test
    fun theFirstAttemptHasNoDelay() {
        assertEquals(0L, RetryBackoff.delayFor(0))
    }

    @Test
    fun theSecondAttemptWaitsTheBaseDelay() {
        assertEquals(1_000L, RetryBackoff.delayFor(1))
    }

    @Test
    fun eachAttemptDoublesTheDelay() {
        assertEquals(2_000L, RetryBackoff.delayFor(2))
        assertEquals(4_000L, RetryBackoff.delayFor(3))
        assertEquals(8_000L, RetryBackoff.delayFor(4))
    }

    @Test
    fun theDelayNeverExceedsTheCap() {
        assertEquals(60_000L, RetryBackoff.delayFor(20))
    }

    @Test
    fun aCustomBaseAndCapAreHonoured() {
        assertEquals(300L, RetryBackoff.delayFor(1, baseMs = 300, capMs = 1_000))
        assertEquals(1_000L, RetryBackoff.delayFor(5, baseMs = 300, capMs = 1_000))
    }

    @Test
    fun aHugeAttemptNumberDoesNotOverflow() {
        assertEquals(60_000L, RetryBackoff.delayFor(Int.MAX_VALUE))
    }

    @Test
    fun retryIsAllowedBeforeTheMaximumAttemptCount() {
        assertTrue(RetryBackoff.shouldRetry(0, 3))
        assertTrue(RetryBackoff.shouldRetry(2, 3))
    }

    @Test
    fun retryIsRefusedAtTheMaximumAttemptCount() {
        assertFalse(RetryBackoff.shouldRetry(3, 3))
    }
}
