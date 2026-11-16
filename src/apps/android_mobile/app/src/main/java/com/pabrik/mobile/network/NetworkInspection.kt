package com.pabrik.mobile.network

import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.recents.formatRelativeTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

const val RedactedPlaceholder = "••••••••"

enum class NetworkEntryFilter {
    All,
    Mutations,
    Failed,
}

enum class NetworkStatusClass {
    Success,
    Redirect,
    ClientError,
    ServerError,
    Failure,
}

data class NetworkSummary(
    val requestCount: Int,
    val failedCount: Int,
    val totalBytes: Int,
    val slowestMillis: Long,
)

/** Header names whose value is a credential. */
val SensitiveHeaderNames: Set<String> = setOf(
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "x-auth-token",
    "x-session-token",
    "x-csrf-token",
    "x-amz-security-token",
    "x-amz-credential",
)

/** Field names that carry a secret in a JSON or form body. */
val SensitiveFieldNames: Set<String> = setOf(
    "password",
    "passwd",
    "secret",
    "token",
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "apikey",
    "auth",
    "authorization",
    "credential",
    "credentials",
    "session",
    "session_id",
    "private_key",
    "client_secret",
    "otp",
    "pin",
)

/** Suffixes catch vendor spellings (`stripe_signature`, `imap_password`) that an exact-name list cannot. */
val SensitiveFieldSuffixes: List<String> = listOf(
    "_token",
    "_secret",
    "_password",
    "_api_key",
    "_access_key",
    "_private_key",
    "_credential",
    "_signature",
    "_code",
    "-token",
    "-secret",
    "-password",
)

private val JsonFieldPattern = Regex("\"([^\"]+)\"(\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|[^,}\\]\\s]*)")
private val FormFieldPattern = Regex(
    "([A-Za-z0-9_%.\\-]+)=([^&;\\s]*)",
)
private val LineBreakPattern = Regex("[\\r\\n]+")

private val ClockFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss", Locale.US)

fun isSensitiveHeaderName(name: String): Boolean =
    SensitiveHeaderNames.contains(name.trim().lowercase())

fun isSensitiveFieldName(name: String): Boolean {
    val normalized = name.trim().lowercase()
    if (normalized in SensitiveFieldNames) return true
    return SensitiveFieldSuffixes.any { suffix -> normalized.endsWith(suffix) }
}

fun redactHeaders(headers: List<HttpHeader>): List<HttpHeader> =
    headers.map { header ->
        if (isSensitiveHeaderName(header.name)) {
            header.copy(value = RedactedPlaceholder)
        } else {
            header
        }
    }

/** Hides secret query values (`?token=…`) so a screenshot of the URL line is safe. */
fun redactUrl(url: String): String {
    val queryStart = url.indexOf('?')
    if (queryStart < 0) return url

    val base = url.substring(0, queryStart)
    val query = url.substring(queryStart + 1)
    val redacted = query.split('&').joinToString("&") { pair ->
        val separator = pair.indexOf('=')
        if (separator < 0) {
            pair
        } else {
            val name = pair.substring(0, separator)
            if (isSensitiveFieldName(name)) "$name=$RedactedPlaceholder" else pair
        }
    }
    return "$base?$redacted"
}

fun redactBody(body: String?): String? {
    if (body.isNullOrEmpty()) return body

    val jsonRedacted = JsonFieldPattern.replace(body) { match ->
        val name = match.groupValues[1]
        val separator = match.groupValues[2]
        if (isSensitiveFieldName(name)) {
            "\"$name\"$separator\"$RedactedPlaceholder\""
        } else {
            match.value
        }
    }

    return FormFieldPattern.replace(jsonRedacted) { match ->
        val name = match.groupValues[1]
        if (isSensitiveFieldName(name)) {
            "$name=$RedactedPlaceholder"
        } else {
            match.value
        }
    }
}

/** The read-only view of a record that the UI shows while "reveal secrets" is off. */
fun redactedHeadersOf(entry: NetworkLogEntry, request: Boolean): List<HttpHeader> =
    redactHeaders(if (request) entry.requestHeaders else entry.responseHeaders)

fun redactedBodyOf(entry: NetworkLogEntry, request: Boolean): String? =
    redactBody(if (request) entry.requestBody else entry.responseBody)

fun containsSecretField(body: String?): Boolean {
    if (body.isNullOrEmpty()) return false
    if (JsonFieldPattern.findAll(body).any { match -> isSensitiveFieldName(match.groupValues[1]) }) {
        return true
    }
    return FormFieldPattern.findAll(body).any { match -> isSensitiveFieldName(match.groupValues[1]) }
}

