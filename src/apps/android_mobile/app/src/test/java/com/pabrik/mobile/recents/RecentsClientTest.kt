package com.pabrik.mobile.recents

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RecentsClientTest {
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
        ): AuthHttpResponse = error("The sidebar only reads.")

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
    fun loadWorkspacesSendsTheSessionCookie() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"workspaces":[{"id":"ws_1","name":"Sprint bulan Juni"}]}""",
            ),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadWorkspaces()

        assertTrue(result is RecentsResult.Loaded)
        val loaded = (result as RecentsResult.Loaded).value as List<*>
        assertEquals(listOf("ws_1"), loaded.map { (it as WorkspaceOption).id })
        // The backend reads the session from this cookie and nowhere else, so a client that omitted it would silently get a 401.
        assertEquals("Cookie", transport.lastHeaders.keys.single())
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
    }

    @Test
    fun loadChatsScopesTheRequestToTheWorkspace() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"sessions":[{"session_id":"task_1","session_name":"Real chat"}]}""",
            ),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadChats("item_1785055824163739523")

        assertTrue(result is RecentsResult.Loaded)
        val path = transport.lastPath.orEmpty()
        assertTrue(path, path.contains("workspace_id=item_1785055824163739523"))
        assertTrue(path, path.contains("sort_by=updated_at"))
        assertTrue(path, path.contains("direction=desc"))
    }

    @Test
    fun anExpiredCookieReportsSignedOutRatherThanAnError() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 401, body = """{"error":"unauthorized"}"""),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        // Retry cannot fix a dead cookie, so this has to be distinguishable from a transient failure at the ViewModel.
        assertEquals(RecentsResult.SignedOut, client.loadWorkspaces())
    }

    @Test
    fun aServerErrorIsRetryable() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 503, body = "unavailable"),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadWorkspaces()

        assertTrue(result is RecentsResult.Unavailable)
        assertTrue(
            (result as RecentsResult.Unavailable).message.isNotBlank(),
        )
    }

    @Test
    fun anOfflineDeviceIsRetryable() {
        val transport = FakeTransport(failure = IOException("no route to host"))
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadWorkspaces()

        assertTrue(result is RecentsResult.Unavailable)
        assertTrue(
            (result as RecentsResult.Unavailable).message.contains("Check your connection"),
        )
    }

    @Test
    fun anUnreadableBodyIsAnErrorNotACrashOrAnEmptySidebar() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 200, body = "<html>proxy error</html>"),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadWorkspaces()

        // A parse failure must never degrade into "you have no workspaces", which is indistinguishable from a real empty account.
        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun anUnreadableSessionCookieIsAnErrorNotARequestWithNoAuth() {
        val store = object : SessionStore {
            override fun read(): String? = throw IOException("keystore unavailable")
            override fun save(cookieValue: String) = Unit
            override fun clear() = Unit
        }
        val transport = FakeTransport()
        val client = RecentsClient(store, httpTransport = transport)

        val result = client.loadWorkspaces()

        assertTrue(result is RecentsResult.Unavailable)
        // Sending the request anyway would have produced a 401 and looked like a signed-out user.
        assertEquals(null, transport.lastPath)
    }

    @Test
    fun aGenuinelyEmptyAccountLoadsAsEmpty() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 200, body = """{"workspaces":[]}"""),
        )
        val client = RecentsClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadWorkspaces()

        assertTrue(result is RecentsResult.Loaded)
        assertEquals(emptyList<WorkspaceOption>(), (result as RecentsResult.Loaded).value)
    }
}
