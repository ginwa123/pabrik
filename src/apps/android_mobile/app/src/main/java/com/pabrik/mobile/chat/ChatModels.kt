package com.pabrik.mobile.chat

/** The render model for one chat turn. */
data class ChatMessage(
    val id: String,
    val role: String,
    val content: String,
    val createdAtEpochMillis: Long,
    val sortKeyNanos: Long,
    val toolName: String = "",
    val toolCallId: String = "",
    val reasoningContent: String = "",
    val finishReason: String = "",
    val imageUrls: List<String> = emptyList(),
    val videoUrls: List<String> = emptyList(),
    /** The two sides of a file edit, present only on a completed tool result. */
    val diffviewBefore: String = "",
    val diffviewAfter: String = "",
    /** The tool calls an assistant turn declared, as a JSON *string* holding an OpenAI-style array. */
    val toolCallsJson: String = "",
    /** The agentic-loop diagnostic frame, which is not a chat turn. */
    val isError: Boolean = false,
    /** True only for the in-flight assistant placeholder the SSE `chunk` frames append to. */
    val isStreaming: Boolean = false,
) {
    val isUser: Boolean get() = role == ROLE_USER

    /** An assistant turn whose whole content is "I am going to call these tools". */
    val isToolCallTurn: Boolean
        get() = role == ROLE_ASSISTANT &&
            finishReason == FINISH_REASON_TOOL_CALLS &&
            toolCallsJson.isNotBlank()

    /** True when either side of a file edit is present. */
    val hasDiff: Boolean
        get() = diffviewBefore.isNotEmpty() || diffviewAfter.isNotEmpty()

    /** True when there is something to draw, so an empty row is never rendered. */
    val hasVisibleContent: Boolean
        get() = hasRenderableContent ||
            reasoningContent.isNotBlank() ||
            isDrawableToolRow ||
            imageUrls.isNotEmpty() ||
            videoUrls.isNotEmpty() ||
            hasDiff ||
            isError

    /** A tool row is drawable from its name alone; its body is an envelope. */
    private val isDrawableToolRow: Boolean
        get() = role == ROLE_TOOL && toolName.isNotBlank()

    /** The row is a real turn the transcript keeps, whether or not it draws. */
    val isRealTurn: Boolean
        get() = hasVisibleContent || isToolCallTurn

    /** The content a renderer would actually show, which is not the raw column. */
    val hasRenderableContent: Boolean
        get() = content.isNotBlank() &&
            (HtmlResponse.isHtmlTurn(content, isComplete = !isStreaming) ||
                Markdown.hasContent(content))

    companion object {
        const val ROLE_USER = "user"
        const val ROLE_ASSISTANT = "assistant"
        const val ROLE_SYSTEM = "system"
        const val ROLE_TOOL = "tool"

        /** Every role the wire can deliver a persisted turn under. */
        fun knownRoles(): List<String> = listOf(ROLE_USER, ROLE_ASSISTANT, ROLE_SYSTEM, ROLE_TOOL)

        /** The only `finish_reason` that means "this turn declared tool calls". */
        const val FINISH_REASON_TOOL_CALLS = "tool_calls"

        /** The `finish_reason` on a tool row, both its placeholder and its result. */
        const val FINISH_REASON_TOOL = "tool"

        /** The synthetic role the backend uses for sub-agent lifecycle pings. */
        const val ROLE_SUBAGENT_PROGRESS = "subagent_progress"

        /** Reserved prefix for the placeholder the stream appends to. */
        const val STREAMING_ID_PREFIX = "streaming-"
    }
}

/** A row in the reserved streaming namespace, whether or not it is still frozen. */
val ChatMessage.isStreamingPlaceholder: Boolean
    get() = isStreaming || id.startsWith(ChatMessage.STREAMING_ID_PREFIX)

/** True when this is the server's finished row for the turn [partial] is still typing, so the placeholder has done its job and can go. */
fun ChatMessage.supersedesStreaming(partial: ChatMessage): Boolean {
    if (partial.content.isEmpty()) return false
    if (role != ChatMessage.ROLE_ASSISTANT) return false
    return content.length >= partial.content.length && content.startsWith(partial.content)
}

/** Consecutive same-role turns rendered as one list item. */
data class ChatMessageGroup(
    val key: String,
    val role: String,
    val messages: List<ChatMessage>,
    val timestampEpochMillis: Long,
    /** The tool calls of this run that no tool row has answered yet. */
    val unpairedToolCalls: List<ToolCallEntry> = emptyList(),
) {
    val isUser: Boolean get() = role == ChatMessage.ROLE_USER
}

/** The bare call declarations this group carries. */
private fun ChatMessageGroup.bareDeclarations(): List<ToolCallEntry> {
    if (role != ChatMessage.ROLE_ASSISTANT) return emptyList()
    val bare = messages.filter {
        it.isToolCallTurn && it.content.isBlank() && it.reasoningContent.isBlank()
    }
    // No candidate, no `tool_calls_json` to parse.
    if (bare.isEmpty()) return emptyList()
    return bare.flatMap { ToolCalls.parse(it.toolCallsJson) }
}

/** One entry of `config.profiles_models`: a saved LLM configuration. */
data class ModelProfile(
    val name: String,
    val model: String,
    val baseUrl: String,
) {
    /** The one line under the name in the picker. */
    val detail: String
        get() = listOf(model, baseUrl).filter { it.isNotEmpty() }.joinToString(" · ")
}

