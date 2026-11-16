package com.pabrik.mobile.worker

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The store is what every spinner on every screen reads, so its transitions are the whole feature: a session that is lit when it should be dark, or dark when it … */
class RunningSessionsStoreTest {
    private val store = RunningSessionsStore()

    @Test
    fun `a new store has nothing running`() {
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `created marks a session running`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")

        assertEquals(setOf("task_1"), store.runningSessionIds.value)
        assertTrue(store.isRunning("task_1"))
    }

    @Test
    fun `deleted clears a session`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")
        store.apply(RunningSessionsStore.ACTION_DELETED, "task_1")

        assertTrue(store.runningSessionIds.value.isEmpty())
        assertFalse(store.isRunning("task_1"))
    }

    @Test
    fun `a heartbeat keeps a session running without duplicating it`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")
        store.apply(RunningSessionsStore.ACTION_UPDATED, "task_1")
        store.apply(RunningSessionsStore.ACTION_UPDATED, "task_1")

        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `a heartbeat after a delete puts the spinner back`() {
        // Counter-intuitive, and deliberate.
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")
        store.apply(RunningSessionsStore.ACTION_DELETED, "task_1")
        store.apply(RunningSessionsStore.ACTION_UPDATED, "task_1")

        assertTrue(store.isRunning("task_1"))
    }

    @Test
    fun `an action this app does not know counts as running, not idle`() {
        // `worker_unknown` is a real event name on the wire for an unclassified action.
        store.apply("reordered", "task_1")

        assertTrue(store.isRunning("task_1"))
    }

    @Test
    fun `a blank session id is ignored`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "")

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a null session id reads as not running`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")

        assertFalse(store.isRunning(null))
        assertFalse(store.isRunning("task_2"))
    }

    @Test
    fun `replace swaps the whole set`() {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_gone")
        store.replace(setOf("task_1", "task_2"))

        assertEquals(setOf("task_1", "task_2"), store.runningSessionIds.value)
    }

    @Test
    fun `replace drops a session that stopped while the socket was down`() {
        // The resync is the only repair available: the server keeps no replay buffer, so a `deleted` that happened mid-outage was never sent.
        store.replace(setOf("task_1", "task_2"))
        store.replace(setOf("task_1"))

        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `replace with an empty list turns every spinner off`() {
        store.replace(setOf("task_1"))
        store.replace(emptySet())

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `clear drops everything`() {
        store.replace(setOf("task_1", "task_2"))
        store.clear()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a no-op transition does not re-emit the same set`() {
        // StateFlow conflates by equality, so emitting an equal set re-runs no collector and costs a comparison.
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")
        val afterCreate = store.runningSessionIds.value

        store.apply(RunningSessionsStore.ACTION_UPDATED, "task_1")
        assertTrue(afterCreate === store.runningSessionIds.value)

        store.replace(setOf("task_1"))
        assertTrue(afterCreate === store.runningSessionIds.value)

        store.clear()
        store.clear()
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `the flow is readable by a collector`() = runTest {
        store.apply(RunningSessionsStore.ACTION_CREATED, "task_1")

        assertEquals(setOf("task_1"), store.runningSessionIds.first())
    }
}
