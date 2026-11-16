package com.pabrik.mobile.chat

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Top-visible index that arms the older page, matching the web's load-more band. */
private const val LOAD_OLDER_INDEX_THRESHOLD = 2

/** Reserved key for the "earlier messages" row, which is not a message. */
private const val LOAD_OLDER_KEY = "__load_older__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

/** How close to the end counts as being at it. */
private val JUMP_TO_NEWEST_BAND = 24.dp

/** How far the bottom of the transcript is below the bottom of the viewport, in pixels: zero at the end, larger the further away, [DISTANCE_FAR] when the end is … */
internal fun LazyListLayoutInfo.distanceFromBottomPx(): Int {
    if (totalItemsCount == 0) return DISTANCE_UNMEASURED
    val lastVisible = visibleItemsInfo.lastOrNull() ?: return DISTANCE_UNMEASURED
    if (lastVisible.index != totalItemsCount - 1) return DISTANCE_FAR
    val contentBottom = lastVisible.offset + lastVisible.size
    if (contentBottom <= viewportEndOffset) return 0
    return contentBottom - viewportEndOffset
}

/** How far into the last turn the viewport must be scrolled for the very end of the transcript — trailing content padding included — to be on screen. */
internal fun scrollOffsetToShowTheEndOf(
    lastItemSize: Int,
    viewportEndOffset: Int,
    afterContentPadding: Int,
): Int = (lastItemSize + afterContentPadding - viewportEndOffset).coerceAtLeast(0)

/** Leading-edge rule that marks an unboxed diagnostic row, matching the web's `.chat-tool-card` `border-left: 2px solid`. */
private val ruleWidth = 2.dp

/** One sample of where the viewport is and whether the reader is driving it. */
private data class ViewportReading(
    val lastVisibleIndex: Int,
    val totalItems: Int,
    val isScrolling: Boolean,
)

