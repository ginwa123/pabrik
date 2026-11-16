package com.pabrik.mobile.worker

import com.pabrik.mobile.chat.SseChannels
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the `/api/workers` contract the spinner depends on. */
class WorkerApiTest {
    @Test
    fun `the workers path asks for the page the server defaults to`() {
        assertEquals("/api/workers?limit=50", WorkerApi.workersPath())
        assertEquals("/api/workers?limit=200", WorkerApi.workersPath(limit = 200))
    }

    @Test
    fun `there is one channel set for the whole app, and it includes workers`() {
        // The bus that owns the socket subscribes `llm` and `queue` as bare central keys with no session id and every subscriber filters by `event.session_id` itself.
        val path = SseChannels.eventsPath()

        assertEquals("/api/events?channels=llm,queue,sessions,workers", path)
        assertTrue("workers must be on the shared connection", path.contains("workers"))
        assertTrue("llm must be on the shared connection", path.contains("llm"))
        assertTrue("queue must be on the shared connection", path.contains("queue"))
        assertTrue("sessions must be on the shared connection", path.contains("sessions"))
        // A per-session routing key would need a socket per open chat, which is the thing this exists to avoid.
        assertFalse("no per-session channel key", path.contains(":"))
    }

    @Test
    fun `one row becomes one running session`() {
        val body = """
            {
                "workers": [
                    {
                        "id": "task_1",
                        "session_id": "task_1",
                        "working_directory": "/home/ginwa/repo",
                        "last_activity": 1756900000,
                        "last_activity_description": "running tool: exec_read",
                        "created_at": "2026-09-03 12:00:00",
                        "status": "running",
                        "is_running": true,
                        "queue_count": 0
                    }
                ],
                "count": 1
            }
        """.trimIndent()

        assertEquals(setOf("task_1"), WorkerApi.parseRunningSessionIds(body))
    }

    @Test
    fun `every returned row is busy regardless of the flags it carries`() {
        // `status` and `is_running` are hardcoded by the server, so a row with `is_running: false` still means a worker exists.
        val body = """
            {
                "workers": [
                    {"id": "task_1", "session_id": "task_1", "status": "running", "is_running": true},
                    {"id": "task_2", "session_id": "task_2", "status": "done", "is_running": false}
                ],
                "count": 2
            }
        """.trimIndent()

        assertEquals(setOf("task_1", "task_2"), WorkerApi.parseRunningSessionIds(body))
    }

    @Test
    fun `a row with an empty session_id falls back to id`() {
        // The server populates both on `created`, but the list is built by one query that selects `id` first — so a row written by a path that only set `id` must still …
        val body = """
            {"workers": [{"id": "task_9", "session_id": ""}], "count": 1}
        """.trimIndent()

        assertEquals(setOf("task_9"), WorkerApi.parseRunningSessionIds(body))
    }

    @Test
    fun `a row with a null session_id falls back to id`() {
        val body = """{"workers": [{"id": "task_9", "session_id": null}], "count": 1}"""

        assertEquals(setOf("task_9"), WorkerApi.parseRunningSessionIds(body))
    }

    @Test
    fun `a row with neither id nor session_id is dropped rather than guessed`() {
        val body = """{"workers": [{"working_directory": "/tmp"}], "count": 1}"""

        assertTrue(WorkerApi.parseRunningSessionIds(body)!!.isEmpty())
    }

    @Test
    fun `an empty list means nothing is running`() {
        assertEquals(emptySet<String>(), WorkerApi.parseRunningSessionIds("""{"workers": [], "count": 0}"""))
    }

    @Test
    fun `a missing workers array is unknown, not an empty list`() {
        // `count` is not the list.
        assertNull(WorkerApi.parseRunningSessionIds("""{"count": 0}"""))
    }

    @Test
    fun `duplicated rows collapse to one session`() {
        val body = """
            {"workers": [{"id": "task_1", "session_id": "task_1"}], "count": 1}
        """.trimIndent()

        assertEquals(setOf("task_1"), WorkerApi.parseRunningSessionIds(body))
    }
}
