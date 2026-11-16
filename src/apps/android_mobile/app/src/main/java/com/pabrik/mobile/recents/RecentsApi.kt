package com.pabrik.mobile.recents

import com.pabrik.mobile.chat.optNullableString
import org.json.JSONObject
import java.net.URLEncoder
import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset

/** The sidebar's two endpoints, and the wire shape that comes back. */
object RecentsApi {
    /** `is_include_items` defaults to `"true"` on the server, which drags along every workspace item and its tasks. */
    const val WORKSPACES_PATH = "/api/workspaces?is_include_items=false"

    /** How many rows the drawer's preview asks for. */
    const val DRAWER_PREVIEW_ROWS = 5

    /** How many rows one page of the **full-screen** list asks for. */
    const val CHATS_PAGE_LIMIT = 20

    /** `workspace_id` is only honoured when it resolves to real sessions, so this is a scoped list rather than a client-side filter. */
    fun chatsPath(
        workspaceId: String,
        cursor: String? = null,
        limit: Int = CHATS_PAGE_LIMIT,
    ): String = buildString {
        append("/api/session?sort_by=updated_at&direction=desc")
        append("&limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        append("&workspace_id=")
        append(encodeQueryValue(workspaceId))
        // A blank cursor is indistinguishable from "first page" to the server, so sending it would restart the list and re-serve page 1 forever.
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

    fun parseWorkspaces(body: String): List<WorkspaceOption> {
        val workspaces = JSONObject(body).optJSONArray("workspaces")
            ?: return emptyList()

        return buildList(workspaces.length()) {
            for (index in 0 until workspaces.length()) {
                val workspace = workspaces.optJSONObject(index) ?: continue
                val id = workspace.stringField("id")
                // A row without an id cannot be scoped to, so it is unusable.
                if (id.isEmpty()) continue
                add(
                    WorkspaceOption(
                        id = id,
                        name = workspace.stringField("name"),
                    ),
                )
            }
        }
    }

    fun parseChats(
        body: String,
        workspaceId: String,
    ): List<ChatSummary> = parseChatsPage(body, workspaceId).chats

    /** One page of recents plus everything a *drain* needs to know whether to ask for another one. */
    fun parseChatsPage(
        body: String,
        workspaceId: String,
    ): ChatsPage {
        val root = JSONObject(body)
        val sessions = root.optJSONArray("sessions")

        val chats = buildList {
            if (sessions == null) return@buildList
            for (index in 0 until sessions.length()) {
                val session = sessions.optJSONObject(index) ?: continue
                val id = session.stringField("session_id")
                if (id.isEmpty()) continue
                add(
                    ChatSummary(
                        id = id,
                        // The scoped response does not echo the workspace back, so the id we asked with is the only one available.
                        workspaceId = workspaceId,
                        title = session.stringField("session_name"),
                        // Two answers, deliberately: the page is ordered by `updated_at` (that is what `sort_by=updated_at` asked the server for), while the pill shows the human's own …
                        updatedAtEpochMillis = sessionOrderTimestampMillis(session),
                        lastHumanTouchedAtEpochMillis = sessionLabelTimestampMillis(session),
                        // `stringField` maps an explicit JSON null to "", so the blank check is what separates "no project" from a project whose id happened to be empty.
                        projectId = session.stringField("workspace_item_id")
                            .takeIf { it.isNotBlank() },
                    ),
                )
            }
        }

        val total = if (root.isNull("total")) 0 else root.optInt("total", 0)
        val serverHasMore = if (root.isNull("has_more")) false else root.optBoolean("has_more", false)

        return ChatsPage(
            chats = chats,
            // `total` is a backstop, not the primary signal.
            hasMore = serverHasMore && (total <= 0 || chats.size < total),
            // A blank cursor is worse than none: it would restart the list at page 1 and hand back rows the sidebar already shows.
            nextCursor = root.optNullableString("next_cursor")?.takeIf { it.isNotBlank() },
            total = total,
        )
    }

    /** Write-through merge for a page append: a same-id incoming row replaces the one already held, order is preserved. */
    fun mergeChatsById(
        current: List<ChatSummary>,
        incoming: List<ChatSummary>,
    ): List<ChatSummary> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ChatSummary>(current.size + incoming.size)
        current.forEach { chat -> byId[chat.id] = chat }
        incoming.forEach { chat -> byId[chat.id] = chat }
        return byId.values.toList()
    }

    /** The **order** key: plain `updated_at`, then `created_at`. */
    private fun sessionOrderTimestampMillis(session: JSONObject): Long =
        parseTimestampEpochMillis(session.stringField("updated_at"))
            ?: parseTimestampEpochMillis(session.stringField("created_at"))
            ?: UNKNOWN_TIMESTAMP

    /** The **label** key: `last_human_touched_at`, then `updated_at`, then `created_at` — the desktop's `last_human_touched_at || updated_at`, with a `created_at` leg … */
    private fun sessionLabelTimestampMillis(session: JSONObject): Long =
        parseTimestampEpochMillis(session.stringField("last_human_touched_at"))
            ?: sessionOrderTimestampMillis(session)

    /** Parses the two timestamp shapes the backend emits into epoch millis, or null when the value is absent or unparseable. */
    fun parseTimestampEpochMillis(raw: String?): Long? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null

        if (trimmed.length >= MIN_UNIX_MILLIS_DIGITS && trimmed.all { it in '0'..'9' }) {
            return trimmed.toLongOrNull()
        }

        val match = SqliteUtcPattern.matchEntire(trimmed) ?: return null
        val (year, month, day, hour, minute, second) = match.destructured
        return try {
            LocalDateTime.of(
                year.toInt(),
                month.toInt(),
                day.toInt(),
                hour.toInt(),
                minute.toInt(),
                second.toInt(),
            )
                .toInstant(ZoneOffset.UTC)
                .toEpochMilli()
        } catch (_: DateTimeException) {
            // Calendar-invalid values ("2026-02-31 00:00:00") parse as digits but are not instants; a missing label beats a wrong one.
            null
        }
    }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /** No upper clamp on the server, so the client picks one. */
    private const val MAX_LIMIT = 1000

    private val SqliteUtcPattern =
        Regex("""^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$""")

    /** Any integer at or above this is a plausible unix-seconds/millis stamp. */
    private const val MIN_UNIX_MILLIS_DIGITS = 10

    /** Sentinel for a session whose every timestamp was missing. */
    const val UNKNOWN_TIMESTAMP = 0L
}

/** `JSONObject.optString` renders an explicit null as the four-character text `"null"`, and does not trim. */
internal fun JSONObject.stringField(name: String): String =
    if (isNull(name)) "" else optString(name).trim()
