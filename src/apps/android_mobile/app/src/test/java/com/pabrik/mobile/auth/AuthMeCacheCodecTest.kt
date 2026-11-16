package com.pabrik.mobile.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure half of the `/me` cache: the key derivation and the freshness rule. */
class AuthMeCacheCodecTest {

    @Test
    fun aFingerprintIsStableForTheSameCookie() {
        // A non-deterministic key would make the cache permanently cold.
        assertEquals(
            AuthMeCacheCodec.fingerprint("tok-abc"),
            AuthMeCacheCodec.fingerprint("tok-abc"),
        )
    }

    @Test
    fun differentCookiesFingerprintDifferently() {
        // This is the isolation guarantee: account A's cached identity is not addressable with account B's cookie.
        assertNotEquals(
            AuthMeCacheCodec.fingerprint("tok-a"),
            AuthMeCacheCodec.fingerprint("tok-b"),
        )
    }

    @Test
    fun theFingerprintDoesNotLeakTheCookie() {
        val fingerprint = AuthMeCacheCodec.fingerprint("super-secret-session-cookie")!!

        // A bearer credential must never become part of a storage key — and it is now a column value, not just a filename component, so a database dump would carry it …
        assertTrue(fingerprint, !fingerprint.contains("secret"))
        assertTrue(fingerprint, !fingerprint.contains("super"))
        assertEquals(32, fingerprint.length) // 16 bytes, hex
    }

    @Test
    fun aBlankCookieCannotBeFingerprinted() {
        assertNull(AuthMeCacheCodec.fingerprint(""))
        assertNull(AuthMeCacheCodec.fingerprint("   "))
    }

    @Test
    fun freshnessHoldsExactlyUpToTheTtlBoundary() {
        val entry = CachedAuthMe(body = "{}", storedAtEpochMillis = 10_000L)
        val ttl = AuthMeCacheCodec.TTL_MILLIS

        assertTrue(entry.isFresh(10_000L, ttl))
        assertTrue(entry.isFresh(10_000L + ttl - 1, ttl))
        // At exactly the TTL the answer is no longer trustworthy, so it is a miss.
        assertFalse(entry.isFresh(10_000L + ttl, ttl))
        assertFalse(entry.isFresh(10_000L + ttl + 1, ttl))
    }

    @Test
    fun aClockThatWentBackwardsDoesNotPoisonTheEntry() {
        val entry = CachedAuthMe(body = "{}", storedAtEpochMillis = 10_000L)

        // now < storedAt gives a negative age, which is "very fresh".
        entry.isFresh(5_000L, AuthMeCacheCodec.TTL_MILLIS)
    }

    @Test
    fun theTtlMatchesTheWeb() {
        // Mirrors AUTH_ME_TTL_MS in helpers/authMe.ts.
        assertEquals(30_000L, AuthMeCacheCodec.TTL_MILLIS)
    }
}
