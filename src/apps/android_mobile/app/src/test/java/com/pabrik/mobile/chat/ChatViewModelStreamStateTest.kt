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

/** What the chat stream's own state transitions do to `isStreaming`. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelStreamStateTest {

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

    private fun streamStateTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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

    private class FakeTransport(
        var messages: String = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
        var streamSnapshot: String = "",
        var offline: Boolean = false,
    ) : AuthTransport {
        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            return AuthHttpResponse(201, """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            return AuthHttpResponse(
                statusCode = 200,
                body = if (path.endsWith("/stream")) streamSnapshot else messages,
            )
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        bus: FakeSseBus = FakeSseBus(),
        transport: AuthTransport = FakeTransport(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_789_451_234_000L },
    ).also { it.onUserChanged("user_a") }

    /** Opens a session and gets a delta on screen, i.e. a run in progress. */
    private suspend fun TestScope.openStreamingTurn(
        schedulers: Schedulers,
        bus: FakeSseBus,
    ): ChatViewModel {
        val model = model(schedulers.ioDispatcher, bus)
        model.openSession("sess_1")
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()
        bus.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "part"))
        schedulers.drain()
        assertTrue("precondition: the turn is streaming", model.uiState.value.isStreaming)
        return model
    }

    /** No row may still claim to be mid-sentence. */
    private fun assertNoRowClaimsToStream(model: ChatViewModel) {
        assertTrue(
            "no transcript row may still render the streaming hint",
            model.uiState.value.messages.none { it.isStreaming },
        )
    }

    @Test
    fun `a terminal stream failure stops claiming the turn is streaming`() =
        streamStateTest { schedulers ->
            val bus = FakeSseBus()
            val model = openStreamingTurn(schedulers, bus)

            // The pump `return`s on a rejected handshake instead of retrying, so neither `chunk_final` nor `llm_full` is ever coming for this turn.
            bus.state(ChatStreamState.Failed("The event stream is unavailable (401)."))
            schedulers.drain()

            assertFalse(model.uiState.value.isStreaming)
            assertFalse(isChatWorking(isRunning = false, isStreaming = model.uiState.value.isStreaming))
            assertEquals("The event stream is unavailable (401).", model.uiState.value.errorMessage)
            // The row flag too, not just the state's: `StreamingHint` reads the row, so clearing only `ChatUiState.isStreaming` leaves a "streaming…" line under a turn that …
            assertNoRowClaimsToStream(model)
        }

    @Test
    fun `an is_error frame clears the flag too, the way a terminal failure now does`() =
        streamStateTest { schedulers ->
            val bus = FakeSseBus()
            val model = openStreamingTurn(schedulers, bus)

            // `llm_full` with `is_error` is an agentic-loop diagnostic ("a retry notice", "TooManyRetries"), not a turn, and it already cleared the flag before this change.
            bus.emit(
                ChatStreamEvent.Failed("The agent hit TooManyRetries and gave up."),
            )
            schedulers.drain()

            assertFalse(model.uiState.value.isStreaming)
            assertEquals("The agent hit TooManyRetries and gave up.", model.uiState.value.errorMessage)
            assertNoRowClaimsToStream(model)
        }

    @Test
    fun `a reconnecting stream leaves the flag alone`() = streamStateTest { schedulers ->
        val bus = FakeSseBus()
        val model = openStreamingTurn(schedulers, bus)

        // A reconnect is not the end of the run — the refetch it triggers is what may settle it — so this transition must not clear anything.
        bus.state(ChatStreamState.Reconnecting)
        schedulers.drain()

        assertTrue(model.uiState.value.isStreaming)
    }
}
