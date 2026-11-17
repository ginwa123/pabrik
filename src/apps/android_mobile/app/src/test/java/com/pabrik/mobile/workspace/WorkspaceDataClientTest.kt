package com.pabrik.mobile.workspace

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceDataClientTest {
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
        ): AuthHttpResponse = error("Workspace data is read-only.")

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
    fun loadSecretsScopesThePathAndSendsTheCookie() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"secrets":[{"id":"sec_1","name":"KEY"}]}""",
            ),
        )
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadSecrets("ws_1")

        assertTrue(result is WorkspaceDataResult.Loaded)
        val secrets = (result as WorkspaceDataResult.Loaded).value as List<*>
        assertEquals(listOf("sec_1"), secrets.map { (it as SecretEntry).id })
        assertEquals("/api/workspaces/ws_1/secrets", transport.lastPath)
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
    }

    @Test
    fun loadMembersParsesTheRealPayload() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"members":[{"user_id":"u1","email":"a@b.c","role":"owner"}]}""",
            ),
        )
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadMembers("ws_1")

        val members = (result as WorkspaceDataResult.Loaded).value as List<*>
        assertEquals("a@b.c", (members.single() as MemberEntry).email)
        assertEquals("/api/workspaces/ws_1/members", transport.lastPath)
    }

    @Test
    fun loadUsageParsesTotals() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"totals":{"calls":7,"sessions":2},"daily":[],"models":[],"tools":[]}""",
            ),
        )
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadUsage("ws_1")

        val usage = (result as WorkspaceDataResult.Loaded).value as UsageData
        assertEquals(7, usage.totals.calls)
        assertEquals("/api/workspaces/ws_1/usage", transport.lastPath)
    }

    @Test
    fun a401IsReportedAsSignedOut() {
        val transport = FakeTransport(response = AuthHttpResponse(statusCode = 401, body = ""))
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        assertTrue(client.loadSecrets("ws_1") is WorkspaceDataResult.SignedOut)
    }

    @Test
    fun aNetworkFailureIsReportedAsUnavailable() {
        val transport = FakeTransport(failure = IOException("offline"))
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadSecrets("ws_1")

        assertTrue(result is WorkspaceDataResult.Unavailable)
    }

    @Test
    fun anUnparseableBodyIsReportedAsUnavailable() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 200, body = "not json"),
        )
        val client = WorkspaceDataClient(MemorySessionStore(), httpTransport = transport)

        assertTrue(client.loadSecrets("ws_1") is WorkspaceDataResult.Unavailable)
    }
}
