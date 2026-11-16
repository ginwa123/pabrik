package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The chat header's two rules, without a device. */
class ChatStatusTest {

    @Test
    fun `a worker with no deltas is still working`() {
        // The case this change is for.
        assertTrue(isChatWorking(isRunning = true, isStreaming = false))
    }

    @Test
    fun `a delta before the worker event is still working`() {
        // The other direction's gap: a send returns, the turn is queued, and the `workers` frame has not arrived yet.
        assertTrue(isChatWorking(isRunning = false, isStreaming = true))
    }

    @Test
    fun `neither signal means idle`() {
        assertFalse(isChatWorking(isRunning = false, isStreaming = false))
    }

    @Test
    fun `a working run outranks a live stream`() {
        assertEquals("Working…", chatStatusLabel(isWorking = true, isLive = true))
    }

    @Test
    fun `a live stream with no run says so`() {
        assertEquals("Live", chatStatusLabel(isWorking = false, isLive = true))
    }

    @Test
    fun `a dead stream with no run says reconnecting`() {
        assertEquals("Reconnecting…", chatStatusLabel(isWorking = false, isLive = false))
    }

    @Test
    fun `a working run says so even when the stream is down`() {
        // The worker's own answer outlives the socket.
        assertEquals("Working…", chatStatusLabel(isWorking = true, isLive = false))
    }
}