/** One chat: a virtualized transcript and a composer. */
@Composable
fun ChatView(
    state: ChatUiState,
    modifier: Modifier = Modifier,
    onDraftChanged: (String) -> Unit = {},
    onSend: () -> Unit = {},
    /** Hand a picked image to whoever decodes it, as the picker's own string. */
    onAttachmentPicked: (String) -> Unit = {},
    /** Drop one pending attachment, by the id its row carries. */
    onRemoveAttachment: (String) -> Unit = {},
    /** Whether a run can be interrupted. */
    isRunning: Boolean = false,
    onStop: () -> Unit = {},
    /** Re-read the queue behind the composer's panel, and put a waiting turn's text back in the box. */
    onRefreshQueue: () -> Unit = {},
    onUseQueuedMessage: (QueuedChatMessage) -> Unit = {},
    /** Put this chat on a different profile. */
    onSelectModel: (String) -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onDismissError: () -> Unit = {},
    onAnswer: (QuestionAnswer) -> Unit = {},
    /** The viewport has been put where the reader left this chat, and this is the only place that knows it. */
    onTranscriptSettled: (String?) -> Unit = {},
) {
    val onAttachPicked by rememberUpdatedState(onAttachmentPicked)
    // One launcher for the whole transcript, not one per attachment: it is a registration against the activity, and re-registering it for each chip would leave the …
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onAttachPicked(uri.toString())
    }

    // Same disjunction the header's word uses, so the composer's stop control and the status line can never disagree about whether a run exists.
    val isWorking = isChatWorking(isRunning = isRunning, isStreaming = state.isStreaming)

    val groups = remember(state.messages) { groupMessages(state.messages) }
    val listState = rememberLazyListState()
    // Owned here, above the `LazyColumn`, because the per-card open/closed state has to outlive the item being scrolled out of the viewport — a card remembered …
    val toolExpansion = rememberToolExpansion()

    /** The "earlier messages" row occupies index 0 when it is present, so a group's LazyColumn index is its group index plus this. */
    val sentinelOffset = if (state.hasMoreOlder) 1 else 0

    /** A fingerprint of the *tail* of the transcript. */
    val tailSignature = remember(state.messages) {
        val last = state.messages.lastOrNull()
        if (last == null) {
            ""
        } else {
            "${last.id}|${last.content.length}|${last.reasoningContent.length}|${last.isStreaming}"
        }
    }

    /** Where the transcript belongs after each change, and whether it should follow the end. */
    val chatScroll = remember { ChatScrollState() }
    val onLoadOlderNow by rememberUpdatedState(onLoadOlder)
    val onTranscriptSettledNow by rememberUpdatedState(onTranscriptSettled)

    /** One page per approach to the top. */
    var loadOlderLatched by remember { mutableStateOf(true) }

    /** Waits for the list to have measured the row a scroll is aimed at. */
    suspend fun awaitMeasuredItems() {
        if (listState.layoutInfo.totalItemsCount > 0) return
        snapshotFlow { listState.layoutInfo.totalItemsCount }.first { it > 0 }
    }

    suspend fun pinToNewest() {
        if (groups.isEmpty()) return
        awaitMeasuredItems()
        listState.scrollToItem(groups.lastIndex + sentinelOffset)
    }

    /** The end of the transcript, for a reader who *asked* to be put there. */
    suspend fun scrollToNewestEdge() {
        if (groups.isEmpty()) return
        awaitMeasuredItems()
        val index = groups.lastIndex + sentinelOffset
        listState.scrollToItem(index)
        val layout = listState.layoutInfo
        val landed = layout.visibleItemsInfo.lastOrNull() ?: return
        if (landed.index != index) return
        val intoTheTurn = scrollOffsetToShowTheEndOf(
            lastItemSize = landed.size,
            viewportEndOffset = layout.viewportEndOffset,
            afterContentPadding = layout.afterContentPadding,
        )
        if (intoTheTurn > 0) {
            listState.scrollToItem(index, intoTheTurn)
        }
    }

    suspend fun restoreAnchor(action: ChatScrollAction.RestoreAnchor) {
        val groupIndex = groups.indexOfFirst { it.key == action.key }
        if (groupIndex < 0) {
            // The anchored turn is gone — grouped away, or paged out with the page it came from.
            pinToNewest()
            return
        }
        awaitMeasuredItems()
        // The captured offset, not zero.
        listState.scrollToItem(groupIndex + sentinelOffset, action.offset)
    }

    /** Performs a decision the *transcript* asked for — a content change, a turn sent. */
    suspend fun applyScroll(action: ChatScrollAction) {
        when (action) {
            ChatScrollAction.Hold -> Unit
            is ChatScrollAction.PinToNewest -> pinToNewest()
            is ChatScrollAction.RestoreAnchor -> restoreAnchor(action)
        }
    }

    /** Whether the transcript is offering to take the reader to the newest turn. */
    var offerJumpToNewest by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val jumpBandPx = with(density) { JUMP_TO_NEWEST_BAND.roundToPx() }

    /** The reader pressed the jump control. */
    fun jumpToNewest() {
        // Decided by the policy first, so a press carries the same bookkeeping an arriving delta does: re-arm following, and drop an in-flight backwards-page anchor that …
        when (val action = chatScroll.onReaderJumpedToNewest()) {
            ChatScrollAction.Hold -> Unit
            is ChatScrollAction.PinToNewest -> scope.launch { scrollToNewestEdge() }
            // Unreachable today — a jump has nothing to anchor to — but a compiler-checked `when` beats an `else` that would drop a future decision on the floor.
            is ChatScrollAction.RestoreAnchor -> scope.launch { applyScroll(action) }
        }
    }

    /** Whether the jump control should be on screen. */
    LaunchedEffect(listState, jumpBandPx, state.sessionId) {
        snapshotFlow { listState.layoutInfo.distanceFromBottomPx() }
            .distinctUntilChanged()
            .collect { distancePx ->
                offerJumpToNewest = ChatScrollPolicy.shouldOfferJumpToNewest(
                    distanceFromBottomPx = distancePx,
                    bandPx = jumpBandPx,
                )
            }
    }

    // A new chat re-arms the backwards-page latch, so opening a transcript whose top is on screen does not immediately request a page it already holds.
    LaunchedEffect(state.sessionId) {
        loadOlderLatched = true
    }

    /** Where the reader actually is. */
    LaunchedEffect(listState) {
        snapshotFlow {
            ViewportReading(
                lastVisibleIndex = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1,
                totalItems = listState.layoutInfo.totalItemsCount,
                isScrolling = listState.isScrollInProgress,
            )
        }
            .distinctUntilChanged()
            .collect { reading ->
                chatScroll.onViewportMoved(
                    lastVisibleIndex = reading.lastVisibleIndex,
                    totalItems = reading.totalItems,
                    isScrolling = reading.isScrolling,
                )
            }
    }

    LaunchedEffect(listState, state.hasMoreOlder) {
        snapshotFlow { listState.firstVisibleItemIndex <= LOAD_OLDER_INDEX_THRESHOLD }
            .distinctUntilChanged()
            .collect { nearTop ->
                if (!nearTop) {
                    loadOlderLatched = false
                } else if (!loadOlderLatched) {
                    loadOlderLatched = true
                    if (state.hasMoreOlder && !state.isLoadingOlder) {
                        // Taken before the request, not after the response: the prepend renumbers every index above the reader, so an index captured afterwards names a different message.
                        chatScroll.armOlderPage(
                            listState.layoutInfo.visibleItemsInfo.firstOrNull()?.let { item ->
                                ChatScrollAnchor(item.key.toString(), item.offset)
                            },
                        )
                        onLoadOlderNow()
                    }
                }
            }
    }

    /** The single effect that owns "the transcript changed, where does it belong" — so a prepend, an append and an open can never fight over the scroll position. */
    LaunchedEffect(
        state.sessionId,
        groups.size,
        state.messages.size,
        state.hasMoreOlder,
        tailSignature,
    ) {
        val action = chatScroll.onContentChanged(state.sessionId, groups.size)
        applyScroll(action)
        // Reported after the scroll is issued, not on the state change that caused it.
        if (action !is ChatScrollAction.Hold) {
            onTranscriptSettledNow(state.sessionId)
        }
    }

    /** A transcript that finished loading with nothing in it is as settled as one that has been scrolled — there is no more arriving, so a gate waiting for a first … */
    LaunchedEffect(state.sessionId, state.isLoading, groups.isEmpty()) {
        if (!state.isLoading && groups.isEmpty()) {
            onTranscriptSettledNow(state.sessionId)
        }
    }

    // Sending is an explicit "take me to the newest turn" — the reader is looking at history, but the turn they just asked for lands at the end.
    LaunchedEffect(state.isSending) {
        if (state.isSending) {
            applyScroll(chatScroll.onTurnSent())
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .testTag("chat_view"),
    ) {
        AnimatedVisibility(visible = state.errorMessage != null) {
            ChatErrorBanner(
                message = state.errorMessage.orEmpty(),
                isShowingStaleData = state.isShowingStaleData,
                onDismiss = onDismissError,
            )
        }

        Box(modifier = Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .testTag("chat_message_list"),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (state.hasMoreOlder) {
                    item(key = LOAD_OLDER_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                        LoadOlderSentinel(isLoading = state.isLoadingOlder)
                    }
                }

                items(
                    count = groups.size,
                    // A stable identity, never the index: an index key re-keys every row above an append and discards per-item state.
                    key = { index -> groups[index].key },
                    contentType = { index -> groups[index].role },
                ) { index ->
                    ChatMessageGroupRow(groups[index], toolExpansion, onAnswer, state.sessionId.orEmpty())
                }
            }

            when {
                state.isLoading && state.messages.isEmpty() -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.testTag("chat_loading"),
                        color = PabrikAccent,
                    )
                }

                state.isEmptyConversation -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "No messages yet. Say something to start.",
                        modifier = Modifier.testTag("chat_empty"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = PabrikMuted,
                    )
                }
            }

            // Over the transcript, not in it.
            JumpToNewestButton(
                visible = offerJumpToNewest,
                onClick = { jumpToNewest() },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
            )
        }

        ChatComposer(
            draft = state.draft,
            attachments = state.pendingAttachments,
            isSending = state.isSending,
            isAttaching = state.isAttaching,
            isWorking = isWorking,
            model = state.selectedProfileModel,
            modelProfiles = state.availableProfiles,
            activeModelProfile = state.activeProfile,
            isSavingModel = state.isUpdatingProfile,
            onSelectModel = onSelectModel,
            cwd = state.cwd,
            onDraftChanged = onDraftChanged,
            onAttach = {
                // One image at a time.
                picker.launch(
                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                )
            },
            onRemoveAttachment = onRemoveAttachment,
            onSend = onSend,
            onStop = onStop,
            queuedMessages = state.queuedMessages,
            onRefreshQueue = onRefreshQueue,
            onUseQueuedMessage = onUseQueuedMessage,
        )
    }
}

