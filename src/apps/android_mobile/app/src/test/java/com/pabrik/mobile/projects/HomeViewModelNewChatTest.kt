package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.HomeViewModel
import com.pabrik.mobile.recents.HomeViewModel.Companion.DEFAULT_PROJECT_ERROR_MESSAGE
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.testing.InMemoryLastPositionStore
import com.pabrik.mobile.testing.InMemoryProjectsCache
import com.pabrik.mobile.testing.InMemoryRecentsCache
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** `HomeViewModel.newChat()` — the drawer's top-level "New Chat". */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelNewChatTest {

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

    private fun newChatTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val s = Schedulers()
        Dispatchers.setMain(s.mainDispatcher)
        try {
            body(s)
        } finally {
            Dispatchers.resetMain()
        }
    }

    /** Answers the reads the ViewModel makes on launch, and records every POST so a test can assert the exact *number* of creates — a "no network on the happy path" … */
    private class NewChatTransport(
        private val itemsBody: String,
        private val defaultProjectStatus: Int = 201,
    ) : AuthTransport {
        val posts = mutableListOf<String>()
        var defaultProjectBodies: MutableList<String> = mutableListOf()

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            posts += path
            if (path.endsWith("/default-project")) {
                defaultProjectBodies += body
                return AuthHttpResponse(
                    defaultProjectStatus,
                    """{"item":{"id":"item_default","workspace_id":"ws_1","item_type":"agent",""" +
                        """"name":"Project Default","path":"/home/tester","is_default":1},"created":true}""",
                )
            }
            return AuthHttpResponse(
                200,
                """{"id":"task_9","name":"New Chat","task_type":"standard",""" +
                    """"updated_at":"2026-09-27 05:12:40"}""",
            )
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse = when {
            path.startsWith("/api/workspaces/") && path.endsWith("/items") ->
                AuthHttpResponse(200, itemsBody)

            path.contains("/items/") && path.contains("/tasks") -> AuthHttpResponse(
                200,
                """{"tasks":[],"count":0,"has_more":false,"next_cursor":null}""",
            )

            path.startsWith("/api/session") -> AuthHttpResponse(
                200,
                """{"sessions":[],"has_more":false,"next_cursor":null,"total":0}""",
            )

            else -> AuthHttpResponse(200, """{"workspaces":[{"id":"ws_1","name":"Kabelweb"}]}""")
        }
    }

    private class StubSessionStore : SessionStore {
        override fun read(): String? = "tok"
        override fun save(cookieValue: String) = Unit
        override fun clear() = Unit
    }

    private fun viewModel(
        ioDispatcher: CoroutineDispatcher,
        transport: AuthTransport,
    ): HomeViewModel = HomeViewModel(
        client = com.pabrik.mobile.recents.RecentsClient(StubSessionStore(), httpTransport = transport),
        cache = InMemoryRecentsCache(),
        projectsClient = ProjectsClient(StubSessionStore(), httpTransport = transport),
        projectsCache = InMemoryProjectsCache(),
        kanbanClient = KanbanClient(StubSessionStore()),
        positionStore = InMemoryLastPositionStore() as LastPositionStore,
        ioDispatcher = ioDispatcher,
    )

    private fun itemsWithDefault() = """
        {"items":[
          {"id":"item_default","workspace_id":"ws_1","item_type":"agent",
           "name":"Project Default","path":"/home/tester","is_default":1},
          {"id":"item_a","workspace_id":"ws_1","item_type":"agent","name":"Helper",
           "path":"/tmp/a","is_default":0}
        ],"count":2}
    """.trimIndent()

    private fun itemsWithoutDefault() = """
        {"items":[
          {"id":"item_a","workspace_id":"ws_1","item_type":"agent","name":"Helper",
           "path":"/tmp/a","is_default":0}
        ],"count":1}
    """.trimIndent()

    private fun HomeViewModel.taskCreatePostCount(transport: NewChatTransport) =
        transport.posts.count { it.endsWith("/tasks") }

    // ── 1. the happy path makes no network call ─────────────────────────

    @Test
    fun theDefaultIsFoundLocallyAndCostsNoRequest() = newChatTest { s ->
        val transport = NewChatTransport(itemsWithDefault())
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        model.newChat()
        s.drain()

        // The one POST that must exist: the chat create, under the DEFAULT project.
        assertEquals(0, transport.posts.count { it.endsWith("/default-project") })
        assertEquals(1, model.taskCreatePostCount(transport))
        assertTrue(
            transport.posts.any { it == "/api/workspaces/ws_1/items/item_default/tasks" },
        )
    }

    // ── 2. the cold path asks the server once ───────────────────────────

    @Test
    fun aListWithoutADefaultAsksTheServerThenCreatesTheChat() = newChatTest { s ->
        val transport = NewChatTransport(itemsWithoutDefault())
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        model.newChat()
        s.drain()

        assertEquals(1, transport.posts.count { it.endsWith("/default-project") })
        // The chat still lands in the DEFAULT project the endpoint returned — not in the ordinary project that was the only one in the list.
        assertTrue(
            transport.posts.any { it == "/api/workspaces/ws_1/items/item_default/tasks" },
        )
    }

    @Test
    fun theDefaultProjectRequestSendsNoBody() = newChatTest { s ->
        val transport = NewChatTransport(itemsWithoutDefault())
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        model.newChat()
        s.drain()

        // The endpoint is a command ("give me the default"); a body would tempt a name/path override the invariant forbids.
        assertEquals(1, transport.defaultProjectBodies.size)
        assertEquals("", transport.defaultProjectBodies.single())
    }

    // ── 3. a failure neither navigates nor invents a project ─────────────

    @Test
    fun aFailedDefaultProjectRequestCreatesNoChatAndSaysWhy() = newChatTest { s ->
        val transport = NewChatTransport(
            itemsBody = itemsWithoutDefault(),
            defaultProjectStatus = 500,
        )
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        model.newChat()
        s.drain()

        // The create must not have been attempted with a bogus project id.
        assertEquals(0, model.taskCreatePostCount(transport))
        assertEquals(
            DEFAULT_PROJECT_ERROR_MESSAGE,
            model.uiState.value.taskCreateError,
        )
    }

    @Test
    fun aDoubleTapCreatesOneChat() = newChatTest { s ->
        val transport = NewChatTransport(itemsWithDefault())
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        model.newChat()
        model.newChat()
        s.drain()

        // One create at a time.
        assertEquals(1, model.taskCreatePostCount(transport))
    }

    @Test
    fun aCreatedChatIsEmittedForTheGraphToNavigateTo() = newChatTest { s ->
        val transport = NewChatTransport(itemsWithDefault())
        val model = viewModel(s.ioDispatcher, transport)
        // The initial load.
        model.onUserChanged("user_a")
        s.drain()

        val emitted = mutableListOf<String>()
        val collector = CoroutineScope(s.ioDispatcher).launch {
            model.createdChat.collect { emitted += it }
        }
        s.drain()

        model.newChat()
        s.drain()

        // The graph navigates off this flow.
        assertEquals(listOf("task_9"), emitted)
        collector.cancel()
    }
}
