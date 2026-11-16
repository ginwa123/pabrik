package com.pabrik.mobile.http

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

/** A response body as bytes, plus the header line the caller needs to make a decision about them. */
data class BinaryHttpResponseSpec(
    val statusCode: Int,
    val contentType: String = "",
    val body: ByteArray = ByteArray(0),
) {
    // data class + ByteArray is the one combination where the generated equals/hashCode compare identity, which makes a test that asserts on a fetched body pass or …
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BinaryHttpResponseSpec) return false
        return statusCode == other.statusCode &&
            contentType == other.contentType &&
            body.contentEquals(other.body)
    }

    override fun hashCode(): Int =
        (statusCode * 31 + contentType.hashCode()) * 31 + body.contentHashCode()
}

/** Seam for a binary fetch, so a preview can be tested without opening a socket. */
fun interface BinaryHttpExchange {
    fun execute(request: HttpRequestSpec): BinaryHttpResponseSpec
}

/** The binary sibling of [HttpsHttpExchange] — same connection settings, same "one call site" promise, one extra job: it does not decode. */
class HttpsBinaryExchange(
    private val connectTimeoutMillis: Int = HttpsHttpExchange.DEFAULT_TIMEOUT_MILLIS,
    private val readTimeoutMillis: Int = HttpsHttpExchange.DEFAULT_TIMEOUT_MILLIS,
    private val maxBytes: Int = DEFAULT_MAX_BYTES,
) : BinaryHttpExchange {

    override fun execute(request: HttpRequestSpec): BinaryHttpResponseSpec {
        // The same opener the JSON exchange uses, so "may this build speak plain HTTP" is decided in exactly one place and a file download can never disagree with an API …
        val connection = HttpsHttpExchange.openFor(request.url)

        try {
            connection.requestMethod = request.method
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty(HttpsHttpExchange.ACCEPT_HEADER, HttpsHttpExchange.DEFAULT_ACCEPT)
            request.headers.forEach { header ->
                connection.setRequestProperty(header.name, header.value)
            }

            if (request.body != null) {
                val bodyBytes = request.body.toByteArray(Charsets.UTF_8)
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bodyBytes.size)
                connection.outputStream.use { it.write(bodyBytes) }
            }

            val statusCode = connection.responseCode
            val stream = if (statusCode in 200..299) connection.inputStream else connection.errorStream

            return BinaryHttpResponseSpec(
                statusCode = statusCode,
                contentType = connection.contentType.orEmpty(),
                body = stream.readBytesCapped(maxBytes),
            )
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        /** Matches `MAX_DOWNLOAD_BYTES` in `src/http_handlers/files_download.zig` (50 MiB). */
        const val DEFAULT_MAX_BYTES = 50 * 1024 * 1024
    }
}

/** Read at most [maxBytes]; throw when there is more. */
internal fun InputStream?.readBytesCapped(maxBytes: Int): ByteArray {
    if (this == null) return ByteArray(0)
    return use { stream ->
        val buffer = ByteArray(READ_CHUNK_BYTES)
        val out = ByteArrayOutputStream()
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            if (out.size() + read > maxBytes) throw IOException("Response exceeded $maxBytes bytes")
            out.write(buffer, 0, read)
        }
        out.toByteArray()
    }
}

private const val READ_CHUNK_BYTES = 16 * 1024

// The timeout and Accept defaults come from HttpsHttpExchange's companion rather than being restated here: RecordingAuthTransport already rewrites the recorded …
