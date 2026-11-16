package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The wire, pinned where getting it wrong produces a list that merely *looks* fine — which is the failure mode for all of these. */
class ProjectsApiTest {

    @Test
    fun itemsPathScopesToTheWorkspace() {
        val path = ProjectsApi.itemsPath("item_1785055824163739523")

        assertEquals("/api/workspaces/item_1785055824163739523/items", path)
    }

    @Test
    fun itemsPathEncodesAnIdThatWouldOtherwiseSplitTheRoute() {
        // A workspace id containing a slash would land on a different route entirely if it were concatenated raw.
        val path = ProjectsApi.itemsPath("ws/../admin")

        assertFalse("an unencoded slash would split the path segment", path.contains("ws/../admin"))
        assertTrue("the slash must be percent-encoded", path.contains("%2F"))
    }

    @Test
    fun tasksPathAsksForNewestFirstAndCarriesBothIds() {
        val path = ProjectsApi.tasksPath("ws_1", "item_1")

        assertTrue(path, path.startsWith("/api/workspaces/ws_1/items/item_1/tasks?"))
        assertTrue(path, path.contains("sort_by=updated_at"))
        assertTrue(path, path.contains("direction=desc"))
        assertTrue(path, path.contains("limit=${ProjectsApi.TASKS_PAGE_LIMIT}"))
    }

    @Test
    fun tasksPathEncodesBothSegments() {
        val path = ProjectsApi.tasksPath("ws/1", "item 1")

        assertTrue(path, path.contains("ws%2F1"))
        assertTrue(path, path.contains("item%201"))
    }

    @Test
    fun tasksPathOmitsABlankCursor() {
        // A blank cursor is indistinguishable from "first page" to the server, so sending it would restart the list and re-serve page 1 forever.
        assertFalse(
            "a null cursor must not be sent at all",
            ProjectsApi.tasksPath("ws_1", "item_1", cursor = null).contains("cursor"),
        )
        assertFalse(
            "a blank cursor must not be sent either",
            ProjectsApi.tasksPath("ws_1", "item_1", cursor = "   ").contains("cursor"),
        )
    }

    @Test
    fun tasksPathRoundTripsTheServersOwnCursorVerbatim() {
        // The cursor is `"<sort_value>|<id>"`, not an opaque token.
        val cursor = "2026-09-26 05:12:37|task_9"
        val path = ProjectsApi.tasksPath("ws_1", "item_1", cursor = cursor)

        assertTrue(path, path.contains("cursor=2026-09-26+05%3A12%3A37%7Ctask_9"))
    }

    @Test
    fun parseItemsReadsEveryFieldTheRowNeeds() {
        val body = """
            {"items":[{"id":"item_1","workspace_id":"ws_1","item_type":"kanban",
            "name":"sprint board","path":"/home/me/board","created_at":"2026-01-01 00:00:00",
            "updated_at":"2026-01-02 00:00:00"}],"count":1}
        """.trimIndent()

        val projects = ProjectsApi.parseItems(body)

        assertEquals(1, projects.size)
        val project = projects.first()
        assertEquals("item_1", project.id)
        assertEquals("ws_1", project.workspaceId)
        assertEquals(ProjectTypes.KANBAN, project.itemType)
        assertEquals("sprint board", project.displayName)
        assertEquals("/home/me/board", project.path)
    }

    @Test
    fun parseItemsSkipsRowsWithoutAnId() {
        // A row without an id cannot be scoped to, so it is unusable — the same rule the recents parser applies to sessions.
        val body = """{"items":[{"item_type":"kanban","name":"nameless"},{"id":"item_2","item_type":"agent","name":"real"}],"count":2}"""

        val projects = ProjectsApi.parseItems(body)

        assertEquals(listOf("item_2"), projects.map { it.id })
    }

    @Test
    fun parseItemsLeavesNameAndPathEmptyWhenTheServerSendsNull() {
        // `name` and `path` are both nullable server-side.
        val body = """{"items":[{"id":"item_1","workspace_id":"ws_1","item_type":"kanban","name":null,"path":null}],"count":1}"""

        val project = ProjectsApi.parseItems(body).first()

        assertEquals("", project.name)
        assertEquals("Untitled project", project.displayName)
    }

    @Test
    fun parseItemsKeepsAnUnknownTypeSoTheRowStillRenders() {
        // Dropping it would hide a project the web app can see.
        val body = """{"items":[{"id":"item_1","workspace_id":"ws_1","item_type":"something_new","name":"future"}],"count":1}"""

        assertEquals("something_new", ProjectsApi.parseItems(body).first().itemType)
    }

    @Test
    fun parseItemsTreatsAMissingArrayAsNoProjects() {
        assertEquals(emptyList<ProjectSummary>(), ProjectsApi.parseItems("""{}"""))
    }

