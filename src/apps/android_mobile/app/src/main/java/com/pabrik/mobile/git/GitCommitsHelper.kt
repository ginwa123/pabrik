package com.pabrik.mobile.git

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object GitCommitsHelper {
    private val dateFormatter = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.ROOT)

    fun authorInitials(name: String): String {
        val parts = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return "?"
        if (parts.size == 1) return parts[0].take(2).ifEmpty { "?" }
        val first = parts.first().firstOrNull() ?: return "?"
        val last = parts.last().firstOrNull() ?: return "?"
        return "$first$last".uppercase(Locale.ROOT)
    }

    fun footerLabel(loaded: Int, total: Int): String =
        if (total > 0) "$loaded of $total" else loaded.toString()

    fun hasMore(loaded: Int, total: Int): Boolean = total > loaded

    fun shortSha(sha: String): String = sha.take(7)

    fun formatDate(epochSeconds: Long, zone: ZoneId): String =
        if (epochSeconds <= 0) "" else dateFormatter.withZone(zone).format(Instant.ofEpochSecond(epochSeconds))
}
