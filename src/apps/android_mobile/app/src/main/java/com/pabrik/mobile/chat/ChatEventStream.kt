package com.pabrik.mobile.chat

import org.json.JSONObject

/** One dispatched server-sent event: the `event:` name and the joined `data:` payload. */
data class SseFrame(val event: String, val data: String)

/** The SSE line parser, with no Android and no network in it, so the awkward part is testable. */
class SseFrameParser {
    private var eventName: String? = null
    private val data = StringBuilder()

    /** Feeds one line (without its terminator) and returns a frame if that line completed one. */
    fun accept(line: String): SseFrame? {
        return when {
            // A comment; the heartbeat arrives as one.
            line.startsWith(":") -> null

            line.isEmpty() -> dispatch()

            // `field: value`, with an optional single leading space that the spec says to strip.
            line.contains(':') -> {
                val separator = line.indexOf(':')
                val field = line.substring(0, separator)
                val value = line.substring(separator + 1).removePrefix(" ")
                when (field) {
                    "event" -> eventName = value
                    "data" -> {
                        if (data.isNotEmpty()) data.append('\n')
                        data.append(value)
                    }
                    // `retry` and any unknown field are ignored on purpose
                }
                null
            }

            // A bare field name means an empty value.
            else -> {
                when (line) {
                    "event" -> eventName = ""
                    "data" -> data.append('\n')
                }
                null
            }
        }
    }

    /** Dispatches whatever is buffered at end of stream. */
    fun flush(): SseFrame? = dispatch()

    private fun dispatch(): SseFrame? {
        if (eventName == null && data.isEmpty()) return null
        val frame = SseFrame(
            // A frame with no `event:` line is a bare `data:` dispatch, which the spec names "message".
            event = eventName?.takeIf { it.isNotEmpty() } ?: DEFAULT_EVENT,
            data = data.toString(),
        )
        eventName = null
        data.setLength(0)
        return frame
    }

    companion object {
        const val DEFAULT_EVENT = "message"
    }
}

/** What a decoded frame means to the chat. */
sealed interface ChatStreamEvent {
    /** The handshake. The only liveness signal the server offers. */
    data object Connected : ChatStreamEvent

    /** A raw delta. */
    data class Chunk(
        val sessionId: String,
        val index: Int,
        val content: String = "",
        val reasoningContent: String = "",
    ) : ChatStreamEvent

    /** End of a turn's stream. Carries no message; the `full` that follows does. */
    data class ChunkFinished(
        val sessionId: String,
        val totalTokens: Int?,
    ) : ChatStreamEvent

    /** The canonical, complete row. Upsert by [ChatMessage.id]. */
    data class Full(val sessionId: String, val message: ChatMessage) : ChatStreamEvent

    /** A sub-agent was launched, finished or failed. */
    data class SubAgentProgress(
        val sessionId: String,
        val toolCallId: String,
        val agentName: String,
        val status: String,
        val agentIndex: Int,
        val totalAgents: Int,
    ) : ChatStreamEvent {
        companion object {
            const val STATUS_LAUNCHED = "launched"
            const val STATUS_COMPLETED = "completed"
            const val STATUS_FAILED = "failed"
        }
    }

    data class SessionChanged(
        val sessionId: String,
        val action: String,
        val name: String,
    ) : ChatStreamEvent

    /** A turn joined or left the queue behind the current run. */
    data class QueueChanged(
        val sessionId: String,
        val action: String,
        val id: String,
        val message: String = "",
    ) : ChatStreamEvent {
        companion object {
            const val ACTION_QUEUED = "queued"
            const val ACTION_DELETED = "deleted"
        }
    }

    /** A worker was registered, heart-beat, or removed. */
    data class WorkerChanged(
        val sessionId: String,
        val action: String,
    ) : ChatStreamEvent {
        companion object {
            const val ACTION_CREATED = "created"
            const val ACTION_UPDATED = "updated"
            const val ACTION_DELETED = "deleted"
        }
    }

    /** The stream was rejected. */
    data class Failed(val message: String) : ChatStreamEvent
}

sealed interface ChatStreamState {
    data object Connecting : ChatStreamState
    data object Live : ChatStreamState
    data object Reconnecting : ChatStreamState
    data class Failed(val message: String) : ChatStreamState
}