fun containsSecretQueryParam(query: String?): Boolean {
    if (query.isNullOrBlank()) return false
    return query.split('&').any { pair ->
        val name = pair.substringBefore('=')
        isSensitiveFieldName(name)
    }
}

/** Rebuilds the call as a runnable shell command, with the real values — a curl with `••••••••` in it does not reproduce anything, which is the whole point of the … */
fun buildCurlCommand(entry: NetworkLogEntry): String {
    val parts = mutableListOf("curl", "-X", entry.method.uppercase(), shellQuote(entry.url))
    entry.requestHeaders.forEach { header ->
        parts += "-H"
        parts += shellQuote("${header.name}: ${header.value}")
    }
    entry.requestBody
        ?.takeIf { body -> body.isNotEmpty() }
        ?.let { body ->
            parts += "--data-raw"
            parts += shellQuote(body)
        }
    return parts.joinToString(" ")
}

/** POSIX single-quote wrapping. */
fun shellQuote(value: String): String {
    val sanitized = LineBreakPattern.replace(value) { "\\n" }
    return "'" + sanitized.replace("'", "'\\''") + "'"
}

fun statusClassOf(entry: NetworkLogEntry): NetworkStatusClass {
    val statusCode = entry.statusCode ?: return NetworkStatusClass.Failure
    return when {
        statusCode in 200..299 -> NetworkStatusClass.Success
        statusCode in 300..399 -> NetworkStatusClass.Redirect
        statusCode in 400..499 -> NetworkStatusClass.ClientError
        statusCode in 500..599 -> NetworkStatusClass.ServerError
        else -> NetworkStatusClass.Failure
    }
}

fun filterNetworkEntries(
    entries: List<NetworkLogEntry>,
    filter: NetworkEntryFilter,
    query: String,
): List<NetworkLogEntry> {
    val needle = query.trim().lowercase()
    return entries.filter { entry ->
        val matchesFilter = when (filter) {
            NetworkEntryFilter.All -> true
            NetworkEntryFilter.Mutations -> entry.isMutation
            NetworkEntryFilter.Failed -> entry.isFailure
        }
        matchesFilter && (needle.isEmpty() || entry.matchesQuery(needle))
    }
}

private fun NetworkLogEntry.matchesQuery(needle: String): Boolean =
    label.lowercase().contains(needle) ||
        method.lowercase().contains(needle) ||
        displayPath.lowercase().contains(needle) ||
        host.lowercase().contains(needle) ||
        statusLabel.lowercase().contains(needle) ||
        (errorMessage?.lowercase()?.contains(needle) == true)

fun summarizeNetworkEntries(entries: List<NetworkLogEntry>): NetworkSummary = NetworkSummary(
    requestCount = entries.size,
    failedCount = entries.count { entry -> entry.isFailure },
    totalBytes = entries.sumOf { entry -> entry.totalBytes },
    slowestMillis = entries.maxOfOrNull { entry -> entry.durationMillis } ?: 0L,
)

fun formatBytes(bytes: Int): String = when {
    bytes < 0 -> "—"
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(Locale.US, "%.1f kB", bytes / 1024.0)
    else -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
}

fun formatDuration(durationMillis: Long): String = when {
    durationMillis < 0L -> "—"
    durationMillis < 1L -> "<1 ms"
    durationMillis < 1000L -> "$durationMillis ms"
    else -> String.format(Locale.US, "%.2f s", durationMillis / 1000.0)
}

fun formatClockTime(epochMillis: Long): String =
    runCatching {
        LocalTime.ofInstant(java.time.Instant.ofEpochMilli(epochMillis), java.time.ZoneId.systemDefault())
            .format(ClockFormatter)
    }.getOrElse { "—" }

fun formatRecordAge(startedAtEpochMillis: Long, nowEpochMillis: Long): String =
    formatRelativeTime(startedAtEpochMillis, nowEpochMillis)

/** Friendly names so a bare list of paths is readable without opening each record. */
private val PathLabels = mapOf(
    "/api/auth/login" to "Sign in",
    "/api/auth/logout" to "Sign out",
    "/api/auth/me" to "Session restore",
)

fun labelForExchange(method: String, path: String): String {
    val known = PathLabels[path]
    if (known != null) return known
    val suffix = path.substringAfterLast('/').takeIf { it.isNotBlank() }
    return if (suffix == null) {
        "$method request"
    } else {
        "$method $suffix"
    }
}
