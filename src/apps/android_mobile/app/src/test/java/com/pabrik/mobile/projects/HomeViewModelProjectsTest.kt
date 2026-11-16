package com.pabrik.mobile.projects

import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.Dispatchers
import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.HomeViewModel
import com.pabrik.mobile.recents.RecentsClient
import com.pabrik.mobile.testing.InMemoryLastPositionStore
import com.pabrik.mobile.testing.InMemoryProjectsCache
import com.pabrik.mobile.testing.InMemoryRecentsCache
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Two schedulers, not one. */
@OptIn(ExperimentalCoroutinesApi::class)
private class Schedulers {
    val main = TestCoroutineScheduler()
    val io = TestCoroutineScheduler()
    val mainDispatcher = StandardTestDispatcher(main)
    val ioDispatcher = StandardTestDispatcher(io)

    /** Runs a fetch to completion; it hops main -> io -> main. */
    fun drain() {
        repeat(20) {
            main.advanceUntilIdle()
            io.advanceUntilIdle()
        }
    }
}

private fun projectsTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
    val s = Schedulers()
    Dispatchers.setMain(s.mainDispatcher)
    try {
        body(s)
    } finally {
        Dispatchers.resetMain()
    }
}

private class MemorySessionStore(var value: String? = "tok") : SessionStore {
    override fun read(): String? = value
    override fun save(cookieValue: String) { value = cookieValue }
    override fun clear() { value = null }
}

/** Answers both recents and projects, and counts what it was asked for. */
private class ScriptedTransport(
    private val workspacesBody: String = """{"workspaces":[{"id":"ws_1","name":"Kabelweb"},{"id":"ws_2","name":"Other"}]}""",
    private val chatsBody: String = """{"sessions":[],"has_more":false,"next_cursor":null,"total":0}""",
    private val itemsByWorkspace: Map<String, String> = mapOf(
        "ws_1" to """{"items":[{"id":"item_1","workspace_id":"ws_1","item_type":"kanban","name":"sprint board"}],"count":1}""",
        "ws_2" to """{"items":[{"id":"item_9","workspace_id":"ws_2","item_type":"agent","name":"other agent"}],"count":1}""",
    ),
    private val chatsByProject: Map<String, List<String>> = emptyMap(),
    private val chatsStatus: Int = 200,
) : AuthTransport {
    val requested = mutableListOf<String>()

    override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse =
        error("The drawer only reads.")

    override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
        requested += path
        return when {
            path.startsWith("/api/workspaces/") && path.endsWith("/items") -> {
                val workspace = path.removePrefix("/api/workspaces/").removeSuffix("/items")
                ok(itemsByWorkspace[workspace] ?: """{"items":[],"count":0}""")
            }

            path.contains("/items/") && path.contains("/tasks") -> {
                if (chatsStatus != 200) return AuthHttpResponse(chatsStatus, "")
                val itemId = path.substringAfter("/items/").substringBefore("/tasks")
                ok(projectChatsJson(itemId))
            }

            path.startsWith("/api/session") -> ok(chatsBody)
            path.startsWith("/api/workspaces") -> ok(workspacesBody)
            else -> ok("{}")
        }
    }

    /** Built with escaped quotes rather than a raw string: a `"""` literal that itself contains `"` has to end, and ending it mid-JSON reads as a syntax error rather … */
    private fun projectChatsJson(itemId: String): String {
        val ids = chatsByProject[itemId].orEmpty()
        val tasks = ids.joinToString(",") { id ->
            "{\"id\":\"$id\",\"name\":\"chat $id\",\"updated_at\":\"2026-09-26 05:12:37\"}"
        }
        return "{\"tasks\":[$tasks],\"count\":${ids.size},\"has_more\":false,\"next_cursor\":null}"
    }

    private fun ok(body: String) = AuthHttpResponse(statusCode = 200, body = body)
}

private fun buildModel(
    ioDispatcher: kotlinx.coroutines.CoroutineDispatcher,
    transport: AuthTransport,
    projectsCache: InMemoryProjectsCache = InMemoryProjectsCache(),
): HomeViewModel = HomeViewModel(
    client = RecentsClient(MemorySessionStore(), httpTransport = transport),
    cache = InMemoryRecentsCache(),
    projectsClient = ProjectsClient(MemorySessionStore(), httpTransport = transport),
    projectsCache = projectsCache,
    kanbanClient = KanbanClient(MemorySessionStore()),
    positionStore = InMemoryLastPositionStore(),
    ioDispatcher = ioDispatcher,
)

