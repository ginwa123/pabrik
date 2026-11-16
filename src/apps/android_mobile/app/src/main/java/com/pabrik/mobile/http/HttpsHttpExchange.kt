package com.pabrik.mobile.http

import com.pabrik.mobile.BuildConfig
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import javax.net.ssl.HttpsURLConnection

/** The app's single HTTPS call site. */
class HttpsHttpExchange(
    private val connectTimeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
    private val readTimeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
) : HttpExchange {
    override fun execute(request: HttpRequestSpec): HttpResponseSpec {
        val connection = openFor(request.url)

        try {
            connection.requestMethod = request.method
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty(ACCEPT_HEADER, DEFAULT_ACCEPT)
            request.headers.forEach { header ->
                connection.setRequestProperty(header.name, header.value)
            }

            if (request.body != null) {
                val bodyBytes = request.body.toByteArray(StandardCharsets.UTF_8)
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bodyBytes.size)
                connection.outputStream.use { it.write(bodyBytes) }
            }

            val statusCode = connection.responseCode
            val responseStream = if (statusCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }

            return HttpResponseSpec(
                statusCode = statusCode,
                headers = connection.readResponseHeaders(),
                body = responseStream.readUtf8OrEmpty(),
            )
        } finally {
            connection.disconnect()
        }
    }

    /** `getHeaderFields()` keys the status line under a null name; drop it so only real headers survive. */
    private fun HttpURLConnection.readResponseHeaders(): List<HttpHeader> =
        headerFields.entries.flatMap { (name, values) ->
            if (name == null) {
                emptyList()
            } else {
                values.orEmpty().map { value -> HttpHeader(name, value) }
            }
        }

    private fun InputStream?.readUtf8OrEmpty(): String =
        this?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() } ?: ""

    companion object {
        const val DEFAULT_TIMEOUT_MILLIS = 15_000
        const val ACCEPT_HEADER = "Accept"
        const val DEFAULT_ACCEPT = "application/json"

        /** Opens [url], enforcing HTTPS unless this build has opted out. */
        internal fun openFor(url: String): HttpURLConnection {
            val opened = URL(url).openConnection()
            if (opened is HttpsURLConnection) return opened
            if (!BuildConfig.ALLOW_INSECURE_HTTP) {
                throw IOException("Request did not open an HTTPS connection")
            }
            return opened as? HttpURLConnection
                ?: throw IOException("Request did not open an HTTP connection")
        }
    }
}
