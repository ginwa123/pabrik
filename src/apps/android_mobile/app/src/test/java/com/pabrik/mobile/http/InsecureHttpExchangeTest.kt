package com.pabrik.mobile.http

import com.pabrik.mobile.BuildConfig
import com.pabrik.mobile.auth.HttpsAuthTransport
import java.io.BufferedReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.HttpsURLConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The debug build's one deliberate hole, driven against a real socket. */
class InsecureHttpExchangeTest {

    private lateinit var server: ServerSocket
    private val accepted = CopyOnWriteArrayList<Socket>()

    /** The request lines the stub was actually handed. */
    private val requestLines = CopyOnWriteArrayList<String>()

    @Before
    fun startServer() {
        server = ServerSocket(0)
        Thread {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: Exception) {
                    return@Thread
                }
                accepted += socket
                Thread {
                    try {
                        // Read the request head so the client's write completes.
                        val reader: BufferedReader = socket.getInputStream().bufferedReader()
                        var line = reader.readLine()
                        if (line != null) requestLines += line
                        while (line != null && line.isNotEmpty()) line = reader.readLine()
                        val body = """{"ok":true}"""
                        val head = buildString {
                            append("HTTP/1.1 200 OK\r\n")
                            append("Content-Type: application/json\r\n")
                            append("Content-Length: ${body.toByteArray().size}\r\n")
                            append("Connection: close\r\n\r\n")
                        }
                        socket.getOutputStream().write((head + body).toByteArray())
                        socket.getOutputStream().flush()
                        // Close, so the body is bounded twice over: the client can stop at Content-Length and EOF is unambiguous.
                        socket.close()
                    } catch (_: Exception) {
                        // The client hung up; nothing to do.
                    }
                }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    @After
    fun stopServer() {
        runCatching { accepted.forEach { it.close() } }
        runCatching { server.close() }
    }

    private fun baseUrl() = "http://127.0.0.1:${server.localPort}"

    // ─── the guard, on the request path ────────────────────────────────────

    /** Fails the first request to [url], and returns what refused it. */
    private fun refusalFor(url: String): IllegalArgumentException =
        assertThrows(
            "$url must be refused",
            IllegalArgumentException::class.java,
        ) {
            HttpsAuthTransport { url }.get(path = "/api/auth/me", headers = emptyMap())
        }

    @Test
    fun `the debug build accepts a plain-http base url`() {
        assertTrue(
            "this test only means something where the seam is armed",
            BuildConfig.ALLOW_INSECURE_HTTP,
        )

        // 127.0.0.1 is one of the three hosts the debug `network_security_config.xml` grants cleartext to, so the request goes out over plain HTTP and the scheme rule …
        val response = HttpsAuthTransport { baseUrl() }
            .get(path = "/api/auth/me", headers = emptyMap())

        // A round trip, not a construction: the scheme rule now lives on the request path, so the only proof that it let this through is a server answering.
        assertEquals(200, response.statusCode)
    }

    @Test
    fun `a scheme that is neither http nor https is still refused`() {
        val thrown = refusalFor("ftp://127.0.0.1:${server.localPort}")

        assertTrue(
            "the failure has to name the rule it broke, not just 'invalid': ${thrown.message}",
            thrown.message.orEmpty().contains("HTTP or HTTPS"),
        )
    }

    @Test
    fun `a trailing slash does not change the decision`() {
        // The normalisation happens before the guard, so this pins the order
        HttpsAuthTransport { "${baseUrl()}/" }
            .get(path = "/api/auth/me", headers = emptyMap())

        assertTrue(
            "a doubled slash reached the server: $requestLines",
            requestLines.any { it == "GET /api/auth/me HTTP/1.1" },
        )
    }

    // ─── the two exchanges ─────────────────────────────────────────────────

    @Test
    fun `a plain-http request round-trips through the json exchange`() {
        val response = HttpsHttpExchange().execute(
            HttpRequestSpec(method = "GET", url = "${baseUrl()}/api/auth/me"),
        )

        assertEquals(200, response.statusCode)
        assertTrue("body was ${response.body}", response.body.orEmpty().contains("\"ok\":true"))
        assertEquals(1, accepted.size)
    }

    @Test
    fun `a plain-http request round-trips through the binary exchange`() {
        // The file path is a separate class with its own copy of the decision, and it is the one that downloads bytes rather than JSON — so it gets its own round trip …
        val response = HttpsBinaryExchange().execute(
            HttpRequestSpec(method = "GET", url = "${baseUrl()}/api/files/download?path=/a.txt"),
        )

        assertEquals(200, response.statusCode)
        assertTrue(
            "content type was '${response.contentType}'",
            response.contentType.startsWith("application/json"),
        )
        assertTrue(String(response.body), String(response.body).contains("\"ok\":true"))
    }

    // ─── the part that must not have changed ───────────────────────────────

    @Test
    fun `an https url still opens a tls connection`() {
        // The relaxation must not have replaced the TLS path with a plain one.
        val opened = HttpsHttpExchange.openFor("https://agent.ginwa.site/api/auth/me")

        assertTrue(
            "https must still yield a TLS connection, got ${opened::class.java.name}",
            opened is HttpsURLConnection,
        )
    }
}