/** The transcript's "take me to the newest turn" control. */
@Composable
private fun JumpToNewestButton(
    visible: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        modifier = modifier,
    ) {
        Surface(
            modifier = Modifier
                // 48dp, not a tighter 40.
                .size(48.dp)
                .clip(CircleShape)
                .testTag("chat_jump_to_newest"),
            color = PabrikBackgroundRaised,
            shape = CircleShape,
            border = BorderStroke(1.dp, PabrikBorder),
        ) {
            IconButton(
                onClick = onClick,
                modifier = Modifier.fillMaxSize(),
            ) {
                Icon(
                    imageVector = Icons.Filled.ArrowDownward,
                    contentDescription = "Jump to the newest message",
                    tint = PabrikAccent,
                )
            }
        }
    }
}

@Composable
private fun ChatErrorBanner(
    message: String,
    isShowingStaleData: Boolean,
    onDismiss: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .testTag("chat_error"),
        color = PabrikField,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (isShowingStaleData) "$message Showing the last saved copy." else message,
                style = MaterialTheme.typography.bodySmall,
                color = PabrikMuted,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onDismiss) { Text("Dismiss", color = PabrikMuted) }
        }
    }
}

@Composable
private fun LoadOlderSentinel(isLoading: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_load_older"),
        contentAlignment = Alignment.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = PabrikAccent,
            )
        } else {
            Text(
                text = "Scroll for earlier messages",
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
            )
        }
    }
}

