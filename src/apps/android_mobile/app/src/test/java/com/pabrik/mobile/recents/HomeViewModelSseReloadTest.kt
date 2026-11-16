package com.pabrik.mobile.recents

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState
import com.pabrik.mobile.projects.KanbanClient
import com.pabrik.mobile.projects.ProjectsClient
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.testing.FakeSseBus
import com.pabrik.mobile.testing.InMemoryLastPositionStore
import com.pabrik.mobile.testing.InMemoryProjectsCache
import com.pabrik.mobile.testing.InMemoryRecentsCache
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

/** The drawer has to be *live*, and the specific thing it was not. */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelSseReloadTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(20) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }
    }

    private class MemorySessionStore(var value: String? = "tok") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    /** Serves whatever [servedChatIds] currently holds, so a test can move the server's truth forward and then assert the drawer followed. */
    private class MutableTransport : AuthTransport {
        var servedChatIds: List<String> = emptyList()
        var chatsRequests = 0

        override fun post(path: String, body: String, headers: Map<String, String>) =
            error("read-only")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (path.startsWith(RecentsApi.WORKSPACES_PATH)) {
                return AuthHttpResponse(
                    200,
                    """{"workspaces":[{"id":"ws_1","name":"One"}]}""",
                )
            }
            chatsRequests++
            val rows = servedChatIds.joinToString(",") { id ->
                """{"session_id":"$id","session_name":"Chat $id",""" +
                    """"updated_at":"2026-09-26 05:12:37"}"""
            }
            return AuthHttpResponse(
                200,
                """{"sessions":[$rows],"total":${servedChatIds.size},""" +
                    """"has_more":false,"next_cursor":null}""",
            )
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        transport: MutableTransport,
        bus: FakeSseBus?,
        cache: RecentsCache = InMemoryRecentsCache(),
        positionStore: LastPositionStore = InMemoryLastPositionStore(),
    ) = HomeViewModel(
        client = RecentsClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        projectsClient = ProjectsClient(MemorySessionStore()),
        projectsCache = InMemoryProjectsCache(),
        kanbanClient = KanbanClient(MemorySessionStore()),
        positionStore = positionStore,
        ioDispatcher = ioDispatcher,
        bus = bus,
    )

    private fun sseTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    // ── The reported bug ────────────────────────────────────────────────

    @Test
    fun aChatCreatedElsewhereJoinsTheList() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        assertEquals(listOf("c1"), model.uiState.value.chats.map { it.id })
        val requestsAfterFirstLoad = transport.chatsRequests

        // What the webview does while this phone is looking at its drawer: a second agent session starts.
        transport.servedChatIds = listOf("c2", "c1")
        bus.emit(
            ChatStreamEvent.SessionChanged(
                sessionId = "c2",
                action = "created",
                name = "Chat c2",
            ),
        )
        s.drain()

        assertEquals(listOf("c2", "c1"), model.uiState.value.chats.map { it.id })
        assertTrue(
            "the event must have cost one reload, not zero",
            transport.chatsRequests > requestsAfterFirstLoad,
        )
    }

    @Test
    fun aRunStartingOnAnExistingChatAlsoReloads() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1", "c2") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        val before = transport.chatsRequests

        // `worker_created` rather than `session_created`: no new session, but the run touches it and the list is ordered by `updated_at`, so the row the reader is about …
        bus.emit(
            ChatStreamEvent.WorkerChanged(
                sessionId = "c1",
                action = ChatStreamEvent.WorkerChanged.ACTION_CREATED,
            ),
        )
        s.drain()

        assertTrue(transport.chatsRequests > before)
    }

    // ── What must NOT reload ───────────────────────────────────────────

    @Test
    fun aHeartbeatDoesNotReload() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        val before = transport.chatsRequests

        // The backend emits `worker_updated` on every activity-description change — several times a minute for a live worker.
        repeat(5) {
            bus.emit(
                ChatStreamEvent.WorkerChanged(
                    sessionId = "c1",
                    action = ChatStreamEvent.WorkerChanged.ACTION_UPDATED,
                ),
            )
        }
        s.drain()

        assertEquals(before, transport.chatsRequests)
    }

    @Test
    fun nothingReloadsBeforeSignIn() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1") }
        val bus = FakeSseBus()
        // Built but never handed a user, which is the state between the Activity being created and the cookie being read back.
        val model = model(s.ioDispatcher, transport, bus)

        bus.emit(
            ChatStreamEvent.SessionChanged(sessionId = "c2", action = "created", name = "n"),
        )
        s.drain()

        assertEquals(0, transport.chatsRequests)
        assertTrue(model.uiState.value.chats.isEmpty())
    }

    // ── Shape of the reload ────────────────────────────────────────────

    @Test
    fun aBurstOfEventsCostsOneReload() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        val before = transport.chatsRequests

        // Exactly the sequence one "create a chat and start it" produces
        bus.emit(ChatStreamEvent.SessionChanged("c2", "created", "n"))
        bus.emit(
            ChatStreamEvent.WorkerChanged(
                "c2",
                ChatStreamEvent.WorkerChanged.ACTION_CREATED,
            ),
        )
        bus.emit(ChatStreamEvent.SessionChanged("c2", "updated", "Chat c2"))
        s.drain()

        assertEquals(before + 1, transport.chatsRequests)
    }

    @Test
    fun reconnectingReloads() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        val before = transport.chatsRequests

        // The socket keeps no replay buffer, so a run that started while it was down left no frame to apply and no second event is coming.
        transport.servedChatIds = listOf("c3", "c1")
        bus.state(ChatStreamState.Live)
        s.drain()

        assertEquals(listOf("c3", "c1"), model.uiState.value.chats.map { it.id })
        assertTrue(transport.chatsRequests > before)
    }

    @Test
    fun aDeletedChatLeavesAtOnce() = sseTest { s ->
        val transport = MutableTransport().apply { servedChatIds = listOf("c1", "c2") }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, transport, bus)

        model.onUserChanged("user_a")
        s.drain()
        assertEquals(listOf("c1", "c2"), model.uiState.value.chats.map { it.id })

        // Asserted with NO scheduler advance, and with the transport still serving `c2`: a delete must not wait for the debounced reload, or for the next 400 ms the row …
        bus.emit(
            ChatStreamEvent.SessionChanged(
                sessionId = "c2",
                action = HomeViewModel.ACTION_SESSION_DELETED,
                name = "",
            ),
        )

        assertEquals(listOf("c1"), model.uiState.value.chats.map { it.id })
    }
}
