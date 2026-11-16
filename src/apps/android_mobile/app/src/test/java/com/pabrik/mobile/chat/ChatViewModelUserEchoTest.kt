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
import org.junit.Assert.assertTrue
import org.junit.Test

// Regression: the reader's OWN turn, echoed back by the server, has to land at the BOTTOM of the transcript.
private val TWO_TURN_TRANSCRIPT = """
    {"messages":[
      {"id":"900","role":"user","content":"hello there","created_at":"1789450000000000000"},
      {"id":"901","role":"assistant","content":"hi","created_at":"1789450001000000000"}
    ],"has_more":false,"next_cursor":null,"total":2}
""".trimIndent()

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelUserEchoTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(40) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }
    }

    private fun echoTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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

    /** A transcript that already has one answered turn in it, because "the user bubble is last" is only a meaningful claim when there is something older for it to be … */
    private class FakeTransport(
        var messagesBody: String = TWO_TURN_TRANSCRIPT,
        var offline: Boolean = false,
    ) : AuthTransport {
        var sendCount = 0
            private set

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            sendCount++
            return AuthHttpResponse(statusCode = 201, body = """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            return when {
                path.endsWith("/queue_messages") ->
                    AuthHttpResponse(statusCode = 200, body = """{"messages":[],"count":0}""")

                path.endsWith("/stream") -> AuthHttpResponse(
                    statusCode = 200,
                    body = """{"active":false,"content":""}""",
                )

                else -> AuthHttpResponse(
                    statusCode = 200,
                    body = messagesBody,
                )
            }
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        cache: ChatCache,
        bus: FakeSseBus,
        transport: AuthTransport,
        clock: () -> Long,
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = clock,
    ).also { it.onUserChanged("user_a") }

    /** Feeds raw SSE wire text through the real line parser and the real frame decoder, then hands the event to the bus exactly as the socket does. */
    private fun FakeSseBus.replay(wire: String) {
        val parser = SseFrameParser()
        for (line in wire.split("\n")) {
            val frame = parser.accept(line.trimEnd('\r')) ?: continue
            decodeChatFrame(frame)?.let { emit(it) }
        }
    }

    // ── the wire ────────────────────────────────────────────────────────────

    /** `queue_queued` — emitted by `insert_queue_message.zig:47-80` on EVERY send, idle session included (`workflow.zig:727-743`): the turn only starts after the … */
    private val QUEUE_QUEUED_WIRE = """
event: queue_queued
data: {
data:     "action": "queued",
data:     "id": "1789451234500000000",
data:     "message": "and open a PR",
data:     "session_id": "sess_1",
data:     "image_url": ""
data: }

""".trimIndent() + "\n"

    /** `queue_deleted` — `delete_queue_worker.zig:31-66`, fired right after the drain. */
    private val QUEUE_DELETED_WIRE = """
event: queue_deleted
data: {
data:     "action": "deleted",
data:     "id": "1789451234500000000",
data:     "session_id": "sess_1"
data: }

""".trimIndent() + "\n"

    /** `llm_full` with `role: "user"` — the drain writing the reader's turn to `llm_history` with `is_emit_sse = true` (`workflow.zig:997-1024`). */
    private val USER_ECHO_WIRE = """
event: llm_full
data: {
data:     "id": "1789451234567890200",
data:     "type": "full",
data:     "session_id": "sess_1",
data:     "role": "user",
data:     "content": "and open a PR",
data:     "model": "anthropic",
data:     "cwd": "/tmp/p",
data:     "finish_reason": "null",
data:     "loop_index": 0,
data:     "temperature": 0.7,
data:     "is_thinking": false,
data:     "is_input": true,
data:     "is_output": false,
data:     "is_error": false
data: }

""".trimIndent() + "\n"

    /** The assistant's answer to the turn above — same missing `created_at`. */
    private val ASSISTANT_ECHO_WIRE = """
event: llm_full
data: {
data:     "id": "1789451234999999999",
data:     "type": "full",
data:     "session_id": "sess_1",
data:     "role": "assistant",
data:     "content": "Opened it.",
data:     "model": "anthropic",
data:     "cwd": "/tmp/p",
data:     "finish_reason": "null",
data:     "loop_index": 0,
data:     "temperature": 0.7,
data:     "is_thinking": false,
data:     "is_input": false,
data:     "is_output": true,
data:     "is_error": false
data: }

""".trimIndent() + "\n"

    /** A `created_at` the server DID send — the only shape in which one arrives, because nothing in `SseEventLLMHistory` produces it today. */
    private val SERVER_STAMPED_ECHO_WIRE = """
event: llm_full
data: {
data:     "id": "800",
data:     "type": "full",
data:     "session_id": "sess_1",
data:     "role": "user",
data:     "content": "an earlier turn",
data:     "created_at": "1789449000000000000",
data:     "is_error": false
data: }

""".trimIndent() + "\n"

    // ── the tests ───────────────────────────────────────────────────────────

    /** The reported symptom, end to end: send into an EXISTING chat, let the server's own echo of the reader's turn land, and the transcript must read in the order … */
    @Test
    fun `the sent message is not received as the last turn`() = echoTest { schedulers ->
        val cache = InMemoryChatCache()
        val bus = FakeSseBus()
        val transport = FakeTransport()
        val viewModel = model(schedulers.ioDispatcher, cache, bus, transport) { FIXED_MILLIS }

        viewModel.openSession("sess_1")
        schedulers.drain()

        viewModel.onDraftChanged("and open a PR")
        viewModel.sendMessage()
        schedulers.drain()
        assertEquals("the POST must actually have gone out", 1, transport.sendCount)

        // The turn the reader just sent is queued first — every send is, whether or not a worker was already live.
        bus.replay(QUEUE_QUEUED_WIRE)
        schedulers.drain()
        assertEquals(
            "the waiting turn must be visible as this reader's own, not just a count",
            listOf("and open a PR"),
            viewModel.uiState.value.queuedMessages.map { it.message },
        )

        // Then the drain writes the real row and echoes it.
        bus.replay(USER_ECHO_WIRE)
        schedulers.drain()

        assertEquals(
            "the reader's own turn must be decoded, not dropped as unparseable",
            "and open a PR",
            viewModel.uiState.value.messages.lastOrNull()?.content,
        )
        assertEquals(
            "the reader's own turn must be in the transcript at all",
            true,
            viewModel.uiState.value.messages.any { it.role == ChatMessage.ROLE_USER },
        )

        // And the agent answers it.
        bus.replay(QUEUE_DELETED_WIRE)
        bus.replay(ASSISTANT_ECHO_WIRE)
        schedulers.drain()

        assertEquals(
            "two echoed turns and two answered ones, in the order they happened",
            listOf(
                "hello there" to ChatMessage.ROLE_USER,
                "hi" to ChatMessage.ROLE_ASSISTANT,
                "and open a PR" to ChatMessage.ROLE_USER,
                "Opened it." to ChatMessage.ROLE_ASSISTANT,
            ),
            viewModel.uiState.value.messages.map { it.content to it.role },
        )
    }

    /** The ordering must survive the process. */
    @Test
    fun `a cold start still reads the sent message in the right place`() = echoTest { schedulers ->
        val cache = InMemoryChatCache()
        val bus = FakeSseBus()
        val viewModel = model(
            schedulers.ioDispatcher,
            cache,
            bus,
            FakeTransport(),
        ) { FIXED_MILLIS }

        viewModel.openSession("sess_1")
        schedulers.drain()
        bus.replay(QUEUE_QUEUED_WIRE)
        bus.replay(USER_ECHO_WIRE)
        schedulers.drain()

        // A brand new ViewModel over the same cache, with the socket offline, so the paint can only come from disk.
        val offline = FakeTransport(offline = true)
        val restarted = model(
            schedulers.ioDispatcher,
            cache,
            FakeSseBus(),
            offline,
        ) { FIXED_MILLIS }
        restarted.openSession("sess_1")
        schedulers.drain()

        assertEquals(
            "the persisted transcript must read oldest-first, sent message last",
            listOf("hello there", "hi", "and open a PR"),
            restarted.uiState.value.messages.map { it.content },
        )
        assertTrue(
            "a row persisted with no usable timestamp re-sorts itself to the top " +
                "of the transcript on every cold start",
            restarted.uiState.value.messages.all { it.sortKeyNanos > 0L },
        )
    }

    /** The other half of the rule: a row that *does* carry a server timestamp keeps it. */
    @Test
    fun `a wire timestamp is never overwritten by the local clock`() = echoTest { schedulers ->
        val bus = FakeSseBus()
        val viewModel = model(
            schedulers.ioDispatcher,
            InMemoryChatCache(),
            bus,
            FakeTransport(),
        ) { FIXED_MILLIS }

        viewModel.openSession("sess_1")
        schedulers.drain()

        bus.replay(SERVER_STAMPED_ECHO_WIRE)
        schedulers.drain()

        val row = viewModel.uiState.value.messages.last()
        assertEquals("an earlier turn", row.content)
        assertEquals(
            "the server's own nanosecond timestamp is the authority",
            1_789_449_000_000_000_000L,
            row.sortKeyNanos,
        )
        assertEquals(
            "a server-stamped row must not be re-dated onto this phone's clock",
            1_789_449_000_000L,
            row.createdAtEpochMillis,
        )
    }

    private companion object {
        /** A fixed clock, so the assertions are about ORDER rather than about how fast the machine the test runs on happens to be. */
        const val FIXED_MILLIS = 1_789_451_300_000L
    }
}
