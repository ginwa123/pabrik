package com.pabrik.mobile.worker

import org.json.JSONObject
import java.net.URLEncoder

/** The agentic loop's run state: which sessions currently have a live worker. */
object WorkerApi {
    /** The server's own default, kept explicit so the URL is legible in the network inspector. */
    const val WORKERS_PAGE_LIMIT = 50

    fun workersPath(limit: Int = WORKERS_PAGE_LIMIT): String =
        "/api/workers?limit=$limit"

    /** The same list narrowed to one session. */
    fun workersPathForSession(sessionId: String): String =
        "/api/workers?session_id=${encodeQueryValue(sessionId)}&limit=1"

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /** Projects the workers envelope down to the ids that mean "busy". */
    fun parseRunningSessionIds(body: String): Set<String>? {
        val workers = JSONObject(body).optJSONArray("workers") ?: return null
        val ids = LinkedHashSet<String>(workers.length())
        for (index in 0 until workers.length()) {
            val row = workers.optJSONObject(index) ?: continue
            val sessionId = row.optStringOrEmpty("session_id")
                .ifEmpty { row.optStringOrEmpty("id") }
            if (sessionId.isNotEmpty()) ids += sessionId
        }
        return ids
    }

    private fun JSONObject.optStringOrEmpty(name: String): String {
        if (!has(name) || isNull(name)) return ""
        return optString(name).takeIf { it != "null" }.orEmpty()
    }
}
