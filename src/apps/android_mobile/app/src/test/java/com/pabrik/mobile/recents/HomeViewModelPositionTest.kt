package com.pabrik.mobile.recents

import com.pabrik.mobile.testing.InMemoryProjectsCache
import com.pabrik.mobile.projects.KanbanClient
import com.pabrik.mobile.projects.ProjectsClient
import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.testing.InMemoryLastPositionStore
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The last position, at the ViewModel level: the workspace a relaunch seeds itself from, and the writes a user's own taps leave behind. */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelPositionTest {

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

        /** Runs exactly far enough for the workspace list to have landed and been applied, with the *chat* fetch for the selected workspace queued on IO and not yet run. */
        fun advanceToChatFetchPending() {
            main.advanceUntilIdle() // runs `onUserChanged`, queues the workspace fetch
            io.advanceUntilIdle()   // the workspace response is in, continuation on main
            main.advanceUntilIdle() // applied; the chat fetch is now queued on IO
        }
    }

    private fun positionTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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
        var workspaces: String = TWO_WORKSPACES,
        var chatsByWorkspace: Map<String, String> = emptyMap(),
        var offline: Boolean = false,
    ) : AuthTransport {
        override fun post(path: String, body: String, headers: Map<String, String>) =
            error("read-only")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            val body = if (path.startsWith(RecentsApi.WORKSPACES_PATH)) {
                workspaces
            } else {
                chatsByWorkspace[path.substringAfter("workspace_id=")]
                    ?: EMPTY_CHATS
            }
            return AuthHttpResponse(statusCode = 200, body = body)
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        positionStore: LastPositionStore,
        transport: AuthTransport = FakeTransport(),
        cache: RecentsCache = InMemoryRecentsCache(),
    ) = HomeViewModel(
        client = RecentsClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        // The projects section has no say in these tests, so it gets a client that answers nothing and a cache that answers nothing — which is what keeps an unrelated …
        projectsClient = ProjectsClient(MemorySessionStore()),
        projectsCache = InMemoryProjectsCache(),
        kanbanClient = KanbanClient(MemorySessionStore()),
        positionStore = positionStore,
        ioDispatcher = ioDispatcher,
    )

    @Test
    fun `the saved workspace is painted from cache before any fetch`() = positionTest { s ->
        val cache = InMemoryRecentsCache()
        cache.writeWorkspaces("user_a", listOf(WorkspaceOption("ws_a", "One"), WorkspaceOption("ws_b", "Two")))
        cache.writeChats("user_a", "ws_b", listOf(chat("ws_b", "sess_c")))

        val model = model(
            ioDispatcher = s.ioDispatcher,
            positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c")),
            cache = cache,
        )
        model.onUserChanged("user_a")

        // Undrained: this is the first frame.
        val state = model.uiState.value
        assertEquals("ws_b", state.selectedWorkspaceId)
        assertEquals(listOf("sess_c"), state.chats.map { it.id })
    }

    @Test
    fun `with no cache the saved workspace still wins the first fetch`() = positionTest { s ->
        val model = model(
            ioDispatcher = s.ioDispatcher,
            positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c")),
        )
        model.onUserChanged("user_a")
        s.drain()

        assertEquals("ws_b", model.uiState.value.selectedWorkspaceId)
    }

    @Test
    fun `a saved workspace the server no longer has falls back to the first`() = positionTest { s ->
        val model = model(
            ioDispatcher = s.ioDispatcher,
            positionStore = store(user = "user_a", position = LastPosition("ws_deleted", "sess_c")),
        )
        model.onUserChanged("user_a")
        s.drain()

        // Not an error and not an empty drawer: the list is the truth about which workspaces exist, and the stale id simply loses.
        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)
        assertEquals(null, model.uiState.value.errorMessage)
    }

    @Test
    fun `a spent seed does not come back on a later refresh`() = positionTest { s ->
        val transport = FakeTransport(workspaces = """{"workspaces":[{"id":"ws_a","name":"One"}]}""")
        val model = model(
            ioDispatcher = s.ioDispatcher,
            positionStore = store(user = "user_a", position = LastPosition("ws_deleted", "sess_c")),
            transport = transport,
        )
        model.onUserChanged("user_a")
        s.drain()

        // The user moves on; ws_b comes back on the server later in the session.
        transport.workspaces = TWO_WORKSPACES
        model.refresh()
        s.drain()
        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)

        // And again, after the user deliberately selected ws_a: the seed has to stay spent, or a workspace the user left behind keeps winning.
        model.selectWorkspace("ws_b")
        model.selectWorkspace("ws_a")
        s.drain()
        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)
    }

    @Test
    fun `a tap persists the position the user moved to`() = positionTest { s ->
        val positionStore = store(user = "user_a")
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        model.selectWorkspace("ws_b")
        model.selectChat("sess_c")

        assertEquals(LastPosition("ws_b", "sess_c"), positionStore.read("user_a"))
    }

    @Test
    fun `switching workspace forgets the chat from the one being left`() = positionTest { s ->
        val positionStore = store(user = "user_a")
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        model.selectWorkspace("ws_b")
        model.selectChat("sess_c")
        model.selectWorkspace("ws_a")

        // Resuming sess_c here would open a chat that is not in ws_a's list.
        assertEquals(LastPosition("ws_a", null), positionStore.read("user_a"))
    }

    @Test
    fun `a tap writes the workspace the drawer is actually on`() = positionTest { s ->
        // The store's workspace and the drawer's can disagree — a saved id the server no longer has is exactly how — and the chat a tap persists has to be filed under …
        val positionStore = store(user = "user_a", position = LastPosition("ws_deleted", "sess_old"))
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()
        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)

        model.selectChat("sess_c")

        assertEquals(LastPosition("ws_a", "sess_c"), positionStore.read("user_a"))
    }

    @Test
    fun `re-tapping the workspace already selected is not a position change`() = positionTest { s ->
        val positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c"))
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        // The drawer opens on ws_b, so this is the row the user is on.
        model.selectWorkspace("ws_b")

        assertEquals(LastPosition("ws_b", "sess_c"), positionStore.read("user_a"))
    }

    @Test
    fun `a blank chat is not a position`() = positionTest { s ->
        val positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c"))
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        model.selectChat("")

        assertEquals(LastPosition("ws_b", "sess_c"), positionStore.read("user_a"))
    }

    @Test
    fun `the position is read once per launch, not on every refresh`() = positionTest { s ->
        val positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c"))
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        // The user moves to ws_a, and a background revalidate runs.
        model.selectWorkspace("ws_a")
        s.drain()
        model.refresh()
        s.drain()

        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)
    }

    @Test
    fun `sign-out takes the position with the rows`() = positionTest { s ->
        val positionStore = store(user = "user_a", position = LastPosition("ws_b", "sess_c"))
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)
        model.onUserChanged("user_a")
        s.drain()

        model.onSignedOut()

        // The next account to sign in on this device would otherwise open straight into the previous one's transcript.
        assertTrue("sign-out must purge the position", positionStore.cleared)
        assertTrue(positionStore.read("user_a").isEmpty)
        assertTrue(model.uiState.value.workspaces.isEmpty())
    }

    @Test
    fun `an account's seed is that account's, not the last one's`() = positionTest { s ->
        val positionStore = InMemoryLastPositionStore().apply {
            save("user_a", LastPosition("ws_b", "sess_c"))
            save("user_b", LastPosition("ws_a", "sess_a"))
        }
        val model = model(ioDispatcher = s.ioDispatcher, positionStore = positionStore)

        model.onUserChanged("user_b")
        s.drain()
        assertEquals("ws_a", model.uiState.value.selectedWorkspaceId)

        // And A gets A's back, not the workspace the drawer happened to be on.
        model.onUserChanged("user_a")
        s.drain()
        assertEquals("ws_b", model.uiState.value.selectedWorkspaceId)
    }

    @Test
    fun `the chat list arrives after the app has already settled`() = positionTest { s ->
        // The timing the resume depends on, asserted where it comes from.
        val model = model(
            ioDispatcher = s.ioDispatcher,
            positionStore = store("user_a", LastPosition("ws_b", "sess_c")),
            transport = FakeTransport(
                chatsByWorkspace = mapOf(
                    "ws_b" to """{"sessions":[{"session_id":"sess_c","session_name":"C"}],"total":1}""",
                ),
            ),
        )
        model.onUserChanged("user_a")

        s.advanceToChatFetchPending()
        val between = model.uiState.value
        assertEquals("ws_b", between.selectedWorkspaceId)
        assertEquals(false, between.isLoading)
        assertTrue("precondition: the chat list has not arrived", between.chats.isEmpty())

        s.drain()
        assertEquals(listOf("sess_c"), model.uiState.value.chats.map { it.id })
    }

    @Test
    fun `the current selection outranks the seed`() = positionTest { s ->
        // The precedence in one assertion, because it is the rule two call sites share: a workspace the user is looking at is never moved out from under them by a value …
        assertEquals(
            "ws_a",
            selectWorkspaceId(
                workspaces = listOf(WorkspaceOption("ws_a", "One"), WorkspaceOption("ws_b", "Two")),
                currentSelection = "ws_a",
                resumeSeed = "ws_b",
            ),
        )
        assertEquals(
            "ws_b",
            selectWorkspaceId(
                workspaces = listOf(WorkspaceOption("ws_a", "One"), WorkspaceOption("ws_b", "Two")),
                currentSelection = null,
                resumeSeed = "ws_b",
            ),
        )
        assertEquals(
            "ws_a",
            selectWorkspaceId(
                workspaces = listOf(WorkspaceOption("ws_a", "One"), WorkspaceOption("ws_b", "Two")),
                currentSelection = "ws_gone",
                resumeSeed = "ws_gone_too",
            ),
        )
        assertNull(
            selectWorkspaceId(
                workspaces = emptyList(),
                currentSelection = null,
                resumeSeed = "ws_b",
            ),
        )
    }

    private fun store(user: String, position: LastPosition = LastPosition()) =
        InMemoryLastPositionStore(seedUserId = user, initial = position)

    private fun chat(workspaceId: String, id: String) =
        ChatSummary(id, workspaceId, "Chat $id", 1_000L)

    private companion object {
        const val TWO_WORKSPACES =
            """{"workspaces":[{"id":"ws_a","name":"One"},{"id":"ws_b","name":"Two"}]}"""
        const val EMPTY_CHATS = """{"sessions":[],"total":0,"has_more":false,"next_cursor":null}"""
    }
}
