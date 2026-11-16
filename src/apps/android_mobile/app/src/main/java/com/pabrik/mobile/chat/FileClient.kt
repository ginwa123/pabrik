package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.server.requireUsableBaseUrl
import com.pabrik.mobile.http.BinaryHttpExchange
import com.pabrik.mobile.http.HttpsBinaryExchange
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.http.HttpRequestSpec
import java.net.HttpURLConnection

/** The outcome of asking the server for a presented file's bytes. */
sealed interface FileFetchResult {
    data class Loaded(
        val bytes: ByteArray,
        val mime: String,
    ) : FileFetchResult {
        // ByteArray again — see BinaryHttpResponseSpec for why.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Loaded) return false
            return mime == other.mime && bytes.contentEquals(other.bytes)
        }

        override fun hashCode(): Int = mime.hashCode() * 31 + bytes.contentHashCode()
    }

    /** The cookie is gone — the reader has to sign in again. */
    data object SignedOut : FileFetchResult

    /** The server said no, in words worth showing. */
    data class Rejected(val message: String) : FileFetchResult

    /** Offline, or the answer was not usable. */
    data class Unavailable(val message: String) : FileFetchResult
}

/** Fetches the bytes behind a `present_files` entry. */
class FileClient(
    private val sessionStore: SessionStore,
    private val baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    binaryTransport: BinaryHttpExchange? = null,
) {
    private val transport: BinaryHttpExchange =
        binaryTransport ?: HttpsBinaryExchange()

    fun fetch(sessionId: String, path: String): FileFetchResult {
        if (sessionId.isBlank() || path.isBlank()) {
            return FileFetchResult.Rejected("This file is not reachable from here.")
        }

        val cookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            null
        } ?: return FileFetchResult.SignedOut

        val headers = listOf(
            HttpHeader("Cookie", "${AuthConfig.SESSION_COOKIE_NAME}=$cookie"),
            // The endpoint serves whatever the file is; asking for JSON is how a viewer app ends up handed a parse error instead of a PDF.
            HttpHeader("Accept", "*/*"),
        )

        val response = try {
            // Same per-call resolution as every other transport in the app: a file card is a long-lived composable, and a host captured when it was first composed would …
            val baseUrl = requireUsableBaseUrl(baseUrlProvider())
            transport.execute(
                HttpRequestSpec(
                    method = "GET",
                    url = PresentFiles.downloadUrl(
                        baseUrl = baseUrl,
                        sessionId = sessionId,
                        path = path,
                        inline = true,
                    ),
                    headers = headers,
                ),
            )
        } catch (_: Exception) {
            return FileFetchResult.Unavailable(
                "Could not reach ${AuthConfig.BASE_URL}. Check your connection.",
            )
        }

        return interpret(response.statusCode, response.contentType, response.body)
    }

    /** The one place a status code becomes a verdict. */
    private fun interpret(statusCode: Int, contentType: String, bytes: ByteArray): FileFetchResult {
        if (statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) return FileFetchResult.SignedOut
        if (statusCode == HttpURLConnection.HTTP_FORBIDDEN) {
            return FileFetchResult.Rejected("This file is outside the chat's working folder.")
        }
        if (statusCode == HttpURLConnection.HTTP_NOT_FOUND) {
            return FileFetchResult.Rejected("That file is no longer there.")
        }
        if (statusCode == HttpURLConnection.HTTP_ENTITY_TOO_LARGE) {
            return FileFetchResult.Rejected("That file is too big to open on the phone.")
        }
        if (statusCode in 400..499) {
            return FileFetchResult.Rejected("This file could not be opened.")
        }
        if (statusCode !in 200..299) {
            return FileFetchResult.Unavailable("The server could not load this file. Try again.")
        }
        if (bytes.isEmpty()) {
            return FileFetchResult.Rejected("That file came back empty.")
        }
        return FileFetchResult.Loaded(bytes = bytes, mime = contentType)
    }
}