@Composable
private fun ChatMessageGroupRow(
    group: ChatMessageGroup,
    toolExpansion: ToolExpansion,
    onAnswer: (QuestionAnswer) -> Unit,
    sessionId: String,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_group_${group.role}"),
        horizontalAlignment = if (group.isUser) Alignment.End else Alignment.Start,
        // A boxed bubble brings its own separation; a flat paragraph does not, so the gap carries it.
        verticalArrangement = Arrangement.spacedBy(groupGapDp(group).dp),
    ) {
        // Inside the group, not beside it.
        if (group.unpairedToolCalls.isNotEmpty()) {
            ToolCallSummaryRow(
                calls = group.unpairedToolCalls,
                expansion = toolExpansion,
                // Namespaced: `group.key` is the first tool message's id, which is also that card's expansion key, and sharing it would make opening the header open the first …
                id = "tool-calls-${group.key}",
                modifier = Modifier.testTag("chat_tool_calls_${group.key}"),
            )
        }
        group.messages.forEach { message ->
            MessageRow(message, toolExpansion, onAnswer, sessionId)
        }
    }
}

/** One row, dispatched on what it is rather than what it looks like. */
@Composable
private fun MessageRow(
    message: ChatMessage,
    toolExpansion: ToolExpansion,
    onAnswer: (QuestionAnswer) -> Unit,
    sessionId: String,
) {
    when (messageChrome(message)) {
        MessageChrome.TOOL_CARD -> {
            // Parsed once per distinct row, not once per recomposition: a streaming turn re-renders its card on every appended delta.
            val model = remember(message) { ToolCard.from(message) }
            ToolCardView(
                model = model,
                expanded = toolExpansion.isExpanded(model.id, model.defaultsExpanded),
                onToggle = { toolExpansion.toggle(model.id, model.defaultsExpanded) },
                onAnswer = onAnswer,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("chat_tool_${message.id}"),
                sessionId = sessionId,
            )
        }

        MessageChrome.BUBBLE -> UserMessageBubble(message)

        MessageChrome.PARAGRAPH -> AssistantMessageParagraph(message, toolExpansion)
    }
}

/** The reader's own turn — the one row that is a bubble. */
@Composable
private fun UserMessageBubble(message: ChatMessage) {
    val contentColor = if (message.isError) PabrikError else PabrikText

    Column(
        modifier = Modifier.widthIn(max = 460.dp),
        horizontalAlignment = Alignment.End,
    ) {
        Surface(
            modifier = Modifier.testTag("chat_message_${message.id}"),
            color = PabrikBackgroundRaised,
            contentColor = contentColor,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, PabrikBorder),
        ) {
            Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                MessageBody(message, contentColor)
            }
        }

        StreamingHint(isStreaming = message.isStreaming)
    }
}

