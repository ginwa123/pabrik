package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.testing.FakeSseBus
import com.pabrik.mobile.testing.InMemoryChatCache
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What a refetch does to a turn the stream stopped reporting on. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelStreamingReconcileTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(30) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }
    }

    private fun reconcileTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class MemorySessionStore(var value: String? = "tok") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    /** Routes by path so one fake can answer the three reads a chat screen makes: the transcript, the worker list, and the in-memory snapshot. */
    private class FixtureTransport : AuthTransport {
        /** What `GET /api/llm/session/{id}/messages` answers. */
        var messages: String = emptyPage()

        /** What `GET /api/workers?session_id=…` answers. */
        var workers: String = runningWorker()

        /** A worker read that fails, which must change nothing. */
        var workersUnavailable = false

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse = when {
            path.startsWith("/api/workers") ->
                if (workersUnavailable) {
                    throw IOException("offline")
                } else {
                    AuthHttpResponse(200, workers)
                }

            // `/queue_messages` does not contain "/messages" — the separator is `_` — so the two paths cannot be confused for one another.
            path.contains("/messages") -> AuthHttpResponse(200, messages)
            path.endsWith("/stream") -> AuthHttpResponse(200, """{"active":false,"content":""}""")
            else -> AuthHttpResponse(200, "{}")
        }

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse = AuthHttpResponse(201, "{}")
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        bus: FakeSseBus = FakeSseBus(),
        transport: FixtureTransport = FixtureTransport(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_790_835_984_283_000L },
    ).also { it.onUserChanged("user_a") }

    /** Opens the chat, connects, and gets a delta on screen — a run the phone is watching, with a placeholder it is still filling. */
    private suspend fun TestScope.openedStreamingTurn(
        schedulers: Schedulers,
        transport: FixtureTransport,
        bus: FakeSseBus,
    ): ChatViewModel {
        val model = model(schedulers.ioDispatcher, bus, transport)
        model.openSession("sess_1")
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()
        bus.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = PARTIAL_ANSWER))
        schedulers.drain()
        assertTrue("precondition: the turn is streaming", model.uiState.value.isStreaming)
        assertEquals(
            "precondition: one placeholder row",
            1,
            model.uiState.value.messages.count { it.isStreaming },
        )
        return model
    }

    /** The socket drops and comes back, which is the only repair there is. */
    private fun reconnect(schedulers: Schedulers, bus: FakeSseBus) {
        bus.state(ChatStreamState.Reconnecting)
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()
    }

    @Test
    fun `a refetch replaces the placeholder with the turn that finished`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // The run finished on the server while this phone was not looking
            transport.messages = pageOf(assistantTurn(SAVED_ANSWER))
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse("the header must stop claiming a run", state.isStreaming)
            assertTrue(
                "no row may still claim to be mid-sentence",
                state.messages.none { it.isStreaming },
            )
            assertEquals(
                "the persisted turn replaces the stub",
                listOf(SAVED_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a refetch during a live run leaves the streaming turn exactly as it was`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // The same reconnect, but the worker is still there — so the answer is still arriving and nothing may be settled.
            transport.workers = runningWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a live run must keep its flag", state.isStreaming)
            assertEquals(
                "the placeholder must keep the text it streamed",
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a refetch whose worker read failed settles nothing`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // "No answer" is not "no worker".
            transport.workersUnavailable = true
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a failed read must not claim the run ended", state.isStreaming)
            assertEquals(
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    @Test
    fun `a run that ended without writing a row keeps its text and stops claiming to stream`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // No worker and no row: the turn can never be written now, because nothing is running to write it.
            transport.messages = emptyPage()
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse("there is no run left to claim", state.isStreaming)
            assertEquals(
                "the text the reader watched arrive must not be thrown away",
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
            assertTrue(
                "and it must not keep the streaming hint",
                state.messages.none { it.isStreaming },
            )
        }

    @Test
    fun `an older turn that happens to start the same way does not retire the placeholder`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // "Your URL" was the whole of a *previous* answer, and the turn in flight starts with the same words.
            transport.messages = pageOf(
                assistantTurn("Your URL", id = "old", nanos = OLD_NANOS),
                assistantTurn("Completely different", id = "new", nanos = NEW_NANOS),
            )
            transport.workers = runningWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertTrue("a live run keeps its flag", state.isStreaming)
            assertEquals(
                "the placeholder must survive a decoy",
                1,
                state.messages.count { it.isStreaming },
            )
        }

    @Test
    fun `a refetch with no placeholder on screen leaves the flag to whatever wrote it`() =
        reconcileTest { schedulers ->
            val transport = FixtureTransport()
            val bus = FakeSseBus()
            val model = openedStreamingTurn(schedulers, transport, bus)

            // A normal turn: `chunk_final` lands, the placeholder stays on screen by design until the canonical row does, and a refetch arrives in that window.
            bus.emit(ChatStreamEvent.ChunkFinished(sessionId = "sess_1", totalTokens = null))
            schedulers.drain()
            transport.messages = emptyPage()
            transport.workers = noWorker()
            reconnect(schedulers, bus)

            val state = model.uiState.value
            assertFalse(state.isStreaming)
            assertEquals(
                listOf(PARTIAL_ANSWER),
                state.messages.map { it.content },
            )
        }

    private companion object {
        /** A prefix of [SAVED_ANSWER] — deltas only ever append. */
        const val PARTIAL_ANSWER = "Your URL sugg"

        const val SAVED_ANSWER =
            "Your URL suggestion\n\nYou're right that /app/<ws>/doc/<id> is the better shape."

        const val OLD_NANOS = 1_790_835_900_000_000_000L
        const val NEW_NANOS = 1_790_835_984_283_000_000L

        fun emptyPage(): String =
            """{"messages":[],"has_more":false,"next_cursor":null,"total":0}"""

        /** One live worker on `sess_1`, exactly as `updateWorker` broadcasts it. */
        fun runningWorker(): String =
            """{"workers":[{"id":"sess_1","session_id":"sess_1","working_directory":"/home/ginwa",""" +
                """"last_activity":"2026-10-01 13:25:00","last_activity_description":"streaming",""" +
                """"created_at":"2026-10-01 13:24:00","status":"running","is_running":true,""" +
                """"queue_count":0}],"count":1}"""

        /** No workers at all — the run is over. */
        fun noWorker(): String = """{"workers":[],"count":0}"""

        fun pageOf(vararg rows: String): String =
            """{"messages":[${rows.joinToString(",")}],"has_more":false,""" +
                """"next_cursor":null,"total":${rows.size}}"""

        /** A persisted assistant turn, in the shape `llm_history` rows take on the wire: `created_at` is a *string* holding a nanosecond epoch. */
        fun assistantTurn(
            content: String,
            id: String = "saved_turn",
            nanos: Long = NEW_NANOS,
        ): String =
            """{"id":"$id","role":"assistant","content":${quote(content)},""" +
                """"created_at":"$nanos","finish_reason":"stop"}"""

        fun quote(value: String): String =
            "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
    }
}