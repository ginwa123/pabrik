package com.pabrik.mobile.auth

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The `/me` cache as the client actually uses it. */
class AuthMeCacheClientTest {
    private class MemorySessionStore(var value: String? = "tok-a") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeAuthMeCache : AuthMeCache {
        val entries = mutableMapOf<String, CachedAuthMe>()
        var clears = 0

        override fun read(cookieFingerprint: String): CachedAuthMe? = entries[cookieFingerprint]

        override fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long) {
            entries[cookieFingerprint] = CachedAuthMe(responseBody, nowEpochMillis)
        }

        override fun clear() {
            clears += 1
            entries.clear()
        }
    }

    private var clock = 1_000_000L

    private fun client(
        store: SessionStore = MemorySessionStore(),
        transport: AuthTransport = FakeTransport(),
        cache: AuthMeCache? = FakeAuthMeCache(),
    ) = AuthClient(
        sessionStore = store,
        httpTransport = transport,
        meCache = cache,
        nowMillis = { clock },
    )

    private fun fingerprintOf(cookie: String) = AuthMeCacheCodec.fingerprint(cookie)!!

    @Test
    fun aFreshCacheHitMakesNoNetworkCall() {
        val transport = FakeTransport()
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)

        val result = client(transport = transport, cache = cache).restoreSession()

        assertTrue(result is AuthResult.Authenticated)
        // The whole point. Anything above zero means the cache saved nothing.
        assertEquals(0, transport.getCalls)
    }

    @Test
    fun aCacheHitStillYieldsTheRealUser() {
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)

        val result = client(cache = cache).restoreSession()

        val user = (result as AuthResult.Authenticated).user
        assertEquals("u1", user.id)
        assertEquals("dev@example.com", user.email)
    }

    @Test
    fun theCachedAndNetworkPathsAgreeOnTheSameBody() {
        // Shared `interpretMe`: a cached identity must be judged by the same rules as a live one, or the two drift.
        val cache = FakeAuthMeCache()
        val client = client(cache = cache)

        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock - AuthMeCacheCodec.TTL_MILLIS - 1)
        val fromCache = client.restoreSession()

        val transport = FakeTransport()
        val fresh = AuthClient(
            sessionStore = MemorySessionStore(),
            httpTransport = transport,
            meCache = null,
            nowMillis = { clock },
        ).restoreSession()

        assertEquals(fresh, fromCache)
    }

    @Test
    fun aStaleEntryIsAMissAndRefetches() {
        val transport = FakeTransport()
        val cache = FakeAuthMeCache()
        cache.write(
            fingerprintOf("tok-a"),
            AUTHENTICATED_BODY,
            clock - AuthMeCacheCodec.TTL_MILLIS - 1,
        )

        client(transport = transport, cache = cache).restoreSession()

        // Deliberate divergence from the web, which serves stale and revalidates behind.
        assertEquals(1, transport.getCalls)
    }

    @Test
    fun aSuccessfulResponseIsCachedAgainstItsOwnCookie() {
        val cache = FakeAuthMeCache()
        client(cache = cache).restoreSession()

        assertEquals(
            AUTHENTICATED_BODY,
            cache.entries[fingerprintOf("tok-a")]?.body,
        )
    }

    @Test
    fun anotherAccountsCookieCannotReachTheCachedIdentity() {
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)

        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = """{"authenticated":false,"auth_enabled":true}""",
            ),
        )
        val result = client(
            store = MemorySessionStore("tok-b"),
            transport = transport,
            cache = cache,
        ).restoreSession()

        // B must be judged by the network, not handed A's cached answer.
        assertEquals(1, transport.getCalls)
        assertTrue(result is AuthResult.NoSession)
    }

    @Test
    fun forceRefreshBypassesAFreshEntry() {
        val transport = FakeTransport()
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)

        client(transport = transport, cache = cache).restoreSession(forceRefresh = true)

        // The retry button exists to re-check; replaying the cache would make it inert.
        assertEquals(1, transport.getCalls)
    }

    @Test
    fun a401InvalidatesTheCacheAndTheSession() {
        val transport = FakeTransport(
            response = AuthHttpResponse(statusCode = 401, body = """{"error":"unauthorized"}"""),
        )
        val cache = FakeAuthMeCache()
        // STALE, not fresh: the real-world path is "cached a moment ago, cookie has since died".
        cache.write(
            fingerprintOf("tok-a"),
            AUTHENTICATED_BODY,
            clock - AuthMeCacheCodec.TTL_MILLIS - 1,
        )
        val store = MemorySessionStore("tok-a")

        val result = client(store = store, transport = transport, cache = cache).restoreSession()

        assertTrue(result is AuthResult.NoSession)
        assertEquals(1, transport.getCalls)
        assertEquals(1, cache.clears)
        assertTrue(cache.entries.isEmpty())
        assertNull(store.value)
    }

    @Test
    fun aCachedNotSignedInBodyIsRecheckedRatherThanActedOn() {
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = AUTHENTICATED_BODY,
            ),
        )
        val cache = FakeAuthMeCache()
        cache.entries[fingerprintOf("tok-a")] = CachedAuthMe(
            """{"authenticated":false,"auth_enabled":true}""",
            clock,
        )
        val store = MemorySessionStore("tok-a")

        val result = client(store = store, transport = transport, cache = cache).restoreSession()

        // A cached "not signed in" must not sign the user out on its own.
        assertEquals(1, transport.getCalls)
        assertTrue(result is AuthResult.Authenticated)
    }

    @Test
    fun aServerErrorIsNotCached() {
        // Android's recovery path is a retry button, and a cached 5xx or 401 would make that button do nothing.
        listOf(500, 503, 408).forEach { status ->
            val cache = FakeAuthMeCache()
            client(
                transport = FakeTransport(
                    response = AuthHttpResponse(statusCode = status, body = "boom"),
                ),
                cache = cache,
            ).restoreSession()

            assertTrue("status $status must not be cached", cache.entries.isEmpty())
        }
    }

    @Test
    fun aCorruptCachedBodyIsAMissNotAWrongIdentity() {
        val transport = FakeTransport()
        val cache = FakeAuthMeCache()
        // A FRESH envelope whose body is not a /me payload at all.
        cache.entries[fingerprintOf("tok-a")] = CachedAuthMe("""{"garbage":true}""", clock)

        val result = client(transport = transport, cache = cache).restoreSession()

        // It must be re-checked, not replayed: acting on garbage here would sign the user out on the strength of a corrupt cache entry.
        assertEquals(1, transport.getCalls)
        assertTrue(result is AuthResult.Authenticated)
    }

    @Test
    fun noCookieMeansNoCacheReadAndNoCacheWrite() {
        val transport = FakeTransport()
        val cache = object : AuthMeCache {
            var readAttempts = 0
            override fun read(cookieFingerprint: String): CachedAuthMe? {
                readAttempts += 1
                return null
            }

            override fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long) =
                error("must not cache without a cookie")

            override fun clear() = Unit
        }

        client(store = MemorySessionStore(null), transport = transport, cache = cache)
            .restoreSession()

        assertEquals(0, cache.readAttempts)
        assertEquals(1, transport.getCalls)
    }

    @Test
    fun loginInvalidatesThePreLoginVerdict() {
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-old"), AUTHENTICATED_BODY, clock)
        val transport = FakeTransport(
            response = AuthHttpResponse(
                statusCode = 200,
                body = AUTHENTICATED_BODY,
                setCookieHeaders = listOf("pabrik_session=tok-new; Path=/; HttpOnly"),
            ),
        )

        val result = client(
            store = MemorySessionStore(null),
            transport = transport,
            cache = cache,
        ).login("dev@example.com", "pw")

        assertTrue(result is AuthResult.Authenticated)
        assertEquals(1, cache.clears)
        assertTrue(cache.entries.isEmpty())
    }

    @Test
    fun logoutInvalidatesBeforeTheCookieDisappears() {
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)
        val store = MemorySessionStore("tok-a")

        client(store = store, transport = FakeTransport(), cache = cache).logout()

        assertEquals(1, cache.clears)
        assertTrue(cache.entries.isEmpty())
        assertNull(store.value)
    }

    @Test
    fun anOfflineDeviceWithAFreshEntryStillRestores() {
        // The actual win: a relaunch inside the TTL never touches the network, so airplane mode is indistinguishable from a warm start.
        val transport = FakeTransport(failure = IOException("offline"))
        val cache = FakeAuthMeCache()
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED_BODY, clock)

        val result = client(transport = transport, cache = cache).restoreSession()

        assertTrue(result is AuthResult.Authenticated)
        assertEquals(0, transport.getCalls)
    }

    @Test
    fun withoutACacheTheClientBehavesExactlyAsBefore() {
        val transport = FakeTransport()
        val result = client(transport = transport, cache = null).restoreSession()

        assertTrue(result is AuthResult.Authenticated)
        assertEquals(1, transport.getCalls)
    }

    private class FakeTransport(
        var response: AuthHttpResponse = AuthHttpResponse(
            statusCode = 200,
            body = AUTHENTICATED_BODY,
        ),
        var failure: Exception? = null,
    ) : AuthTransport {
        var getCalls = 0
        var postCalls = 0

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            postCalls += 1
            failure?.let { throw it }
            return response
        }

        override fun get(
            path: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            getCalls += 1
            failure?.let { throw it }
            return response
        }
    }

    private companion object {
        const val AUTHENTICATED_BODY =
            """{"authenticated":true,"auth_enabled":true,""" +
                """"user":{"id":"u1","email":"dev@example.com","name":"Dev","role":"member"}}"""
    }
}
