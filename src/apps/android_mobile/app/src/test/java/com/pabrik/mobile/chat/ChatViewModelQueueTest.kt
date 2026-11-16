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

// The queue at the ViewModel level: the read that bootstraps it, the two frames that keep it live, and the one that repairs it.
private fun queuePage(vararg rows: Pair<String, String>): String {
    val encoded = rows.joinToString(",") { (id, text) -> """{"id":"$id","message":"$text"}""" }
    return """{"messages":[$encoded],"count":${rows.size}}"""
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelQueueTest {

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

    private fun queueTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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

    /** The queue answer is a per-path field rather than a fixed body, because every test here is about a *different* server state and a fake that returns the same … */
    private class FakeTransport(
        var queueBody: String = queuePage(),
        var queueStatus: Int = 200,
        var offline: Boolean = false,
    ) : AuthTransport {
        val requestedPaths = mutableListOf<String>()
        val sentBodies = mutableListOf<String>()

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "POST $path"
            sentBodies += body
            return AuthHttpResponse(statusCode = 201, body = """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "GET $path"
            return when {
                path.endsWith("/queue_messages") ->
                    AuthHttpResponse(statusCode = queueStatus, body = queueBody)

                path.endsWith("/stream") -> AuthHttpResponse(
                    statusCode = 200,
                    body = """{"active":false,"content":""}""",
                )

                else -> AuthHttpResponse(
                    statusCode = 200,
                    body = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
                )
            }
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        transport: AuthTransport = FakeTransport(),
        bus: FakeSseBus = FakeSseBus(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = bus,
        ioDispatcher = ioDispatcher,
    ).also { it.onUserChanged("user_a") }

    private fun queueRequestCount(transport: AuthTransport): Int =
        (transport as FakeTransport).requestedPaths.count { it.endsWith("/queue_messages") }

    // --- The bootstrap read ------------------------------------------------

    @Test
    fun openingAChatReadsTheQueue() = queueTest { schedulers ->
        val transport = FakeTransport(
            queueBody = queuePage("q1" to "then run the tests", "q2" to "and open a PR"),
        )
        val model = model(schedulers.ioDispatcher, transport)

        model.openSession("sess_1")
        schedulers.drain()

        assertEquals(1, queueRequestCount(transport))
        assertEquals(listOf("q1", "q2"), model.uiState.value.queuedMessages.map { it.id })
        assertEquals("and open a PR", model.uiState.value.queuedMessages[1].message)
    }

    @Test
    fun aTurnQueuedWhileTheAppWasClosedIsStillThere() = queueTest { schedulers ->
        // The case the read exists for: no `queue_queued` frame was ever delivered to this process, so without the read the panel is empty and a message the reader sent …
        val transport = FakeTransport(queueBody = queuePage("q1" to "queued from the desktop"))
        val model = model(schedulers.ioDispatcher, transport)

        model.openSession("sess_1")
        schedulers.drain()

        assertEquals(1, model.uiState.value.queuedCount)
    }

    @Test
    fun aFailedReadLeavesWhatTheStreamSaidRatherThanBlanking() = queueTest { schedulers ->
        val transport = FakeTransport()
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, transport, stream)

        model.openSession("sess_1")
        schedulers.drain()
        stream.emit(
            ChatStreamEvent.QueueChanged(
                sessionId = "sess_1",
                action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
                id = "q_live",
                message = "queued while this screen watched",
            ),
        )

        // Now the read fails.
        transport.queueStatus = 500
        model.refreshQueuedMessages()
        schedulers.drain()

        assertEquals(listOf("q_live"), model.uiState.value.queuedMessages.map { it.id })
    }

    @Test
    fun theReadRepairsAMirrorThatMissedAFrame() = queueTest { schedulers ->
        val transport = FakeTransport()
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, transport, stream)

        model.openSession("sess_1")
        schedulers.drain()

        // A drain while the socket was down: the frame went to nobody, so the mirror still lists a turn the server has already answered.
        transport.queueBody = queuePage()
        model.refreshQueuedMessages()
        schedulers.drain()

        assertTrue(model.uiState.value.queuedMessages.isEmpty())
    }

    @Test
    fun aReconnectRereadsTheQueue() = queueTest { schedulers ->
        val transport = FakeTransport(queueBody = queuePage("q1" to "still waiting"))
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, transport, stream)

        model.openSession("sess_1")
        schedulers.drain()
        val afterOpen = queueRequestCount(transport)

        // First connect, then a reconnect.
        stream.state(ChatStreamState.Live)
        schedulers.drain()
        stream.state(ChatStreamState.Reconnecting)
        stream.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(afterOpen + 1, queueRequestCount(transport))
    }

    // --- The live mirror ---------------------------------------------------

    @Test
    fun aQueuedFrameAppendsTheTurnWithItsText() = queueTest { schedulers ->
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, FakeTransport(), stream)

        model.openSession("sess_1")
        schedulers.drain()
        stream.emit(
            ChatStreamEvent.QueueChanged(
                sessionId = "sess_1",
                action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
                id = "q1",
                message = "then open a PR",
            ),
        )

        assertEquals(1, model.uiState.value.queuedCount)
        assertEquals("then open a PR", model.uiState.value.queuedMessages[0].message)
    }

    @Test
    fun theSameFrameTwiceAppendsOnce() = queueTest { schedulers ->
        // The backend emits on the per-session key *and* on the central `queue` broadcast (`insert_queue_message.zig`), so the identical frame really does arrive twice.
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, FakeTransport(), stream)

        model.openSession("sess_1")
        schedulers.drain()
        val event = ChatStreamEvent.QueueChanged(
            sessionId = "sess_1",
            action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
            id = "q1",
            message = "then open a PR",
        )
        stream.emit(event)
        stream.emit(event)

        assertEquals(1, model.uiState.value.queuedCount)
    }

    @Test
    fun aDrainedFrameRemovesThatTurnAndNotAnother() = queueTest { schedulers ->
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, FakeTransport(), stream)

        model.openSession("sess_1")
        schedulers.drain()
        listOf("q1" to "first", "q2" to "second").forEach { (id, text) ->
            stream.emit(
                ChatStreamEvent.QueueChanged(
                    sessionId = "sess_1",
                    action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
                    id = id,
                    message = text,
                ),
            )
        }
        stream.emit(
            ChatStreamEvent.QueueChanged(
                sessionId = "sess_1",
                action = ChatStreamEvent.QueueChanged.ACTION_DELETED,
                id = "q1",
            ),
        )

        assertEquals(listOf("q2"), model.uiState.value.queuedMessages.map { it.id })
    }

    @Test
    fun anotherChatsQueueFrameIsIgnored() = queueTest { schedulers ->
        // The stream is subscribed to the central `queue` channel, so it carries every account's queueing.
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, FakeTransport(), stream)

        model.openSession("sess_1")
        schedulers.drain()
        stream.emit(
            ChatStreamEvent.QueueChanged(
                sessionId = "sess_other",
                action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
                id = "q_other",
                message = "not this chat",
            ),
        )

        assertTrue(model.uiState.value.queuedMessages.isEmpty())
    }

    // --- Sending behind a run ---------------------------------------------

    @Test
    fun aSendWhileAWorkerIsLiveIsTheSameWireBody() = queueTest { schedulers ->
        // There is no "queue" endpoint and no `mode` field.
        val transport = FakeTransport()
        val model = model(schedulers.ioDispatcher, transport)

        model.openSession("sess_1")
        schedulers.drain()
        model.onDraftChanged("and then open a PR")
        model.sendMessage()
        schedulers.drain()

        val body = org.json.JSONObject(transport.sentBodies.single())
        assertEquals("/api/llm/session", transport.requestedPaths.single { it.startsWith("POST ") }.removePrefix("POST "))
        assertEquals("sess_1", body.getString("session_id"))
        assertEquals("and then open a PR", body.getString("queue_message"))
    }

    @Test
    fun aQueuedTurnIsBroughtBackToTheBoxToEdit() = queueTest { schedulers ->
        val model = model(schedulers.ioDispatcher, FakeTransport())

        model.openSession("sess_1")
        schedulers.drain()
        model.useQueuedMessage(QueuedChatMessage("q1", "  then run the tests  "))

        assertEquals("then run the tests", model.uiState.value.draft)
    }

    // --- Session boundaries ------------------------------------------------

    @Test
    fun switchingChatsDropsThePreviousChatsQueue() = queueTest { schedulers ->
        val transport = FakeTransport()
        val stream = FakeSseBus()
        val model = model(schedulers.ioDispatcher, transport, stream)

        model.openSession("sess_1")
        schedulers.drain()
        stream.emit(
            ChatStreamEvent.QueueChanged(
                sessionId = "sess_1",
                action = ChatStreamEvent.QueueChanged.ACTION_QUEUED,
                id = "q1",
                message = "belongs to the chat being left",
            ),
        )

        transport.queueBody = queuePage()
        model.openSession("sess_2")
        schedulers.drain()

        assertTrue(model.uiState.value.queuedMessages.isEmpty())
    }

    @Test
    fun signingOutDropsTheQueue() = queueTest { schedulers ->
        val transport = FakeTransport(queueBody = queuePage("q1" to "still waiting"))
        val model = model(schedulers.ioDispatcher, transport)

        model.openSession("sess_1")
        schedulers.drain()
        assertEquals(1, model.uiState.value.queuedCount)

        model.onSignedOut()

        assertTrue(model.uiState.value.queuedMessages.isEmpty())
        assertFalse(model.uiState.value.queuedCount > 0)
    }
}
