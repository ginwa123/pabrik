package com.pabrik.mobile.recents

private const val MILLIS_PER_MINUTE = 60_000L
private const val MILLIS_PER_HOUR = 60L * MILLIS_PER_MINUTE
private const val MILLIS_PER_DAY = 24L * MILLIS_PER_HOUR

data class WorkspaceOption(
    val id: String,
    val name: String,
) {
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled workspace" }
}

/** One recents row, carrying **two** timestamps because the sidebar needs two different questions answered and they do not have the same answer. */
data class ChatSummary(
    val id: String,
    val workspaceId: String,
    val title: String,
    val updatedAtEpochMillis: Long,
    /** Defaults to the order key so a row built without a human-touch stamp degrades to the desktop's own fallback (`last_human_touched_at || updated_at`) rather than … */
    val lastHumanTouchedAtEpochMillis: Long = updatedAtEpochMillis,
    /** The project this chat belongs to, or null when it is in none. */
    val projectId: String? = null,
) {
    val displayTitle: String
        get() = title.trim().ifEmpty { "New Chat" }

    /** False when the backend sent no parseable timestamp at all (a legacy session whose `created_at`/`updated_at` are empty strings). */
    val hasTimestamp: Boolean
        get() = lastHumanTouchedAtEpochMillis > 0L
}

/** One page of recents, plus the fields the sidebar's scroll needs to decide whether to ask for another one. */
data class ChatsPage(
    val chats: List<ChatSummary>,
    val hasMore: Boolean,
    /** The server's own resume value. Hand it back verbatim; never synthesize. */
    val nextCursor: String?,
    /** Full filtered row count, 0 when the server did not report one. */
    val total: Int,
)

/** Newest-activity first, workspace-scoped. */
fun recentChatsForWorkspace(
    chats: List<ChatSummary>,
    workspaceId: String,
): List<ChatSummary> = chats
    .asSequence()
    .filter { it.workspaceId == workspaceId }
    .sortedWith(
        compareByDescending<ChatSummary> { it.updatedAtEpochMillis }
            .thenBy { it.id },
    )
    .toList()

fun formatRelativeTime(
    timestampEpochMillis: Long,
    nowEpochMillis: Long,
): String {
    val elapsedMillis = (nowEpochMillis - timestampEpochMillis).coerceAtLeast(0L)
    val minutes = elapsedMillis / MILLIS_PER_MINUTE
    if (minutes < 1L) return "now"

    val hours = minutes / 60L
    if (hours < 1L) return "${minutes}m"

    val days = hours / 24L
    if (days < 1L) return "${hours}h"

    val weeks = days / 7L
    if (weeks < 1L) return "${days}d"

    val months = days / 30L
    if (months < 1L) return "${weeks}w"

    val years = days / 365L
    if (years < 1L) return "${months}mo"

    return "${years}y"
}

fun formatRelativeTimeForAccessibility(
    timestampEpochMillis: Long,
    nowEpochMillis: Long,
): String {
    val elapsedMillis = (nowEpochMillis - timestampEpochMillis).coerceAtLeast(0L)
    val minutes = elapsedMillis / MILLIS_PER_MINUTE
    if (minutes < 1L) return "updated just now"

    val hours = minutes / 60L
    if (hours < 1L) {
        return "updated ${countWithUnit(minutes, "minute")} ago"
    }

    val days = hours / 24L
    if (days < 1L) {
        return "updated ${countWithUnit(hours, "hour")} ago"
    }

    val weeks = days / 7L
    if (weeks < 1L) {
        return "updated ${countWithUnit(days, "day")} ago"
    }

    val months = days / 30L
    if (months < 1L) {
        return "updated ${countWithUnit(weeks, "week")} ago"
    }

    val years = days / 365L
    if (years < 1L) {
        return "updated ${countWithUnit(months, "month")} ago"
    }

    return "updated ${countWithUnit(years, "year")} ago"
}

private fun countWithUnit(count: Long, unit: String): String =
    if (count == 1L) "1 $unit" else "$count ${unit}s"
