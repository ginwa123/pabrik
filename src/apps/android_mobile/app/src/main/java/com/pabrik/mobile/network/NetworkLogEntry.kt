package com.pabrik.mobile.network

import com.pabrik.mobile.http.HttpHeader
import java.net.URI

val MutationMethods = setOf("POST", "PUT", "PATCH", "DELETE")

enum class NetworkOutcome {
    Responded,
    Failed,
}

/** One captured request/response pair, the unit the inspector list renders and the unit "copy as cURL"/"replay" rebuild a call from. */
data class NetworkLogEntry(
    val id: Long,
    val label: String,
    val method: String,
    val url: String,
    val requestHeaders: List<HttpHeader> = emptyList(),
    val requestBody: String? = null,
    val requestBodyBytes: Int = 0,
    val requestBodyTruncated: Boolean = false,
    val statusCode: Int? = null,
    val responseHeaders: List<HttpHeader> = emptyList(),
    val responseBody: String? = null,
    val responseBodyBytes: Int = 0,
    val responseBodyTruncated: Boolean = false,
    val errorMessage: String? = null,
    val startedAtEpochMillis: Long,
    val durationMillis: Long,
    val isReplay: Boolean = false,
) {
    private val parsedUri: URI? by lazy(LazyThreadSafetyMode.PUBLICATION) {
        runCatching { URI(url) }.getOrNull()
    }

    val outcome: NetworkOutcome
        get() = if (statusCode == null) NetworkOutcome.Failed else NetworkOutcome.Responded

    val isFailure: Boolean
        get() = statusCode == null || statusCode >= 400

    val isMutation: Boolean
        get() = method.uppercase() in MutationMethods

    val host: String
        get() = parsedUri?.host?.takeIf { it.isNotBlank() } ?: url

    val path: String
        get() = parsedUri?.path?.takeIf { it.isNotBlank() } ?: url

    val query: String?
        get() = parsedUri?.query?.takeIf { it.isNotBlank() }

    val displayPath: String
        get() = query?.let { "$path?$it" } ?: path

    val statusLabel: String
        get() = statusCode?.toString() ?: "ERR"

    val totalBytes: Int
        get() = requestBodyBytes + responseBodyBytes

    /** Drives the "includes live credentials" warning before a copy or a replay. */
    val containsSecrets: Boolean
        get() = requestHeaders.any { header -> isSensitiveHeaderName(header.name) } ||
            responseHeaders.any { header -> isSensitiveHeaderName(header.name) } ||
            containsSecretField(requestBody) ||
            containsSecretField(responseBody) ||
            containsSecretQueryParam(query)
}
