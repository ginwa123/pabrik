package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetryBackoffHelperTest {

    @Test
    fun validRetryCount() {
        assertTrue(RetryBackoffHelper.isValidRetryCount(0))
        assertTrue(RetryBackoffHelper.isValidRetryCount(5))
        assertTrue(RetryBackoffHelper.isValidRetryCount(10))
        assertFalse(RetryBackoffHelper.isValidRetryCount(-1))
        assertFalse(RetryBackoffHelper.isValidRetryCount(11))
    }

    @Test
    fun validBackoffMs() {
        assertTrue(RetryBackoffHelper.isValidBackoffMs(100))
        assertTrue(RetryBackoffHelper.isValidBackoffMs(60_000))
        assertFalse(RetryBackoffHelper.isValidBackoffMs(50))
        assertFalse(RetryBackoffHelper.isValidBackoffMs(60_001))
    }

    @Test
    fun nextBackoffMs() {
        assertEquals(200L, RetryBackoffHelper.nextBackoffMs(100, 1))
        assertEquals(400L, RetryBackoffHelper.nextBackoffMs(100, 2))
    }

    @Test
    fun nextBackoffMsCapped() {
        assertEquals(60_000L, RetryBackoffHelper.nextBackoffMs(1000, 10))
    }
}
