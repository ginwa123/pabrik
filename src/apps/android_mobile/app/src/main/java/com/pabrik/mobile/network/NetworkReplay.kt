package com.pabrik.mobile.network

import com.pabrik.mobile.http.HttpExchange
import com.pabrik.mobile.http.HttpRequestSpec
import com.pabrik.mobile.http.HttpsHttpExchange

/** Re-sends a captured call exactly as recorded, so "why did that POST fail?" can be answered by running it again instead of guessing. */
fun replayNetworkEntry(
    entry: NetworkLogEntry,
    store: NetworkLogStore = NetworkLogStore.default,
    exchange: HttpExchange = HttpsHttpExchange(),
    nowMillis: () -> Long = System::currentTimeMillis,
    nanoTime: () -> Long = System::nanoTime,
): NetworkLogEntry? {
    val startedAt = nowMillis()
    val startedNanos = nanoTime()
    val clippedRequest = clipBody(entry.requestBody)

    val buildEntry: (Long) -> NetworkLogEntry = { id ->
        NetworkLogEntry(
            id = id,
            label = "Replay · ${entry.label}",
            method = entry.method,
            url = entry.url,
            requestHeaders = entry.requestHeaders,
            requestBody = clippedRequest.first,
            requestBodyBytes = entry.requestBodyBytes,
            requestBodyTruncated = entry.requestBodyTruncated,
            startedAtEpochMillis = startedAt,
            durationMillis = elapsedMillis(startedNanos, nanoTime),
            isReplay = true,
        )
    }

    return try {
        val response = exchange.execute(
            HttpRequestSpec(
                method = entry.method,
                url = entry.url,
                headers = entry.requestHeaders,
                body = entry.requestBody,
            ),
        )
        val clippedResponse = clipBody(response.body)
        store.record { id ->
            buildEntry(id).copy(
                statusCode = response.statusCode,
                responseHeaders = response.headers,
                responseBody = clippedResponse.first,
                responseBodyBytes = response.body?.length ?: 0,
                responseBodyTruncated = clippedResponse.second,
            )
        }
    } catch (error: Exception) {
        store.record { id ->
            buildEntry(id).copy(
                statusCode = null,
                responseHeaders = emptyList(),
                errorMessage = error.describeForInspector(),
            )
        }
    }
}

private fun elapsedMillis(startedNanos: Long, nanoTime: () -> Long): Long =
    ((nanoTime() - startedNanos) / 1_000_000L).coerceAtLeast(0L)
