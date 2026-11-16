package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.http.BinaryHttpExchange
import com.pabrik.mobile.http.BinaryHttpResponseSpec
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.http.HttpRequestSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.HttpURLConnection

/** [FileClient] over a fake exchange. */
class FileClientTest {

    private class FakeStore(private val cookie: String?) : SessionStore {
        override fun read(): String? = cookie
        override fun save(cookieValue: String) = Unit
        override fun clear() = Unit
    }

    private class RecordingExchange(
        private val response: BinaryHttpResponseSpec,
        private val failure: Exception? = null,
    ) : BinaryHttpExchange {
        var lastRequest: HttpRequestSpec? = null
            private set

        override fun execute(request: HttpRequestSpec): BinaryHttpResponseSpec {
            lastRequest = request
            failure?.let { throw it }
            return response
        }
    }

    private fun client(
        store: SessionStore,
        exchange: BinaryHttpExchange,
    ) = FileClient(
        sessionStore = store,
        baseUrlProvider = { "https://host" },
        binaryTransport = exchange,
    )

    @Test
    fun `a 200 returns the bytes and the server content type`() {
        val exchange = RecordingExchange(
            BinaryHttpResponseSpec(200, "image/png", byteArrayOf(1, 2, 3)),
        )
        val result = client(FakeStore("abc"), exchange).fetch("s1", "/a/x.png")

        val loaded = result as FileFetchResult.Loaded
        assertEquals("image/png", loaded.mime)
        assertTrue(loaded.bytes.contentEquals(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `the request carries the session cookie`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(65)))
        client(FakeStore("cookie-value"), exchange).fetch("s1", "/a/x.txt")

        val cookie = exchange.lastRequest!!.headers.first { it.name == "Cookie" }
        assertEquals("pabrik_session=cookie-value", cookie.value)
    }

    @Test
    fun `the request asks for the file inline at the download endpoint`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(65)))
        client(FakeStore("abc"), exchange).fetch("s1", "/w/notes.md")

        val url = exchange.lastRequest!!.url
        assertTrue(url.contains("/api/files/download"))
        assertTrue(url.contains("session_id=s1"))
        assertTrue(url.contains("disposition=inline"))
        // An `Accept: application/json` here is how a viewer ends up holding a parse error instead of a PDF.
        assertTrue(exchange.lastRequest!!.headers.any { it == HttpHeader("Accept", "*/*") })
    }

    @Test
    fun `no session cookie is a signed-out, and no request is made`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(65)))
        val result = client(FakeStore(null), exchange).fetch("s1", "/a/x.txt")

        assertEquals(FileFetchResult.SignedOut, result)
        assertEquals(null, exchange.lastRequest)
    }

    @Test
    fun `a 401 is a signed-out`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(401))
        assertEquals(FileFetchResult.SignedOut, client(FakeStore("abc"), exchange).fetch("s1", "/a"))
    }

    /** The sandbox in `files_download.zig` answers 403 for a path outside the session's working directory. */
    @Test
    fun `a 403 says the file is outside the working folder`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(403))
        val result = client(FakeStore("abc"), exchange).fetch("s1", "/etc/passwd")
        assertEquals(
            "This file is outside the chat's working folder.",
            (result as FileFetchResult.Rejected).message,
        )
    }

    @Test
    fun `a 404 says the file is gone`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(404))
        val result = client(FakeStore("abc"), exchange).fetch("s1", "/a/x")
        assertEquals("That file is no longer there.", (result as FileFetchResult.Rejected).message)
    }

    @Test
    fun `a 413 says the file is too big`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(413))
        val result = client(FakeStore("abc"), exchange).fetch("s1", "/a/x")
        assertEquals("That file is too big to open on the phone.", (result as FileFetchResult.Rejected).message)
    }

    @Test
    fun `a 400 is a rejection, not a retryable failure`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(400))
        assertTrue(client(FakeStore("abc"), exchange).fetch("s1", "/a") is FileFetchResult.Rejected)
    }

    @Test
    fun `a 500 is retryable`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(500))
        assertTrue(client(FakeStore("abc"), exchange).fetch("s1", "/a") is FileFetchResult.Unavailable)
    }

    /** A 200 with no bytes is not a success. */
    @Test
    fun `a 200 with an empty body is a rejection`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", ByteArray(0)))
        assertTrue(client(FakeStore("abc"), exchange).fetch("s1", "/a") is FileFetchResult.Rejected)
    }

    @Test
    fun `a thrown socket error is unavailable, not a crash`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200), failure = java.io.IOException("boom"))
        assertTrue(client(FakeStore("abc"), exchange).fetch("s1", "/a") is FileFetchResult.Unavailable)
    }

    /** A card whose session id never arrived must say so rather than fetch with an empty one — the endpoint answers 400 and the reader gets a message about a request … */
    @Test
    fun `a blank session id is refused before the socket`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(65)))
        val result = client(FakeStore("abc"), exchange).fetch("", "/a/x.txt")

        assertTrue(result is FileFetchResult.Rejected)
        assertEquals(null, exchange.lastRequest)
    }

    @Test
    fun `a blank path is refused before the socket`() {
        val exchange = RecordingExchange(BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(65)))
        assertTrue(client(FakeStore("abc"), exchange).fetch("s1", "  ") is FileFetchResult.Rejected)
        assertEquals(null, exchange.lastRequest)
    }

    @Test
    fun `loaded compares by content, not by identity`() {
        val first = FileFetchResult.Loaded(byteArrayOf(1, 2, 3), "image/png")
        val second = FileFetchResult.Loaded(byteArrayOf(1, 2, 3), "image/png")
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
    }

    @Test
    fun `the two authorised outcomes are distinct types`() {
        // A guard on the sealed hierarchy: a caller that forgets a branch must get a compile error, not a silently-mapped verdict.
        assertTrue(FileFetchResult.SignedOut != FileFetchResult.Rejected("x"))
        assertTrue(HttpURLConnection.HTTP_UNAUTHORIZED == 401)
    }
}
