package com.pabrik.mobile.chat

import org.json.JSONObject
import java.net.URLEncoder
import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset

/** One page of messages plus the session metadata the messages endpoint happens to carry, which is how the web learns the session's cwd and profile without a … */
data class ChatPage(
    val messages: List<ChatMessage>,
    val hasMore: Boolean,
    val nextCursor: String?,
    val selectedProfileModel: String,
    val cwd: String,
    val total: Int?,
)

/** The chat endpoint and the wire shape that comes back. */
object ChatApi {
    /** The web's `PAGE_SIZE`; one page is the whole visible transcript. */
    const val MESSAGES_PAGE_LIMIT = 1000

    /** The `/api/session` and `/api/llm/session` trees are the same handlers registered twice. */
    fun messagesPath(
        sessionId: String,
        limit: Int = MESSAGES_PAGE_LIMIT,
        cursor: String? = null,
        direction: String = "asc",
    ): String = buildString {
        append("/api/llm/session/")
        append(encodeQueryValue(sessionId))
        append("/messages?limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        append("&sort_by=")
        // `sort_by=created_at` orders page 1 by the *session's* created_at (so it degenerates to id order) and later pages by the message's.
        append("id&direction=")
        append(if (direction == "desc") "desc" else "asc")
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

    fun sessionPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}"

    /** The profile list. */
    fun profilesPath(): String = "/api/config/pabrik"

    /** `PUT /api/llm/session/{id}` — the per-session profile choice. */
    fun updateSessionBody(
        selectedProfileModel: String,
        name: String = "",
        isAutoRetryUntilStop: String = "",
    ): String = JSONObject()
        .put("selected_profile_model", selectedProfileModel)
        .put("name", name)
        .put("is_auto_retry_until_stop", isAutoRetryUntilStop)
        .toString()

    /** The profile list, and the one the server calls active. */
    fun parseProfiles(body: String): ProfilesPage {
        val json = JSONObject(body)
        val profiles = json.optJSONObject("profiles")
        val names = profiles?.keys()?.asSequence()?.toList().orEmpty()
        return ProfilesPage(
            profiles = names.map { name ->
                val entry = profiles?.optJSONObject(name)
                ModelProfile(
                    name = name,
                    model = entry?.optNullableString("model").orEmpty(),
                    baseUrl = entry?.optNullableString("base_url").orEmpty(),
                )
            },
            activeProfile = json.optNullableString("active_profile")?.takeIf { it.isNotEmpty() },
        )
    }

    /** The turns waiting behind this chat's current run, oldest first. */
    fun queueMessagesPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/queue_messages"

    /** `{"messages": [{"id", "message"}], "count": n}`. */
    fun parseQueuedMessages(body: String): List<QueuedChatMessage> {
        val raw = JSONObject(body).optJSONArray("messages")
        return buildList(raw?.length() ?: 0) {
            for (index in 0 until (raw?.length() ?: 0)) {
                val row = raw?.optJSONObject(index) ?: continue
                // No id means no way to match a later `queue_deleted` to this row, so it could only ever be appended and never removed.
                val id = row.optNullableString("id").orEmpty()
                if (id.isEmpty()) continue
                add(
                    QueuedChatMessage(
                        id = id,
                        message = row.optNullableString("message").orEmpty(),
                    ),
                )
            }
        }
    }

    fun stopPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/stop"

    /** Settles a pending `ask_user` question. */
    fun answerPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/answer"

    fun answerQuestionBody(
        questionId: String? = null,
        toolCallId: String? = null,
        answer: String? = null,
        skip: Boolean = false,
    ): String = JSONObject().apply {
        if (!questionId.isNullOrBlank()) put("question_id", questionId)
        if (!toolCallId.isNullOrBlank()) put("tool_call_id", toolCallId)
        if (skip) put("skip", true) else put("answer", answer.orEmpty())
    }.toString()

    fun streamSnapshotPath(sessionId: String): String =
        "/api/llm/session/${encodeQueryValue(sessionId)}/stream"

    /** Sending a message is the *same* endpoint that creates a session. */
    fun sendMessageBody(
        sessionId: String,
        message: String,
        cwd: String = "",
        imageUrls: List<String> = emptyList(),
        videoUrls: List<String> = emptyList(),
        selectedProfileModel: String = "",
    ): String = JSONObject()
        .put("session_id", sessionId)
        .put("queue_message", message)
        .put("allowed_tools", DEFAULT_ALLOWED_TOOLS)
        .put("cwd_session", cwd)
        // Pipe-delimited, not a JSON array.
        .put("image_urls", imageUrls.joinToString("|"))
        .put("video_urls", videoUrls.joinToString("|"))
        .put("selected_profile_model", selectedProfileModel)
        .put("is_auto_retry_until_stop", "")
        .toString()

    /** Same tool set the web grants its chat box, so both clients can drive an agent. */
    const val DEFAULT_ALLOWED_TOOLS =
        "search_tool,view_tool,use_tool,command,search,load_memory," +
            "save_memory,search_skills,use_skill,used_tools,ask_user"

    fun parseMessages(body: String): ChatPage {
        val json = JSONObject(body)
        val rawMessages = json.optJSONArray("messages")
        val messages = buildList(rawMessages?.length() ?: 0) {
            for (index in 0 until (rawMessages?.length() ?: 0)) {
                val row = rawMessages?.optJSONObject(index) ?: continue
                toChatMessage(row)?.let { add(it) }
            }
        }
        return ChatPage(
            messages = messages,
            hasMore = json.optBoolean("has_more", false),
            nextCursor = json.optNullableString("next_cursor"),
            selectedProfileModel = json.optNullableString("selected_profile_model").orEmpty(),
            cwd = json.optNullableString("cwd").orEmpty(),
            // `total`, not `total_count`.
            total = if (json.isNull("total")) null else json.optInt("total"),
        )
    }

    /** The one mapper. */
    fun toChatMessage(row: JSONObject): ChatMessage? {
        val id = row.optNullableString("id").orEmpty()
        if (id.isEmpty()) return null

        val nanos = parseCreatedAtNanos(row.optNullableString("created_at"))
        return ChatMessage(
            id = id,
            role = row.optNullableString("role").orEmpty()
                .ifEmpty { if (row.optNullableString("tool_call_id") != null) ChatMessage.ROLE_TOOL else ChatMessage.ROLE_ASSISTANT },
            content = row.optNullableString("content").orEmpty(),
            createdAtEpochMillis = nanos / NANOS_PER_MILLI,
            sortKeyNanos = nanos,
            toolName = row.optNullableString("tool_name").orEmpty(),
            toolCallId = row.optNullableString("tool_call_id").orEmpty(),
            reasoningContent = row.optNullableString("reasoning_content").orEmpty(),
            finishReason = row.optNullableString("finish_reason").orEmpty(),
            imageUrls = splitPipeDelimited(row.optNullableString("image_url")),
            videoUrls = splitPipeDelimited(row.optNullableString("video_url")),
            diffviewBefore = row.optNullableString("diffview_before").orEmpty(),
            diffviewAfter = row.optNullableString("diffview_after").orEmpty(),
            toolCallsJson = row.optNullableString("tool_calls_json").orEmpty(),
            isError = row.optBoolean("is_error", false),
        )
    }

    /** Re-parses a cached `raw` envelope through the same mapper as the network. */
    fun toChatMessage(rawJson: String): ChatMessage? = try {
        toChatMessage(JSONObject(rawJson))
    } catch (_: Exception) {
        null
    }

    /** The backend's `created_at` is a JSON *string* holding a nanosecond integer, but some writers store a SQLite UTC datetime in the same column — so both shapes … */
    fun parseCreatedAtNanos(raw: String?): Long {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return 0L
        if (trimmed.length >= MIN_NANO_DIGITS && trimmed.all { it in '0'..'9' }) {
            return trimmed.toLongOrNull() ?: 0L
        }
        val millis = parseSqliteUtcMillis(trimmed) ?: return 0L
        return millis * NANOS_PER_MILLI
    }

    fun parseSqliteUtcMillis(raw: String?): Long? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
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
            // Calendar-invalid values ("2026-02-31 00:00:00") match the pattern but are not instants.
            null
        }
    }

    /** Write-through merge: a same-id incoming row replaces the cached value. */
    fun mergeById(
        current: List<ChatMessage>,
        incoming: List<ChatMessage>,
    ): List<ChatMessage> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ChatMessage>(current.size + incoming.size)
        current.forEach { message -> byId[message.id] = message }
        incoming.forEach { message -> byId[message.id] = message }
        return byId.values.toList()
    }

    /** `image_url` / `video_url` are pipe-delimited strings, not arrays. */
    fun splitPipeDelimited(raw: String?): List<String> =
        raw.orEmpty()
            .split('|')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private val SqliteUtcPattern =
        Regex("""^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$""")

    /** No max clamp on the server, so the client picks one. */
    private const val MIN_NANO_DIGITS = 13
    private const val MAX_LIMIT = 1000
    /** Shared rather than private: [ChatViewModel] stamps frame-delivered rows on the same scale the parser reads the server's `created_at` on, and two constants for … */
    internal const val NANOS_PER_MILLI = 1_000_000L
}

/** A string field, or null when it is absent or an explicit JSON null. */
internal fun JSONObject.optNullableString(name: String): String? =
    if (!has(name) || isNull(name)) null else optString(name).takeIf { it != "null" }

/** A nested object, or null when absent or an explicit JSON null. */
internal fun JSONObject.optNullableObject(name: String): JSONObject? =
    if (!has(name) || isNull(name)) null else optJSONObject(name)