/** Decodes a dispatched frame into a [ChatStreamEvent], or null when the frame is not one this screen acts on. */
fun decodeChatFrame(frame: SseFrame): ChatStreamEvent? = try {
    decodeChatFrameUnsafe(frame)
} catch (_: Exception) {
    // A frame we cannot parse is dropped, not fatal — the stream carries on and the next `full` refetches the authoritative row.
    null
}

private fun decodeChatFrameUnsafe(frame: SseFrame): ChatStreamEvent? {
    val payload = JSONObject(frame.data)
    return when (frame.event) {
        "connected" -> ChatStreamEvent.Connected

        "auth_error" -> ChatStreamEvent.Failed(
            payload.optNullableString("error") ?: "The event stream was rejected.",
        )

        "llm_chunk" -> {
            val sessionId = payload.optNullableString("session_id").orEmpty()
            val content = payload.optNullableString("content")
            val reasoning = payload.optNullableString("reasoning_content")
            when (payload.optNullableString("type")) {
                "chunk" -> {
                    if (content == null && reasoning == null) {
                        null
                    } else {
                        ChatStreamEvent.Chunk(
                            sessionId = sessionId,
                            index = payload.optInt("index", 0),
                            content = content.orEmpty(),
                            reasoningContent = reasoning.orEmpty(),
                        )
                    }
                }

                "chunk_final" -> ChatStreamEvent.ChunkFinished(
                    sessionId = sessionId,
                    // Nested under `usage`, not top level.
                    totalTokens = payload.optNullableObject("usage")
                        ?.let { if (it.isNull("total_tokens")) null else it.optInt("total_tokens") },
                )

                else -> null
            }
        }

        "llm_full" -> {
            val sessionId = payload.optNullableString("session_id").orEmpty()
            // Sub-agent lifecycle pings ride this same channel, distinguished only by a synthetic role.
            if (payload.optNullableString("role") == ChatMessage.ROLE_SUBAGENT_PROGRESS) {
                ChatStreamEvent.SubAgentProgress(
                    sessionId = sessionId,
                    toolCallId = payload.optNullableString("tool_call_id").orEmpty(),
                    agentName = payload.optNullableString("agent_name").orEmpty(),
                    status = payload.optNullableString("status").orEmpty(),
                    agentIndex = payload.optInt("agent_index", 0),
                    totalAgents = payload.optInt("total_agents", 0),
                )
            } else if (payload.optBoolean("is_error", false)) {
                // `is_error` marks an agentic-loop diagnostic (a retry notice, a TooManyRetries), not a chat turn.
                ChatStreamEvent.Failed(
                    payload.optNullableString("content")
                        ?: "The agent reported an error.",
                )
            } else {
                val message = ChatApi.toChatMessage(payload)
                if (message == null || !message.isRealTurn) {
                    // Accepting a contentless row used to silently drop every tool result and image-only echo.
                    null
                } else {
                    ChatStreamEvent.Full(sessionId, message)
                }
            }
        }

        "session_created", "session_updated", "session_deleted" -> {
            val action = frame.event.removePrefix("session_")
            ChatStreamEvent.SessionChanged(
                sessionId = payload.optNullableString("id").orEmpty(),
                action = action,
                name = payload.optNullableString("name").orEmpty(),
            )
        }

        "queue_queued", "queue_deleted" -> ChatStreamEvent.QueueChanged(
            sessionId = payload.optNullableString("session_id").orEmpty(),
            action = if (frame.event == "queue_queued") {
                ChatStreamEvent.QueueChanged.ACTION_QUEUED
            } else {
                ChatStreamEvent.QueueChanged.ACTION_DELETED
            },
            // Both emitters stamp the row id, and it is the only handle a later delete can be matched against.
            id = payload.optNullableString("id").orEmpty().takeIf { it.isNotEmpty() }
                ?: return null,
            // Only `queue_queued` carries the text; `queue_deleted` does not.
            message = payload.optNullableString("message").orEmpty(),
        )

        "worker_created", "worker_updated", "worker_deleted" -> {
            // The emitters disagree about which id field to fill.
            val sessionId = payload.optNullableString("session_id").orEmpty()
                .ifEmpty { payload.optNullableString("id").orEmpty() }
            if (sessionId.isEmpty()) {
                null
            } else {
                ChatStreamEvent.WorkerChanged(
                    sessionId = sessionId,
                    action = frame.event.removePrefix("worker_"),
                )
            }
        }

        else -> null
    }
}