/** Everything the assistant says, as a paragraph. */
@Composable
private fun AssistantMessageParagraph(
    message: ChatMessage,
    toolExpansion: ToolExpansion,
) {
    val contentColor = if (message.isError) PabrikError else PabrikText

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_message_${message.id}"),
        horizontalAlignment = Alignment.Start,
    ) {
        /** An agentic-loop diagnostic frame carries prose like any other assistant turn, so it gets no box either — but it still has to be findable, and unboxed red text … */
        val diagnosticRule = if (message.isError) {
            Modifier.drawBehind {
                drawRect(color = PabrikError, size = Size(ruleWidth.toPx(), size.height))
            }
        } else {
            Modifier
        }

        Column(
            modifier = diagnosticRule
                .fillMaxWidth()
                .padding(start = if (message.isError) 8.dp else 0.dp),
        ) {
            // Inside the diagnostic rule, not outside it.
            ReasoningBlock(message = message, expansion = toolExpansion)
            MessageBody(message, contentColor)
        }

        StreamingHint(isStreaming = message.isStreaming)
    }
}

/** The "still arriving" note, hung below the row it belongs to, never inside it. */
@Composable
private fun StreamingHint(isStreaming: Boolean) {
    if (!isStreaming) return
    Text(
        text = "streaming…",
        style = MaterialTheme.typography.labelSmall,
        color = PabrikDim,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

/** The content of a turn, with no frame around it. */
@Composable
private fun MessageBody(message: ChatMessage, contentColor: Color) {
    if (message.hasRenderableContent) {
        if (message.isUser) {
            Text(
                text = message.content,
                style = MaterialTheme.typography.bodyMedium,
                color = contentColor,
                modifier = Modifier.testTag("chat_body_${message.id}"),
            )
        } else {
            // Once per distinct content, not once per recomposition: a streaming turn re-runs this on every appended delta, and the split walks the whole answer.
            val isDocument = remember(message.content, message.isStreaming) {
                HtmlResponse.isHtmlTurn(message.content, isComplete = !message.isStreaming)
            }
            if (isDocument) {
                HtmlResponseText(
                    source = message.content,
                    color = contentColor,
                    isComplete = !message.isStreaming,
                    modifier = Modifier.testTag("chat_body_${message.id}"),
                )
            } else {
                MarkdownText(
                    source = message.content,
                    color = contentColor,
                    modifier = Modifier.testTag("chat_body_${message.id}"),
                )
            }
        }
    }
    if (message.imageUrls.isNotEmpty() || message.videoUrls.isNotEmpty()) {
        Spacer(Modifier.height(6.dp))
        Text(
            text = buildString {
                if (message.imageUrls.isNotEmpty()) {
                    append("${message.imageUrls.size} image(s)")
                }
                if (message.videoUrls.isNotEmpty()) {
                    if (isNotEmpty()) append(" · ")
                    append("${message.videoUrls.size} video(s)")
                }
            },
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
            // The bytes are data URLs held in a cache row; a real image loader renders them, this is the count.
            modifier = Modifier.testTag("chat_attachments"),
        )
    }
}
@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun ChatViewPreview() {
    PabrikTheme {
        ChatView(
            state = ChatUiState(
                sessionId = "preview",
                isLoading = false,
                isLive = true,
                messages = listOf(
                    ChatMessage(
                        id = "m1",
                        role = ChatMessage.ROLE_USER,
                        content = "Add a ChatView to the Android app.",
                        createdAtEpochMillis = 1_789_000_000_000,
                        sortKeyNanos = 1_789_000_000_000_000_000,
                    ),
                    ChatMessage(
                        id = "m2",
                        role = ChatMessage.ROLE_ASSISTANT,
                        content = "On it — a LazyColumn keeps the transcript virtualized.",
                        createdAtEpochMillis = 1_789_000_001_000,
                        sortKeyNanos = 1_789_000_001_000_000_000,
                    ),
                ),
            ),
        )
    }
}