/** `GET /api/config/pabrik`'s two answers: every profile, and the active one. */
data class ProfilesPage(
    val profiles: List<ModelProfile>,
    /** The reader's chosen default from Settings → Profiles → "Set active". */
    val activeProfile: String? = null,
)

/** The profile the next LLM call in this chat will actually use. */
fun effectiveProfileName(
    selectedProfile: String,
    activeProfile: String?,
): String? = selectedProfile.ifEmpty { activeProfile }

/** One turn waiting behind the run in progress. */
data class QueuedChatMessage(
    val id: String,
    val message: String,
)

data class ChatUiState(
    val sessionId: String? = null,
    val isLoading: Boolean = true,
    val messages: List<ChatMessage> = emptyList(),
    val selectedProfileModel: String = "",
    val cwd: String = "",
    val errorMessage: String? = null,
    /** The composer's text, owned here rather than by the composable so it can survive a failed send. */
    val draft: String = "",
    /** Images attached to the turn being composed, already encoded. */
    val pendingAttachments: List<ChatAttachment> = emptyList(),
    /** A picked image is being decoded and downscaled. */
    val isAttaching: Boolean = false,
    val isSending: Boolean = false,
    val isStreaming: Boolean = false,
    val isLoadingOlder: Boolean = false,
    val hasMoreOlder: Boolean = false,
    /** Whether the SSE stream is currently open, shown as a live dot. */
    val isLive: Boolean = false,
    /** Turns waiting behind the current run, oldest first. */
    val queuedMessages: List<QueuedChatMessage> = emptyList(),
    /** Sub-agents launched but not yet reported finished. */
    val subAgentsRunning: Int = 0,
    val subAgentsTotal: Int = 0,
    val subAgentsFailed: Int = 0,
    /** Every profile in `config.profiles_models`, for the composer's picker. */
    val availableProfiles: List<ModelProfile> = emptyList(),
    /** The reader's account-wide default profile, or null when none is set. */
    val activeProfile: String? = null,
    /** Profiles are on their way. */
    val isLoadingProfiles: Boolean = false,
    /** A `PUT` of the chosen profile is in flight. */
    val isUpdatingProfile: Boolean = false,
) {
    /** The name to show on the model's chip — the *effective* profile, which is not always [selectedProfileModel]. */
    val effectiveProfile: String?
        get() = effectiveProfileName(selectedProfileModel, activeProfile)

    /** Whether the model chip is a control at all. */
    val canPickProfile: Boolean
        get() = availableProfiles.isNotEmpty() || selectedProfileModel.isNotEmpty()
    /** Rows are on screen and the revalidation failed. */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && messages.isNotEmpty()

    /** Nothing cached and nothing loaded — a genuinely empty conversation. */
    val isEmptyConversation: Boolean
        get() = !isLoading && errorMessage == null && messages.isEmpty()

    /** How many turns are waiting behind the run, for the header's one word. */
    val queuedCount: Int get() = queuedMessages.size
}

/** Collapses consecutive same-role turns into groups, folds a tool call into the tool run that answers it, and drops any group that would render nothing. */
fun groupMessages(messages: List<ChatMessage>): List<ChatMessageGroup> {
    val groups = ArrayList<ChatMessageGroup>()
    var current = mutableListOf<ChatMessage>()

    fun flush() {
        if (current.isEmpty()) return
        val first = current.first()
        groups.add(
            ChatMessageGroup(
                key = first.id,
                role = first.role,
                messages = current.toList(),
                timestampEpochMillis = first.createdAtEpochMillis,
            ),
        )
        current = mutableListOf()
    }

    messages.forEach { message ->
        // A streaming placeholder must never be glued to the turn above it — it belongs visually to the assistant column and carries its own key.
        val startsGroup = current.isEmpty() ||
            current.first().role != message.role ||
            message.isStreaming ||
            current.first().isStreaming
        if (startsGroup) flush()
        current.add(message)
    }
    flush()

    return attachUnpairedToolCalls(groups).filter { group ->
        group.unpairedToolCalls.isNotEmpty() || group.messages.any { it.hasVisibleContent }
    }
}

/** The second grouping pass: work out which declared calls still need naming. */
private fun attachUnpairedToolCalls(
    groups: List<ChatMessageGroup>,
): List<ChatMessageGroup> {
    val attached = arrayOfNulls<ChatMessageGroup>(groups.size)
    val answeredAfter = HashSet<String>()
    var sawDeclaration = false

    for (index in groups.indices.reversed()) {
        val group = groups[index]
        if (group.role == ChatMessage.ROLE_TOOL) {
            group.messages.forEach { message ->
                if (message.toolCallId.isNotBlank()) answeredAfter.add(message.toolCallId)
            }
        }
        val declared = group.bareDeclarations()
        if (declared.isEmpty()) {
            attached[index] = group
        } else {
            sawDeclaration = true
            attached[index] = group.copy(
                unpairedToolCalls = declared.filter { it.id !in answeredAfter },
            )
        }
    }

    // Nothing was declared anywhere, so nothing was copied either.
    if (!sawDeclaration) return groups
    return List(groups.size) { index -> attached[index] ?: groups[index] }
}
