package com.pabrik.mobile.projects

import com.pabrik.mobile.recents.defaultProjectId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The drawer's top-level "New Chat": the workspace's default project (Migration 094) and the fallback request when this app's list has none. */
class DefaultProjectTest {

    private fun project(
        id: String,
        itemType: String = ProjectTypes.AGENT,
        isDefault: Boolean = false,
        path: String = "/home/tester",
    ) = ProjectSummary(
        id = id,
        workspaceId = "ws_1",
        itemType = itemType,
        name = if (isDefault) "Project Default" else id,
        path = path,
        isDefault = isDefault,
    )

    // ── the pure lookup ──────────────────────────────────────────────────

    @Test
    fun findsTheDefaultProject() {
        val projects = listOf(project("item_a"), project("item_default", isDefault = true))
        assertEquals("item_default", defaultProjectId(projects))
    }

    @Test
    fun findsItRegardlessOfItsPositionInTheList() {
        // The list is ordered by `position DESC`, and the default is inserted at the top — but a user reordering projects must not be able to lose their default, so the …
        val projects = listOf(
            project("item_default", isDefault = true),
            project("item_a"),
            project("item_b"),
        )
        assertEquals("item_default", defaultProjectId(projects))
    }

    @Test
    fun anEmptyListHasNoDefault() {
        assertNull(defaultProjectId(emptyList()))
    }

    @Test
    fun aListOfOrdinaryProjectsHasNoDefault() {
        // Null is the cold-start signal: the caller must ask the server to create one.
        val projects = listOf(project("item_a"), project("item_b"), project("item_c"))
        assertNull(defaultProjectId(projects))
    }

    @Test
    fun aKanbanProjectIsNotADefaultEvenIfItClaimsToBe() {
        // The flag is the whole contract; the type is checked by the create flow, not here.
        val projects = listOf(project("item_board", ProjectTypes.KANBAN, isDefault = true))
        assertEquals("item_board", defaultProjectId(projects))
    }

    // ── the parser ───────────────────────────────────────────────────────

    @Test
    fun parseItemsReadsIsDefaultAsZeroOrOne() {
        // The column is an INTEGER, so the wire value is 1/0 and not a JSON boolean — a `optBoolean` here would silently read every row as false and the New Chat row …
        val body = """
            {"items":[
              {"id":"item_default","workspace_id":"ws_1","item_type":"agent",
               "name":"Project Default","path":"/home/tester","is_default":1},
              {"id":"item_a","workspace_id":"ws_1","item_type":"agent",
               "name":"Helper","path":"/tmp/a","is_default":0}
            ],"count":2}
        """.trimIndent()

        val items = ProjectsApi.parseItems(body)

        assertEquals(2, items.size)
        assertEquals(true, items[0].isDefault)
        assertEquals("/home/tester", items[0].path)
        assertEquals(false, items[1].isDefault)
    }

    @Test
    fun aMissingIsDefaultReadsAsOrdinary() {
        // A server older than Migration 094 omits the column.
        val body = """
            {"items":[
              {"id":"item_a","workspace_id":"ws_1","item_type":"agent","name":"Helper","path":"/tmp/a"}
            ],"count":1}
        """.trimIndent()

        assertEquals(false, ProjectsApi.parseItems(body).single().isDefault)
    }

    @Test
    fun parseDefaultProjectUnwrapsTheItemEnvelope() {
        val body = """
            {"item":{"id":"item_default","workspace_id":"ws_1","item_type":"agent",
                     "name":"Project Default","path":"/home/tester","is_default":1},
             "created":true}
        """.trimIndent()

        val project = ProjectsApi.parseDefaultProject(body)

        requireNotNull(project)
        assertEquals("item_default", project.id)
        assertEquals(ProjectTypes.AGENT, project.itemType)
        assertEquals("/home/tester", project.path)
        assertEquals(true, project.isDefault)
    }

    @Test
    fun parseDefaultProjectRejectsAnEnvelopeWithNoUsableItem() {
        // An id-less row cannot be scoped to, so it is unusable — the same rule parseItems applies.
        assertNull(ProjectsApi.parseDefaultProject("""{"created":true}"""))
        assertNull(
            ProjectsApi.parseDefaultProject(
                """{"item":{"workspace_id":"ws_1","item_type":"agent"},"created":true}""",
            ),
        )
    }

    // ── the endpoint path ────────────────────────────────────────────────

    @Test
    fun theDefaultProjectPathIsNestedUnderTheWorkspace() {
        assertEquals(
            "/api/workspaces/ws_1/default-project",
            ProjectsApi.defaultProjectPath("ws_1"),
        )
    }

    @Test
    fun theDefaultProjectPathEncodesTheWorkspaceId() {
        // Every id in every path builder goes through the same encoder; an unencoded id here is a 404 that only shows up for ids the tests happen not to use.
        assertEquals(
            "/api/workspaces/ws%2Fweird/default-project",
            ProjectsApi.defaultProjectPath("ws/weird"),
        )
    }

    // ── the create flow the row depends on ───────────────────────────────

    @Test
    fun anAgentDefaultSkipsTheTypePicker() {
        // The whole point of `item_type = 'agent'`: the drawer's per-project `+` opens a bottom sheet asking Standard Chat / Routine / Memory for every other type.
        val decision = createTaskStartDecision(ProjectTypes.AGENT)
        assertEquals(
            CreateTaskStartDecision.Create(
                CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
            ),
            decision,
        )
    }

    @Test
    fun theStandardChatNameMatchesTheDesktop() {
        // Matches the desktop's `DEFAULT_NEW_CHAT_NAME` (`Sidebar.vue`) exactly.
        assertEquals("New Chat", TaskTypes.DEFAULT_NEW_CHAT_NAME)
    }
}
