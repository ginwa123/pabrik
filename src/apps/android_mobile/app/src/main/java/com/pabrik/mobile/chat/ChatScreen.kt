package com.pabrik.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.shell.RecentsDrawerContent
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.launch

/** Whether the agent is working, from the two signals that can say so. */
fun isChatWorking(isRunning: Boolean, isStreaming: Boolean): Boolean = isRunning || isStreaming

/** The header's word for the run, with no queue or agent counts attached. */
fun chatStatusLabel(isWorking: Boolean, isLive: Boolean): String = when {
    isWorking -> "Working…"
    isLive -> "Live"
    else -> "Reconnecting…"
}

/** The chat as its own destination, with the recents drawer one tap away. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    state: ChatUiState,
    chatTitle: String,
    modifier: Modifier = Modifier,
    onDraftChanged: (String) -> Unit = {},
    onSend: () -> Unit = {},
    onStop: () -> Unit = {},
    /** Re-read the queue behind the composer's panel, and put a waiting turn's text back in the box. */
    onRefreshQueue: () -> Unit = {},
    onUseQueuedMessage: (QueuedChatMessage) -> Unit = {},
    /** Put this chat on a different profile, or clear the override with `""`. */
    onSelectModel: (String) -> Unit = {},
    /** A picked image, as the picker's own string. */
    onAttachmentPicked: (String) -> Unit = {},
    /** Drop one pending attachment, by the id its row carries. */
    onRemoveAttachment: (String) -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onDismissError: () -> Unit = {},
    onAnswer: (QuestionAnswer) -> Unit = {},
    /** The transcript is standing where it belongs and there is nothing left to wait for. */
    onTranscriptSettled: (String?) -> Unit = {},
    /** Whether a worker is registered for this session — the backend's own definition of "the agent is working", and the one that holds between turns. */
    isRunning: Boolean = false,
    /** What the hamburger opens, and the widest way out of the chat into the rest of the app. */
    drawerContent: @Composable (dismissDrawer: () -> Unit) -> Unit,
) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val coroutineScope = rememberCoroutineScope()
    val dismissDrawer: () -> Unit = { coroutineScope.launch { drawerState.close() } }
    // One answer for the label and the stop control, so they can never disagree about whether there is a run to interrupt.
    val isWorking = isChatWorking(isRunning = isRunning, isStreaming = state.isStreaming)

    ModalNavigationDrawer(
        drawerState = drawerState,
        modifier = modifier
            .fillMaxSize()
            .testTag("chat_screen"),
        drawerContent = {
            ModalDrawerSheet(
                // Same tag as the shell's sheet: it is the same drawer, and a test should not have to know which route opened it.
                modifier = Modifier.testTag("sidebar_sheet"),
                drawerState = drawerState,
                drawerContainerColor = PabrikBackground,
                drawerContentColor = PabrikText,
            ) {
                drawerContent(dismissDrawer)
            }
        },
    ) {
        Scaffold(
            containerColor = PabrikBackground,
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(
                                text = chatTitle,
                                color = PabrikText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.testTag("chat_title"),
                            )
                            ChatStatusLine(
                                isLive = state.isLive,
                                isWorking = isWorking,
                                queuedCount = state.queuedCount,
                                subAgentsRunning = state.subAgentsRunning,
                                subAgentsTotal = state.subAgentsTotal,
                                subAgentsFailed = state.subAgentsFailed,
                                isRunning = isRunning,
                            )
                        }
                    },
                    navigationIcon = {
                        IconButton(
                            onClick = { coroutineScope.launch { drawerState.open() } },
                            modifier = Modifier.testTag("chat_drawer_menu"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Menu,
                                contentDescription = "Open chats and workspaces",
                            )
                        }
                    },
                    // No action on the right.
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = PabrikBackground,
                        navigationIconContentColor = PabrikText,
                        titleContentColor = PabrikText,
                    ),
                )
            },
        ) { contentPadding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(contentPadding),
            ) {
                ChatView(
                    state = state,
                    onDraftChanged = onDraftChanged,
                    onSend = onSend,
                    onStop = onStop,
                    onRefreshQueue = onRefreshQueue,
                    onUseQueuedMessage = onUseQueuedMessage,
                    onSelectModel = onSelectModel,
                    isRunning = isRunning,
                    onAttachmentPicked = onAttachmentPicked,
                    onRemoveAttachment = onRemoveAttachment,
                    onLoadOlder = onLoadOlder,
                    onDismissError = onDismissError,
                    onAnswer = onAnswer,
                    onTranscriptSettled = onTranscriptSettled,
                )
            }
        }
    }
}

@Composable
private fun ChatStatusLine(
    isLive: Boolean,
    isWorking: Boolean,
    queuedCount: Int,
    subAgentsRunning: Int,
    subAgentsTotal: Int,
    subAgentsFailed: Int,
    isRunning: Boolean = false,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(if (isLive) PabrikAccent else PabrikDim)
                .testTag("chat_live_dot"),
        )
        Spacer(Modifier.size(6.dp))
        Text(
            text = buildString {
                append(chatStatusLabel(isWorking = isWorking, isLive = isLive))
                // A turn that looks like it vanished is usually still queued, and saying so is the difference between "slow" and "broken".
                if (queuedCount > 0) append(" · $queuedCount queued")
                // A fan-out emits no rows at all until every sub-agent is done, so without this a two-minute spawn_sub_agent is indistinguishable from a hang.
                if (subAgentsRunning > 0 || subAgentsFailed > 0) {
                    append(" · $subAgentsRunning/$subAgentsTotal agents")
                }
                // A fan-out that finished with failures and nothing left running shows only this, or the header would go quiet right when the reader is waiting to find out …
                if (subAgentsRunning == 0 && subAgentsFailed > 0) {
                    append(" · $subAgentsFailed failed")
                }
            },
            style = MaterialTheme.typography.labelSmall,
            color = if (queuedCount > 0) PabrikMuted else PabrikDim,
            modifier = Modifier.testTag("chat_live_label"),
        )
        // Trailing, after the label rather than before it: the label is prose that has to keep its position so the two lines of the top bar do not dance, and a spinner …
        if (isRunning) {
            Spacer(Modifier.size(6.dp))
            CircularProgressIndicator(
                modifier = Modifier
                    .clearAndSetSemantics { }
                    .size(10.dp)
                    .testTag("chat_running_spinner"),
                strokeWidth = 1.5.dp,
                color = PabrikAccent,
            )
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun ChatScreenPreview() {
    // The preview carries the same drawer the route supplies, so the hamburger in the bar is never a button that opens nothing.
    val previewNow = System.currentTimeMillis()
    PabrikTheme {
        ChatScreen(
            state = ChatUiState(sessionId = "preview", isLoading = true, isLive = true),
            chatTitle = "Preview chat",
            drawerContent = { dismissDrawer ->
                RecentsDrawerContent(
                    workspaces = listOf(
                        WorkspaceOption("ws-preview", "Preview workspace"),
                    ),
                    chats = listOf(
                        ChatSummary(
                            id = "chat-preview-1",
                            workspaceId = "ws-preview",
                            title = "Preview chat",
                            updatedAtEpochMillis = previewNow,
                        ),
                    ),
                    selectedWorkspaceId = "ws-preview",
                    selectedChatId = "preview",
                    onWorkspaceSelected = {},
                    onChatSelected = {},
                    onOpenChat = dismissDrawer,
                )
            },
        )
    }
}
