package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.io.IOException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutineClientTest {
    private class MemorySessionStore(var value: String? = "tok-123") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeTransport(
        var response: AuthHttpResponse = AuthHttpResponse(statusCode = 200, body = "{}"),
        var failure: Exception? = null,
    ) : AuthTransport {
        var lastMethod: String? = null
        var lastPath: String? = null
        var lastBody: String? = null
        var lastHeaders: Map<String, String> = emptyMap()

        private fun record(method: String, path: String, body: String?, headers: Map<String, String>): AuthHttpResponse {
            lastMethod = method
            lastPath = path
            lastBody = body
            lastHeaders = headers
            failure?.let { throw it }
            return response
        }

        override fun post(path: String, body: String, headers: Map<String, String>) =
            record("POST", path, body, headers)

        override fun get(path: String, headers: Map<String, String>) =
            record("GET", path, null, headers)

        override fun patch(path: String, body: String, headers: Map<String, String>) =
            record("PATCH", path, body, headers)
    }

    private val routineJson =
        """{"routine":{"id":"r_1","workspace_item_id":"item_1","description":"d","instruction":"i","schedule":"0 9 * * *","selected_profile_model":"","enabled":true,"last_run_at":"","next_run_at":"","last_status":"","last_error":"","created_at":"","updated_at":""}}"""

    private fun client(transport: FakeTransport, store: MemorySessionStore = MemorySessionStore()) =
        RoutineClient(store, httpTransport = transport)

    @Test
    fun loadRoutineGetsTheRoutinePathWithCookieOnly() {
        val transport = FakeTransport(response = AuthHttpResponse(200, routineJson))
        val result = client(transport).loadRoutine("ws_1", "item_1")

        assertEquals("GET", transport.lastMethod)
        assertEquals("/api/workspaces/ws_1/items/item_1/routine", transport.lastPath)
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
        assertFalse(transport.lastHeaders.containsKey("Content-Type"))
        assertTrue(result is RecentsResult.Loaded)
        assertEquals("r_1", (result as RecentsResult.Loaded).value.id)
    }

    @Test
    fun loadRoutine401IsSignedOut() {
        val result = client(FakeTransport(response = AuthHttpResponse(401, ""))).loadRoutine("ws_1", "item_1")
        assertTrue(result is RecentsResult.SignedOut)
    }

    @Test
    fun loadRoutine500SaysRoutineNotSidebar() {
        val result = client(FakeTransport(response = AuthHttpResponse(500, ""))).loadRoutine("ws_1", "item_1")
        assertTrue(result is RecentsResult.Unavailable)
        val message = (result as RecentsResult.Unavailable).message
        assertTrue(message, message.contains("routine"))
        assertFalse(message, message.contains("sidebar"))
    }

    @Test
    fun loadRoutineUnreadableBodyIsUnavailable() {
        val result = client(FakeTransport(response = AuthHttpResponse(200, "{}"))).loadRoutine("ws_1", "item_1")
        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun loadRoutineNetworkFailureIsUnavailable() {
        val result = client(FakeTransport(failure = IOException("down"))).loadRoutine("ws_1", "item_1")
        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun createRoutinePostsVueShapeAndUnwrapsCreated() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                201,
                """{"item":{"id":"item_1","workspace_id":"ws_1","item_type":"routine","name":"Nightly","path":"/tmp/routine"},"routine":{"id":"r_1","workspace_item_id":"item_1","description":"","instruction":"i","schedule":"","selected_profile_model":"","enabled":true,"last_run_at":"","next_run_at":"","last_status":"","last_error":"","created_at":"","updated_at":""}}""",
            ),
        )
        val result = client(transport).createRoutine("ws_1", "Nightly", "/tmp/routine", instruction = "i")

        assertEquals("POST", transport.lastMethod)
        assertEquals("/api/workspaces/ws_1/items/routine", transport.lastPath)
        assertEquals("application/json", transport.lastHeaders["Content-Type"])
        val body = JSONObject(transport.lastBody!!)
        assertEquals("Nightly", body.getString("name"))
        assertEquals("/tmp/routine", body.getString("path"))
        assertTrue(result is RecentsResult.Loaded)
        val loaded = (result as RecentsResult.Loaded).value
        assertEquals("item_1", loaded.first.id)
        assertEquals("r_1", loaded.second.id)
    }

    @Test
    fun createRoutine400IsUnavailableNotSignedOut() {
        val result = client(FakeTransport(response = AuthHttpResponse(400, "")))
            .createRoutine("ws_1", "N", "/p")
        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun updateRoutinePatchesOnlySetFields() {
        val transport = FakeTransport(response = AuthHttpResponse(200, routineJson))
        val result = client(transport).updateRoutine("ws_1", "item_1", schedule = "0 * * * *", enabled = false)

        assertEquals("PATCH", transport.lastMethod)
        assertEquals("/api/workspaces/ws_1/items/item_1/routine", transport.lastPath)
        val body = JSONObject(transport.lastBody!!)
        assertEquals("0 * * * *", body.getString("schedule"))
        assertFalse(body.getBoolean("enabled"))
        assertFalse(body.has("description"))
        assertTrue(result is RecentsResult.Loaded)
    }

    @Test
    fun updateRoutineSendsSelectedProfileModel() {
        val transport = FakeTransport(response = AuthHttpResponse(200, routineJson))
        client(transport).updateRoutine("ws_1", "item_1", selectedProfileModel = "900ribu")
        assertEquals("900ribu", JSONObject(transport.lastBody!!).getString("selected_profile_model"))
    }

    @Test
    fun runRoutinePostsPluralPathAndReturnsSessionId() {
        val transport = FakeTransport(response = AuthHttpResponse(200, """{"session_id":"r_1"}"""))
        val result = client(transport).runRoutine("ws_1", "item_1", "r_1")

        assertEquals("POST", transport.lastMethod)
        assertEquals("/api/workspaces/ws_1/items/item_1/routines/r_1/run", transport.lastPath)
        assertTrue(result is RecentsResult.Loaded)
        assertEquals("r_1", (result as RecentsResult.Loaded).value)
    }

    @Test
    fun runRoutineMissingSessionIdIsUnavailable() {
        val result = client(FakeTransport(response = AuthHttpResponse(200, "{}")))
            .runRoutine("ws_1", "item_1", "r_1")
        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun sessionStoreFailureIsUnavailable() {
        val store = object : SessionStore {
            override fun read(): String? = throw IllegalStateException("locked")
            override fun save(cookieValue: String) = Unit
            override fun clear() = Unit
        }
        val result = RoutineClient(store, httpTransport = FakeTransport()).loadRoutine("ws_1", "item_1")
        assertTrue(result is RecentsResult.Unavailable)
    }
}
