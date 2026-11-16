package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.io.IOException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The three reads the board's form needs and the one write that lands the card in a column. */
class KanbanClientTest {
    private class MemorySessionStore(var value: String? = "tok-123") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeTransport : AuthTransport {
        var getResponse: AuthHttpResponse = AuthHttpResponse(200, body = "{}")
        var patchStatus: Int = 200
        var getFailure: Exception? = null
        var patchFailure: Exception? = null

        val gets = mutableListOf<String>()
        val patches = mutableListOf<Triple<String, String, Map<String, String>>>()

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse = error("This client only reads and moves.")

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            gets += path
            getFailure?.let { throw it }
            return getResponse
        }

        override fun patch(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            patches += Triple(path, body, headers)
            patchFailure?.let { throw it }
            return AuthHttpResponse(patchStatus, body = "{}")
        }
    }

    // ─── The columns ──────────────────────────────────────────────────────────

    @Test
    fun columnsComeBackInBoardOrderWithTheirNames() {
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(
                200,
                body = """
                {"columns":[
                  {"id":"col_todo","workspace_item_id":"item_1","name":"todo","position":0,"created_at":"2026-01-01"},
                  {"id":"col_done","workspace_item_id":"item_1","name":"done","position":2,"created_at":"2026-01-01"}
                ],"count":2}
                """.trimIndent(),
            )
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadColumns("ws_1", "item_1")

        val columns = (result as RecentsResult.Loaded).value
        assertEquals(listOf("todo", "done"), columns.map { it.displayName })
        assertEquals(listOf(0, 2), columns.map { it.position })
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/kanban/columns",
            transport.gets.single(),
        )
    }

    @Test
    fun aColumnWithNoIdIsDroppedRatherThanOffered() {
        // A column the form cannot move a card into is not a choice.
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(
                200,
                body = """{"columns":[{"id":"","name":"ghost"},{"id":"col_1","name":"todo"}],"count":2}""",
            )
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadColumns("ws_1", "item_1")

        assertEquals(listOf("col_1"), (result as RecentsResult.Loaded).value.map { it.id })
    }

    @Test
    fun anEmptyBoardIsLoadedAndNotAFailure() {
        // `{"columns":[]}` is a real answer.
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(200, body = """{"columns":[],"count":0}""")
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadColumns("ws_1", "item_1")

        assertTrue((result as RecentsResult.Loaded).value.isEmpty())
    }

    @Test
    fun aBodyThatIsNotColumnsIsUnavailable() {
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(200, body = "<html>502</html>")
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadColumns("ws_1", "item_1")

        assertTrue(result is RecentsResult.Unavailable)
    }

    // ─── The move ─────────────────────────────────────────────────────────────

    @Test
    fun theMoveIsAPatchToTheTasksMoveRouteWithTheColumnAndPosition() {
        val transport = FakeTransport()

        KanbanClient(MemorySessionStore(), httpTransport = transport)
            .moveTaskToColumn("ws_1", "item_1", "task_1", "col_done", position = 3)

        val (path, body, headers) = transport.patches.single()
        assertEquals("/api/workspaces/ws_1/items/item_1/tasks/task_1/move", path)
        assertEquals("col_done", JSONObject(body).getString("column_id"))
        assertEquals(3, JSONObject(body).getInt("position"))
        // The backend reads the session from this cookie and nowhere else.
        assertEquals("pabrik_session=tok-123", headers["Cookie"])
    }

    @Test
    fun aNewCardLandsAtTheTopOfTheColumn() {
        // Position 0 is what "put it in this column" means on a create form: the new card lands where the board is worked from.
        val transport = FakeTransport()

        KanbanClient(MemorySessionStore(), httpTransport = transport)
            .moveTaskToColumn("ws_1", "item_1", "task_1", "col_done")

        assertEquals(0, JSONObject(transport.patches.single().second).getInt("position"))
    }

    @Test
    fun noChosenColumnMeansNoRequestAtAll() {
        // The server auto-assigns to the board's first column, and that is a perfectly good outcome — not something to PATCH an empty id over.
        val transport = FakeTransport()

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .moveTaskToColumn("ws_1", "item_1", "task_1", "  ")

        assertTrue(transport.patches.isEmpty())
        assertTrue(result is RecentsResult.Loaded)
    }

    @Test
    fun aFailedMoveSaysTheCardExistsAndTheColumnDidNotLand() {
        // "Could not create that" would send the reader looking for a card that is already on their board, and the second one they then create would be a duplicate.
        val transport = FakeTransport().apply { patchStatus = 500 }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .moveTaskToColumn("ws_1", "item_1", "task_1", "col_done")

        val message = (result as RecentsResult.Unavailable).message
        assertTrue(message, message.contains("was created"))
    }

    @Test
    fun anExpiredSessionIsSignedOutRatherThanAFailedMove() {
        val transport = FakeTransport().apply { patchStatus = 401 }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .moveTaskToColumn("ws_1", "item_1", "task_1", "col_done")

        assertTrue(result is RecentsResult.SignedOut)
    }

    // ─── The other two reads ──────────────────────────────────────────────────

    @Test
    fun profileNamesAreTheKeysOfTheProfilesObject() {
        // `config.profiles` is an object keyed by profile name, not the array the web's own type would suggest.
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(
                200,
                body = """{"profiles":{"fast":{"model":"haiku","base_url":""}},"active_profile":""}""",
            )
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadProfileNames()

        assertEquals(listOf("fast"), (result as RecentsResult.Loaded).value)
        assertEquals("/api/config/pabrik", transport.gets.single())
    }

    @Test
    fun theServerHomeComesFromTheFolderListing() {
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(
                200,
                body = """{"path":"~","absolute":"/home/ginwa","home":"/home/ginwa","parent":"/home"}""",
            )
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadServerHome()

        assertEquals("/home/ginwa", (result as RecentsResult.Loaded).value)
        assertEquals("/api/system/folder?action=list", transport.gets.single())
    }

    @Test
    fun anUnknownServerHomeIsEmptyRatherThanGuessed() {
        // A literal `~` must never reach the agent's path validator, so the unknown case is "" and the prefill falls back to the `~` display.
        val transport = FakeTransport().apply {
            getResponse = AuthHttpResponse(200, body = """{"path":"~"}""")
        }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadServerHome()

        assertEquals("", (result as RecentsResult.Loaded).value)
    }

    @Test
    fun anUnreadableSessionIsUnavailableOnEveryCall() {
        val transport = FakeTransport()
        val store = object : SessionStore {
            override fun read(): String? = throw IllegalStateException("no keystore")
            override fun save(cookieValue: String) = Unit
            override fun clear() = Unit
        }
        val client = KanbanClient(store, httpTransport = transport)

        assertTrue(client.loadColumns("ws_1", "item_1") is RecentsResult.Unavailable)
        assertTrue(client.loadProfileNames() is RecentsResult.Unavailable)
        assertTrue(client.loadServerHome() is RecentsResult.Unavailable)
        assertTrue(
            client.moveTaskToColumn("ws_1", "item_1", "task_1", "col_1")
                is RecentsResult.Unavailable,
        )
        assertTrue(transport.gets.isEmpty())
        assertTrue(transport.patches.isEmpty())
    }

    @Test
    fun aTransportThatThrowsIsUnavailableNotACrash() {
        val transport = FakeTransport().apply { getFailure = IOException("connection reset") }

        val result = KanbanClient(MemorySessionStore(), httpTransport = transport)
            .loadColumns("ws_1", "item_1")

        assertTrue(result is RecentsResult.Unavailable)
    }

    // ─── The paths, which are the whole contract for a route with no client ────

    @Test
    fun idsAreEncodedIntoTheirSegments() {
        // An id carrying a slash must not invent a path segment; the backend nests every one of these under a workspace and an item.
        assertEquals(
            "/api/workspaces/ws%201/items/it%2F2/tasks/t%203/move",
            KanbanApi.moveTaskPath("ws 1", "it/2", "t 3"),
        )
        assertEquals(
            "/api/workspaces/ws%201/items/it%2F2/kanban/columns",
            KanbanApi.columnsPath("ws 1", "it/2"),
        )
    }
}
