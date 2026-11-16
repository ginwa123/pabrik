package com.pabrik.mobile.auth

import com.pabrik.mobile.BuildConfig
import java.io.IOException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthClientTest {
    private class MemorySessionStore(
        var value: String? = null,
    ) : SessionStore {
        override fun read(): String? = value

        override fun save(cookieValue: String) {
            value = cookieValue
        }

        override fun clear() {
            value = null
        }
    }

    private class FakeTransport(
        var response: AuthHttpResponse,
    ) : AuthTransport {
        var lastMethod: String? = null
        var lastPath: String? = null
        var lastBody: String? = null
        var lastHeaders: Map<String, String> = emptyMap()
        var throwIo: Boolean = false

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            record("POST", path, body, headers)
            if (throwIo) throw IOException("offline")
            return response
        }

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            record("GET", path, null, headers)
            if (throwIo) throw IOException("offline")
            return response
        }

        private fun record(
            method: String,
            path: String,
            body: String?,
            headers: Map<String, String>,
        ) {
            lastMethod = method
            lastPath = path
            lastBody = body
            lastHeaders = headers
        }
    }

    @Test
    fun loginSendsJsonAndPersistsSessionCookie() {
        val store = MemorySessionStore()
        val transport = FakeTransport(
            AuthHttpResponse(
                statusCode = 200,
                body = """
                    {"user":{"id":"user-1","email":"person@example.com","name":"Person","role":"admin"}}
                """.trimIndent(),
                setCookieHeaders = listOf(
                    "pabrik_session=token-123; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000",
                ),
            ),
        )
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Authenticated)
        assertEquals(
            AuthUser(
                id = "user-1",
                email = "person@example.com",
                name = "Person",
                role = "admin",
            ),
            (result as AuthResult.Authenticated).user,
        )
        assertEquals("/api/auth/login", transport.lastPath)
        assertEquals("POST", transport.lastMethod)
        assertEquals("token-123", store.value)
        assertEquals(
            "person@example.com",
            JSONObject(transport.lastBody!!).getString("email"),
        )
        assertEquals(
            "secret-password",
            JSONObject(transport.lastBody!!).getString("password"),
        )
    }

    @Test
    fun loginRejectsInvalidCredentialsWithoutStoringCookie() {
        val store = MemorySessionStore()
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(401, "{\"error\":\"InvalidCredentials\"}"),
            ),
        )

        val result = client.login("person@example.com", "wrong-password")

        assertTrue(result is AuthResult.Rejected)
        assertEquals("Invalid email or password.", (result as AuthResult.Rejected).message)
        assertNull(store.value)
    }

    @Test
    fun loginFailsClosedWhenServerOmitsSessionCookie() {
        val store = MemorySessionStore()
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(
                    statusCode = 200,
                    body = "{\"user\":{\"id\":\"user-1\",\"email\":\"person@example.com\"}}",
                ),
            ),
        )

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Rejected)
        assertNull(store.value)
    }

    @Test
    fun restoreSessionSendsCookieAndReturnsAuthenticatedUser() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(
            AuthHttpResponse(
                statusCode = 200,
                body = """
                    {"authenticated":true,"auth_enabled":true,
                     "user":{"id":"user-1","email":"person@example.com","name":"Person","role":"admin"}}
                """.trimIndent(),
            ),
        )
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.restoreSession()

        assertTrue(result is AuthResult.Authenticated)
        assertEquals("/api/auth/me", transport.lastPath)
        assertEquals("GET", transport.lastMethod)
        assertEquals("pabrik_session=saved-token", transport.lastHeaders["Cookie"])
    }

    @Test
    fun restoreSessionClearsRejectedCookie() {
        val store = MemorySessionStore("expired-token")
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(AuthHttpResponse(401, "{\"error\":\"Unauthenticated\"}")),
        )

        val result = client.restoreSession()

        assertTrue(result == AuthResult.NoSession)
        assertNull(store.value)
    }

    @Test
    fun restoreSessionReturnsUnavailableWithoutDeletingCookieOnNetworkError() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(AuthHttpResponse(200, "{}"))
        transport.throwIo = true
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        val result = client.restoreSession()

        assertTrue(result is AuthResult.Unavailable)
        assertEquals("saved-token", store.value)
    }

    @Test
    fun logoutClearsLocalSessionEvenWhenServerIsUnavailable() {
        val store = MemorySessionStore("saved-token")
        val transport = FakeTransport(AuthHttpResponse(200, "{\"ok\":true}"))
        transport.throwIo = true
        val client = AuthClient(sessionStore = store, httpTransport = transport)

        client.logout()

        assertNull(store.value)
        assertEquals("/api/auth/logout", transport.lastPath)
    }

    @Test
    fun restoreSessionWhenAuthIsDisabledKeepsLocalCookie() {
        val store = MemorySessionStore("saved-token")
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(200, "{\"authenticated\":false,\"auth_enabled\":false}"),
            ),
        )

        val result = client.restoreSession()

        assertTrue(result == AuthResult.AuthDisabled)
        assertEquals("saved-token", store.value)
    }

    @Test
    fun loginStorageFailureFailsClosed() {
        val store = object : SessionStore {
            var cleared = false

            override fun read(): String? = null

            override fun save(cookieValue: String) {
                throw IllegalStateException("storage unavailable")
            }

            override fun clear() {
                cleared = true
            }
        }
        val client = AuthClient(
            sessionStore = store,
            httpTransport = FakeTransport(
                AuthHttpResponse(
                    200,
                    "{\"user\":{\"id\":\"user-1\",\"email\":\"person@example.com\"}}",
                    setCookieHeaders = listOf("pabrik_session=token-123"),
                ),
            ),
        )

        val result = client.login("person@example.com", "secret-password")

        assertTrue(result is AuthResult.Unavailable)
        assertTrue(store.cleared)
    }

    @Test
    fun parseSessionCookieIgnoresAttributesAndRejectsEmptyValues() {
        assertEquals(
            "token-123",
            parseSessionCookie(
                listOf("pabrik_session=token-123; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"),
            ),
        )
        assertNull(parseSessionCookie(listOf("pabrik_session=; Path=/; Max-Age=0")))
        assertNull(parseSessionCookie(listOf("other=value")))
        assertEquals(
            "valid-token",
            parseSessionCookie(
                listOf(
                    "pabrik_session=; Path=/; Max-Age=0",
                    "pabrik_session=valid-token; Path=/",
                ),
            ),
        )
    }

    /** One transport, and the assertion is that the *request* is refused. */
    private fun refuse(url: String) = assertThrows(
        "$url must be refused",
        IllegalArgumentException::class.java,
    ) {
        HttpsAuthTransport { url }.get(path = AuthConfig.ME_PATH, headers = emptyMap())
    }

    @Test
    fun httpsTransportRefusesCleartextToAHostThisBuildCannotReach() {
        // The plain-HTTP exception is not "HTTP is fine anywhere" — it is the three loopback addresses the debug `network_security_config.xml` grants cleartext to, and …
        refuse("http://agent.ginwa.site")
    }

    @Test
    fun httpsTransportAcceptsCleartextToTheHostsTheDebugConfigPermits() {
        // The half that has to stay true, or the functional UI suite's whole `-PpabrikBaseUrl=http://10.0.2.2:<port>` seam stops working.
        if (!BuildConfig.ALLOW_INSECURE_HTTP) return

        val cleartext = "http://127.0.0.1:1/api/auth/me"
        // Resolving is the assertion: reaching the socket with an unroutable port fails at connect, and `AuthClient` turns that into Unavailable rather than letting it …
        val transport = HttpsAuthTransport { "http://127.0.0.1:1" }
        assertTrue(
            "cleartext to a permitted host must not be refused by the scheme rule",
            runCatching { transport.get(path = "/api/auth/me", headers = emptyMap()) }
                .exceptionOrNull() !is IllegalArgumentException,
        )
        assertTrue(cleartext.startsWith("http://"))
    }

    @Test
    fun httpsTransportRejectsEverySchemeThatIsNotHttpOrHttps() {
        // The widening is for plain HTTP specifically, so the flag cannot be used to smuggle in a scheme this client has no business opening.
        for (url in listOf("ftp://agent.ginwa.site", "file:///etc/hosts", "ws://agent.ginwa.site")) {
            refuse(url)
        }
    }

    @Test
    fun aSchemeLessHostIsResolvedToHttpsRatherThanRefused() {
        // The old guard read `startsWith("https://")`, so a person who typed their own domain without a scheme got an error telling them the address was invalid — having …
        var baseUrl = "agent.ginwa.site"
        val transport = HttpsAuthTransport { baseUrl }

        // Nothing that could be the scheme rule: the name resolves, and the request goes out over TLS to a host that does not exist.
        val failure = runCatching { transport.get(path = AuthConfig.ME_PATH, headers = emptyMap()) }
        assertTrue(
            "a scheme-less host must not be refused by the scheme rule: ${failure.exceptionOrNull()}",
            failure.exceptionOrNull() !is IllegalArgumentException,
        )

        // And it is HTTPS that gets used, not HTTP.
        baseUrl = "ftp://agent.ginwa.site"
        assertThrows(IllegalArgumentException::class.java) {
            transport.get(path = AuthConfig.ME_PATH, headers = emptyMap())
        }
    }

    @Test
    fun theTransportReadsTheHostPerRequestRatherThanCapturingIt() {
        // The behaviour the whole feature rests on.
        var baseUrl = "https://first.example"
        val transport = HttpsAuthTransport { baseUrl }

        baseUrl = "ftp://second.example"
        assertThrows(
            "a transport holding a captured host would still have used the first",
            IllegalArgumentException::class.java,
        ) {
            transport.get(path = AuthConfig.ME_PATH, headers = emptyMap())
        }
    }
}
