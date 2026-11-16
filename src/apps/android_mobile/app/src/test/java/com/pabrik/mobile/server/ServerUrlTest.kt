package com.pabrik.mobile.server

import com.pabrik.mobile.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rule a person typing a hostname is held to. */
class ServerUrlTest {

    private fun applied(raw: String): String {
        val change = normalizeBaseUrl(raw)
        assertTrue(
            "`$raw` should have been accepted, got $change",
            change is ServerChange.Applied,
        )
        return (change as ServerChange.Applied).baseUrl
    }

    private fun rejected(raw: String): String {
        val change = normalizeBaseUrl(raw)
        assertTrue(
            "`$raw` should have been refused, got $change",
            change is ServerChange.Rejected,
        )
        return (change as ServerChange.Rejected).reason
    }

    // ─── the shapes that must work ─────────────────────────────────────────

    @Test
    fun `a bare hostname gets the secure scheme`() {
        // The common case by far.
        assertEquals("https://pabrik.example.com", applied("pabrik.example.com"))
    }

    @Test
    fun `surrounding whitespace is not a person typing a host`() {
        assertEquals("https://pabrik.example.com", applied("  pabrik.example.com  "))
    }

    @Test
    fun `a port is kept, because a self-hoster runs on 8080`() {
        assertEquals("https://pabrik.example.com:8080", applied("pabrik.example.com:8080"))
        assertEquals(
            "https://pabrik.example.com:8443",
            applied("https://pabrik.example.com:8443"),
        )
    }

    @Test
    fun `a path prefix is kept, because a reverse proxy puts pabrik under one`() {
        assertEquals("https://example.com/pabrik", applied("https://example.com/pabrik/"))
    }

    @Test
    fun `scheme and host are lowercased so two spellings are one server`() {
        // `https://Pabrik.Example.COM` and `https://pabrik.example.com` are the same host, and a store that treated them as two would refuse to switch back to the one …
        assertEquals("https://pabrik.example.com", applied("HTTPS://Pabrik.Example.COM"))
    }

    @Test
    fun `a trailing slash is dropped so a path can be appended`() {
        // The join in every transport is `"$baseUrl$path"`.
        assertEquals("https://pabrik.example.com", applied("https://pabrik.example.com/"))
        assertEquals("https://pabrik.example.com", applied("https://pabrik.example.com///"))
    }

    // ─── the shapes that must not ──────────────────────────────────────────

    @Test
    fun `an empty field says so instead of guessing`() {
        assertEquals("Enter your server address.", rejected(""))
        assertEquals("Enter your server address.", rejected("   "))
    }

    @Test
    fun `a scheme this client cannot open names the two it can`() {
        // The same sentence the transport throws with, so the field and the socket never disagree about the rule.
        for (raw in listOf("ftp://pabrik.example.com", "file:///etc/hosts", "ws://x.example")) {
            assertTrue(
                "`$raw` should name the rule: ${rejected(raw)}",
                rejected(raw).contains("HTTP or HTTPS"),
            )
        }
    }

    @Test
    fun `credentials in the address are refused`() {
        // The reader sees the host in the row above the field and not the `user:pass@` in front of it.
        assertTrue(
            rejected("https://user:pass@pabrik.example.com")
                .contains("username and password"),
        )
    }

    @Test
    fun `a query or fragment is refused, naming which part`() {
        // Both would silently disappear when a path is appended, and the first is the shape of a link that points somewhere other than it looks.
        assertTrue(rejected("https://pabrik.example.com?next=/evil").contains("?query"))
        assertTrue(rejected("https://pabrik.example.com#x").contains("?query"))
    }

    @Test
    fun `a host the parser cannot read is refused without a stack trace`() {
        // Two different failures, two different sentences.
        assertTrue(rejected("https://not a host").contains("not a server address"))
        assertTrue(rejected("https://exa_mple.com").contains("domain"))
    }

    // ─── the cleartext policy ──────────────────────────────────────────────

    @Test
    fun `cleartext is refused for every host except the ones the debug config permits`() {
        // This is the invariant the whole file exists to protect, and it is asserted in BOTH variants on purpose.
        if (!BuildConfig.ALLOW_INSECURE_HTTP) {
            for (host in listOf("10.0.2.2", "localhost", "127.0.0.1")) {
                assertTrue(
                    "release must refuse cleartext even to $host",
                    rejected("http://$host:8080").contains("HTTPS only"),
                )
            }
            return
        }

        for (host in listOf("10.0.2.2", "localhost", "127.0.0.1")) {
            assertEquals("http://$host:8080", applied("http://$host:8080"))
        }
        assertTrue(
            "cleartext to a host the platform would refuse must not be accepted",
            rejected("http://pabrik.example.com").contains("Plain HTTP"),
        )
    }

    @Test
    fun `the permitted cleartext hosts are the ones the debug config grants`() {
        // The set, not a boolean, and the set is the same three addresses.
        val expected = if (BuildConfig.ALLOW_INSECURE_HTTP) LOOPBACK_HOSTS else emptySet()
        assertEquals(expected, CLEAR_TEXT_HOSTS)
    }

    // ─── the transport's copy of the same rule ─────────────────────────────

    @Test
    fun `the transport guard returns the normalized url or throws with the sentence`() {
        assertEquals(
            "https://pabrik.example.com",
            requireUsableBaseUrl("pabrik.example.com/"),
        )

        val thrown = runCatching { requireUsableBaseUrl("ftp://pabrik.example.com") }
            .exceptionOrNull()
        assertTrue(
            "the guard must throw rather than return a bad host: $thrown",
            thrown is IllegalArgumentException,
        )
        assertTrue(thrown!!.message.orEmpty().contains("HTTP or HTTPS"))
    }
}
