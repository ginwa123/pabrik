package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The projects client, over a transport that answers whatever the test says. */
class ProjectsClientTest {
    private class MemorySessionStore(var value: String? = "tok-123") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeTransport(
        var response: AuthHttpResponse = AuthHttpResponse(statusCode = 200, body = "{}"),
        var failure: Exception? = null,
    ) : AuthTransport {
        var lastPath: String? = null
        var lastHeaders: Map<String, String> = emptyMap()

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse = error("The drawer only reads.")

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            lastPath = path
            lastHeaders = headers
            failure?.let { throw it }
            return response
        }
    }

    @Test
    fun sendsTheSessionCookieAndNothingElse() {
        // The backend reads the session from this cookie and from nowhere else, and accepts no Authorization header and no CSRF token, so a native client has to send the …
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"items":[],"count":0}""",
            ),
        )

        ProjectsClient(MemorySessionStore(), httpTransport = transport).loadProjects("ws_1")

        assertEquals("Cookie", transport.lastHeaders.keys.single())
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
    }

    @Test
    fun a401IsSignOutRatherThanAnErrorTheReaderCanRetry() {
        val result = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(response = AuthHttpResponse(401, "")),
        ).loadProjects("ws_1")

        assertTrue("expected SignedOut, got $result", result is RecentsResult.SignedOut)
    }

    @Test
    fun aProjectsFailureNeverBlamesTheSidebar() {
        // `RecentsClient.messageForStatus` hard-codes "sidebar" into its 5xx and default messages.
        val server = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(response = AuthHttpResponse(500, "")),
        ).loadProjects("ws_1")
        val notFound = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(response = AuthHttpResponse(404, "")),
        ).loadProjects("ws_1")

        assertEquals("The server could not load your projects. Try again.", server.message())
        assertEquals("Could not load your projects. Try again.", notFound.message())
    }

    @Test
    fun anUnreadableResponseIsUnavailableRatherThanACrash() {
        val result = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(response = AuthHttpResponse(200, "not json at all")),
        ).loadProjects("ws_1")

        assertEquals("The server sent a response this app could not read.", result.message())
    }

    @Test
    fun loadsAProjectsPageFromTheWorkspacePath() {
        val result = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(
                response = AuthHttpResponse(
                    statusCode = 200,
                    body = """
                        {"items":[{"id":"item_1","workspace_id":"ws_1","item_type":"kanban",
                        "name":"board"}],"count":1}
                    """.trimIndent(),
                ),
            ),
        ).loadProjects("ws_1")

        val loaded = (result as RecentsResult.Loaded).value as List<ProjectSummary>
        assertEquals(listOf("item_1"), loaded.map { it.id })
    }

    @Test
    fun loadsAProjectsChatPageAndAttachesTheProjectScope() {
        val result = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(
                response = AuthHttpResponse(
                    statusCode = 200,
                    body = """{"tasks":[{"id":"t1","name":"a"}],"count":1,"has_more":true,"next_cursor":"c1"}""",
                ),
            ),
        ).loadProjectChats("ws_1", "item_1")

        val loaded = (result as RecentsResult.Loaded).value as ProjectChatsPage
        assertEquals("item_1", loaded.chats.first().projectId)
        assertTrue(loaded.hasMore)
        assertEquals("c1", loaded.nextCursor)
    }

    @Test
    fun theChatPathCarriesBothIds() {
        val transport = FakeTransport(
            response = AuthHttpResponse(200, """{"tasks":[],"count":0,"has_more":false}"""),
        )

        ProjectsClient(MemorySessionStore(), httpTransport = transport)
            .loadProjectChats("ws_1", "item_1")

        assertTrue(transport.lastPath!!.startsWith("/api/workspaces/ws_1/items/item_1/tasks?"))
    }

    @Test
    fun anUnreachableHostSaysSoRatherThanClaimingTheDataIsBroken() {
        val result = ProjectsClient(
            MemorySessionStore(),
            httpTransport = FakeTransport(failure = IOException("no route to host")),
        ).loadProjects("ws_1")

        assertTrue("expected an unreachable message, got ${result.message()}", result.message()!!.contains("Could not reach"))
    }

    @Test
    fun anUnreadableSessionIsAnErrorTheReaderCanActOn() {
        val broken = object : SessionStore {
            override fun read(): String? = throw IllegalStateException("keystore gone")
            override fun save(cookieValue: String) = Unit
            override fun clear() = Unit
        }

        val result = ProjectsClient(broken, httpTransport = FakeTransport()).loadProjects("ws_1")

        assertEquals("Could not read the saved session. Try signing in again.", result.message())
    }

    @Test
    fun aMissingCookieStillSendsARequestRatherThanGuessingAnIdentity() {
        // Null is a legitimate "not signed in yet" for the auth layer; the server decides what it means.
        val transport = FakeTransport(
            response = AuthHttpResponse(200, """{"items":[],"count":0}"""),
        )

        ProjectsClient(MemorySessionStore(value = null), httpTransport = transport)
            .loadProjects("ws_1")

        assertNull(transport.lastHeaders["Cookie"])
        assertEquals("/api/workspaces/ws_1/items", transport.lastPath)
    }

    private fun RecentsResult<*>.message(): String? =
        (this as? RecentsResult.Unavailable)?.message
}