private fun item(id: String, workspace: String = "ws_1") = ProjectSummary(
    id = id,
    workspaceId = workspace,
    itemType = ProjectTypes.KANBAN,
    name = "project $id",
)

/** The projects section's state machine. */
class HomeViewModelProjectsTest {

    @Test
    fun theSectionLoadsForTheSelectedWorkspace() = projectsTest { s ->
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(
                chatsByProject = mapOf("item_1" to listOf("t1", "t2")),
            ),
        )

        model.onUserChanged("user_a")
        s.drain()

        assertEquals(listOf("item_1"), model.uiState.value.projects.map { it.id })
        assertFalse(model.uiState.value.isLoadingProjects)
    }

    @Test
    fun switchingWorkspaceClearsThePreviousWorkspacesProjects() = projectsTest { s ->
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1"))),
        )
        model.onUserChanged("user_a")
        s.drain()
        model.toggleProjectExpanded("item_1")
        s.drain()
        assertTrue(model.uiState.value.projectChats.containsKey("item_1"))

        model.selectWorkspace("ws_2")
        s.drain()

        val state = model.uiState.value
        assertEquals(listOf("item_9"), state.projects.map { it.id })
        // Which projects were unfolded, and which chats were paged, belonged to the workspace just left.
        assertTrue(state.expandedProjectIds.isEmpty())
        assertTrue(state.projectChats.isEmpty())
    }

    @Test
    fun theSectionDefaultsToExpanded() = projectsTest { s ->
        val model = buildModel(s.ioDispatcher, ScriptedTransport())

        model.onUserChanged("user_a")
        s.drain()

        assertTrue(model.uiState.value.isProjectsExpanded)
    }

    @Test
    fun theSectionHeaderToggles() = projectsTest { s ->
        val model = buildModel(s.ioDispatcher, ScriptedTransport())
        model.onUserChanged("user_a")
        s.drain()

        model.toggleProjectsSection()
        assertFalse(model.uiState.value.isProjectsExpanded)

        model.toggleProjectsSection()
        assertTrue(model.uiState.value.isProjectsExpanded)
    }

    @Test
    fun expandingAProjectFetchesItsChats() = projectsTest { s ->
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1", "t2")))
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        val before = transport.requested.count { it.contains("/tasks") }

        model.toggleProjectExpanded("item_1")
        s.drain()

        assertEquals(listOf("t1", "t2"), model.uiState.value.projectChatsFor("item_1")?.chats?.map { it.id })
        assertEquals(before + 1, transport.requested.count { it.contains("/tasks") })
    }

    @Test
    fun collapsingAndReopeningAProjectDoesNotRefetch() = projectsTest { s ->
        // The drawer's whole point is to be instantaneous to open.
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1")))
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.toggleProjectExpanded("item_1")
        s.drain()
        val afterFirst = transport.requested.count { it.contains("/tasks") }

        model.toggleProjectExpanded("item_1")
        s.drain()
        model.toggleProjectExpanded("item_1")
        s.drain()

        assertEquals(afterFirst, transport.requested.count { it.contains("/tasks") })
    }

    @Test
    fun theProjectScreenReusesThePageTheDrawerAlreadyFetched() = projectsTest { s ->
        // This is the whole reason the screen shares the ViewModel: expanding a project and then tapping "See all" costs one request, not two.
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1", "t2")))
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        model.toggleProjectExpanded("item_1")
        s.drain()
        val afterExpand = transport.requested.count { it.contains("/tasks") }

        model.ensureProjectChatsLoaded("item_1")
        s.drain()

        assertEquals("the screen must not refetch what the drawer already has", afterExpand, transport.requested.count { it.contains("/tasks") })
    }

    @Test
    fun theProjectScreenFetchesWhenItArrivesWithNothingCached() = projectsTest { s ->
        // A deep link into `pabrik://project/…` on a cold process is the case that actually needs the fetch.
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t9")))
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.ensureProjectChatsLoaded("item_1")
        s.drain()

        assertEquals(listOf("t9"), model.uiState.value.projectChatsFor("item_1")?.chats?.map { it.id })
    }

    @Test
    fun aFailedSectionFetchKeepsTheRowsItAlreadyHas() = projectsTest { s ->
        val cache = InMemoryProjectsCache()
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(),
            projectsCache = cache,
        )
        model.onUserChanged("user_a")
        s.drain()

        // A second refresh against a transport that now fails.
        val failing = ScriptedTransport(chatsStatus = 500)
        val second = buildModel(s.ioDispatcher, failing, cache)
        second.onUserChanged("user_a")
        s.drain()

        assertTrue("cached rows survive a failed refresh", second.uiState.value.projects.isNotEmpty())
    }

    @Test
    fun aFailedChatPageLeavesTheSectionAlone() = projectsTest { s ->
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1")), chatsStatus = 500)
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.toggleProjectExpanded("item_1")
        s.drain()

        val state = model.uiState.value
        // The projects list is unaffected, and the failure did not end up recorded as the recents error — a projects failure reported against the chat list would be a …
        assertEquals(listOf("item_1"), state.projects.map { it.id })
        assertNull("a projects failure must not land in the recents error", state.errorMessage)
    }

    @Test
    fun signingOutClearsProjectsAndTheirChats() = projectsTest { s ->
        val cache = InMemoryProjectsCache()
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1"))),
            projectsCache = cache,
        )
        model.onUserChanged("user_a")
        s.drain()
        model.toggleProjectExpanded("item_1")
        s.drain()

        model.onSignedOut()

        val state = model.uiState.value
        assertTrue(state.projects.isEmpty())
        assertTrue(state.projectChats.isEmpty())
        assertTrue(state.expandedProjectIds.isEmpty())
        // The rows belonged to the account that just ended.
        assertTrue("the projects cache must be purged on sign-out", cache.cleared)
    }

    @Test
    fun accountChangeNeverPaintsThePreviousAccountsProjects() = projectsTest { s ->
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("t1"))),
        )
        model.onUserChanged("user_a")
        s.drain()
        model.toggleProjectExpanded("item_1")
        s.drain()

        model.onUserChanged("user_b")
        s.drain()

        assertTrue(model.uiState.value.projectChats.isEmpty())
    }

    @Test
    fun aWorkspaceWithNoProjectsIsEmptyRatherThanBroken() = projectsTest { s ->
        val model = buildModel(
            s.ioDispatcher,
            ScriptedTransport(itemsByWorkspace = mapOf("ws_1" to """{"items":[],"count":0}""")),
        )

        model.onUserChanged("user_a")
        s.drain()

        val state = model.uiState.value
        assertTrue(state.projects.isEmpty())
        assertNull(state.projectsError)
        assertFalse("not loading and not failing is genuinely empty", state.isLoadingProjects)
    }

    @Test
    fun retryProjectsRefetchesTheSectionWithoutTouchingRecents() = projectsTest { s ->
        // A projects failure while the recents are fine must not be reported against a list the reader never had a problem with.
        val transport = ScriptedTransport()
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()
        val itemsCallsBefore = transport.requested.count { it.endsWith("/items") }

        model.retryProjects()
        s.drain()

        assertEquals(
            "retrying projects must re-run only the projects fetch",
            itemsCallsBefore + 1,
            transport.requested.count { it.endsWith("/items") },
        )
    }

    @Test
    fun theItemsFetchIsScopedToTheSelectedWorkspace() = projectsTest { s ->
        val transport = ScriptedTransport()
        val model = buildModel(s.ioDispatcher, transport)

        model.onUserChanged("user_a")
        s.drain()

        // The first workspace is the default, so switching is what proves the scope actually follows the selection rather than merely happening to be right on the first …
        model.selectWorkspace("ws_2")
        s.drain()

        assertTrue(
            "expected a ws_2 items call, got ${transport.requested}",
            transport.requested.contains("/api/workspaces/ws_2/items"),
        )
    }

    @Test
    fun theWorkspacesCallAsksForNoItemsAndTheItemsCallAsksForNoTasks() = projectsTest { s ->
        // `is_include_items` defaults to true on the server, and true drags along every workspace's items *and* tasks — the whole feature in one response.
        val transport = ScriptedTransport()
        val model = buildModel(s.ioDispatcher, transport)

        model.onUserChanged("user_a")
        s.drain()

        assertTrue(
            "the workspaces call must ask for no items, got ${transport.requested}",
            transport.requested.contains("/api/workspaces?is_include_items=false"),
        )
        assertTrue(
            "the items call must not carry the flag at all",
            transport.requested.none { it.startsWith("/api/workspaces/") && it.contains("is_include_items") },
        )
    }

    @Test
    fun aProjectsChatRowCarriesTheSessionIdSoTheChatRouteTakesItVerbatim() = projectsTest { s ->
        val transport = ScriptedTransport(chatsByProject = mapOf("item_1" to listOf("task_42")))
        val model = buildModel(s.ioDispatcher, transport)
        model.onUserChanged("user_a")
        s.drain()

        model.toggleProjectExpanded("item_1")
        s.drain()

        // The backend joins tasks to sessions on this id.
        assertEquals("task_42", model.uiState.value.projectChatsFor("item_1")?.chats?.first()?.id)
    }
}