    @Test
    fun parseProjectChatsStopsOnHasMoreNotOnCursorPresence() {
        // The decoy, pinned on the projects path so a future reader does not have to know it from the chats test: `next_cursor` is emitted whenever the page was …
        val body = """{"tasks":[{"id":"t1","name":"a"}],"count":1,"has_more":false,"next_cursor":"2026-09-26|t1"}"""

        val page = ProjectsApi.parseProjectChatsPage(body, "item_1")

        assertFalse("a present cursor must not imply more", page.hasMore)
        // The cursor is still *readable*, so a retry could re-request the window.
        assertEquals("2026-09-26|t1", page.nextCursor)
    }

    @Test
    fun parseProjectChatsEndsTheScrollOnAnEmptyPageEvenWhenTheServerClaimsMore() {
        // A page carrying no rows while the server says there are more is a cursor that has stopped advancing.
        val body = """{"tasks":[],"count":0,"has_more":true,"next_cursor":"2026-09-26|t9"}"""

        assertFalse(ProjectsApi.parseProjectChatsPage(body, "item_1").hasMore)
    }

    @Test
    fun parseProjectChatsReadsTheTaskIdAsTheSessionId() {
        // The backend joins the two tables on it.
        val body = """{"tasks":[{"id":"task_42","name":"a chat"}],"count":1,"has_more":false,"next_cursor":null}"""

        assertEquals("task_42", ProjectsApi.parseProjectChatsPage(body, "item_1").chats.first().id)
    }

    @Test
    fun parseProjectChatsSkipsRowsWithoutAnId() {
        val body = """{"tasks":[{"name":"nameless"},{"id":"t2","name":"real"}],"count":2,"has_more":false,"next_cursor":null}"""

        assertEquals(listOf("t2"), ProjectsApi.parseProjectChatsPage(body, "item_1").chats.map { it.id })
    }

    @Test
    fun parseProjectChatsReadsTheSameTimestampFormatAsTheChatList() {
        // The same SQLite-UTC string the recents parser already handles.
        val body = """{"tasks":[{"id":"t1","name":"a","updated_at":"2026-09-26 05:12:37"}],"count":1,"has_more":false,"next_cursor":null}"""

        val chat = ProjectsApi.parseProjectChatsPage(body, "item_1").chats.first()

        assertTrue("expected a real timestamp, got ${chat.updatedAtEpochMillis}", chat.updatedAtEpochMillis > 0L)
        assertTrue(chat.hasTimestamp)
    }

    @Test
    fun parseProjectChatsLeavesTheStampUnsetRatherThanGuessingTheEpoch() {
        // No parseable timestamp: no label beats a wrong one.
        val body = """{"tasks":[{"id":"t1","name":"a","updated_at":"","created_at":""}],"count":1,"has_more":false,"next_cursor":null}"""

        val chat = ProjectsApi.parseProjectChatsPage(body, "item_1").chats.first()

        assertEquals(0L, chat.updatedAtEpochMillis)
        assertFalse(chat.hasTimestamp)
    }

    @Test
    fun parseProjectChatsFallsBackToCreatedAt() {
        val body = """{"tasks":[{"id":"t1","name":"a","updated_at":"","created_at":"2026-09-26 05:12:37"}],"count":1,"has_more":false,"next_cursor":null}"""

        assertTrue(ProjectsApi.parseProjectChatsPage(body, "item_1").chats.first().hasTimestamp)
    }

    @Test
    fun aProjectChatWithNoNameStillRendersAsARow() {
        val body = """{"tasks":[{"id":"t1","name":""}],"count":1,"has_more":false,"next_cursor":null}"""

        assertEquals(
            "New Chat",
            ProjectsApi.parseProjectChatsPage(body, "item_1").chats.first().displayName,
        )
    }

    @Test
    fun mergeProjectChatsReplacesInPlaceAndDeduplicates() {
        // A chat touched while the reader is between pages moves up the ordering, so a page boundary can legitimately hand back a row already on screen.
        val current = listOf(
            ProjectChat("a", "item_1", "A", 1L),
            ProjectChat("b", "item_1", "B", 2L),
        )
        val incoming = listOf(
            ProjectChat("b", "item_1", "B renamed", 9L),
            ProjectChat("c", "item_1", "C", 3L),
        )

        val merged = ProjectsApi.mergeProjectChatsById(current, incoming)

        assertEquals(listOf("a", "b", "c"), merged.map { it.id })
        assertEquals("B renamed", merged.first { it.id == "b" }.name)
    }

    @Test
    fun mergeProjectChatsWithAnEmptyPageReturnsTheCurrentListUnchanged() {
        val current = listOf(ProjectChat("a", "item_1", "A", 1L))

        assertSameList(current, ProjectsApi.mergeProjectChatsById(current, emptyList()))
    }

    @Test
    fun aBlankNextCursorBecomesNullRatherThanBeingHandedBack() {
        // A blank cursor is worse than none: it would restart the list at page 1 and hand back rows the screen already shows.
        val body = """{"tasks":[{"id":"t1","name":"a"}],"count":1,"has_more":true,"next_cursor":""}"""

        assertNull(ProjectsApi.parseProjectChatsPage(body, "item_1").nextCursor)
    }

    private fun assertSameList(expected: List<ProjectChat>, actual: List<ProjectChat>) {
        assertEquals(expected.map { it.id }, actual.map { it.id })
    }
}
