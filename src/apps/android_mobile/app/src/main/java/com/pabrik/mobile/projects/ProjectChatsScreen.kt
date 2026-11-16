package com.pabrik.mobile.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.HourglassTop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.recents.ChatListFooter
import com.pabrik.mobile.recents.ChatListLoadMoreTrigger
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikText

/** Reserved key for the footer row, which is not a chat. */
private const val LOAD_MORE_KEY = "__project_chats_footer__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private const val CONTENT_TYPE_CHAT = "chat"

private const val CONTENT_TYPE_STATE = "state"

/** Every chat in one project, full-screen, paging on scroll. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectChatsScreen(
    projectName: String,
    page: ProjectChatsPage?,
    selectedChatId: String?,
    runningSessionIds: Set<String>,
    isLoading: Boolean,
    onChatSelected: (String) -> Unit,
    /** Open a chat from this screen. */
    onOpenChat: (String) -> Unit,
    onLoadMore: () -> Unit,
    /** Open the create flow for *this* project. */
    onCreateTask: () -> Unit = {},
    /** Whether a create for this project is in flight, for the `+`'s busy state. */
    isCreatingTask: Boolean = false,
    nowEpochMillis: Long = remember { System.currentTimeMillis() },
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val chats = page?.chats.orEmpty()
    val hasMore = page?.hasMore ?: false
    val listState = rememberLazyListState()

    // One page per approach to the end — *and* one when the reader cannot approach the end at all.
    ChatListLoadMoreTrigger(
        listState = listState,
        canPage = hasMore && chats.isNotEmpty() && !isLoading,
        rowCount = chats.size,
        onLoadMore = onLoadMore,
    )

    Scaffold(
        modifier = modifier.testTag("project_chats_screen"),
        containerColor = PabrikBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = projectName,
                        style = MaterialTheme.typography.titleMedium,
                        color = PabrikText,
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag("project_chats_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PabrikAccent,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PabrikBackground,
                ),
                actions = {
                    // The one place on this screen that creates something.
                    IconButton(
                        onClick = onCreateTask,
                        // Disabled while the create is in flight, so a double-tap cannot make two chats.
                        enabled = !isCreatingTask,
                        modifier = Modifier.testTag("project_chats_create"),
                    ) {
                        Icon(
                            imageVector = if (isCreatingTask) {
                                Icons.Filled.HourglassTop
                            } else {
                                Icons.Filled.Add
                            },
                            contentDescription = "New chat in this project",
                            tint = if (isCreatingTask) PabrikDim else PabrikAccent,
                        )
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .testTag("project_chats_list"),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (chats.isEmpty()) {
                item(key = "project_chats_state", contentType = CONTENT_TYPE_STATE) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        com.pabrik.mobile.recents.SidebarPlaceholder(
                            testTag = if (isLoading) "project_chats_loading" else "project_chats_empty",
                            title = if (isLoading) "Loading chats" else "No chats in this project yet",
                            detail = if (isLoading) {
                                "Fetching the chats in this project."
                            } else {
                                // A fresh kanban or agent legitimately has none.
                                "Start one from the web app and it will show up here."
                            },
                            showSpinner = isLoading,
                        )
                    }
                }
                return@LazyColumn
            }

            items(
                items = chats,
                key = { chat -> chat.id },
                contentType = { CONTENT_TYPE_CHAT },
            ) { chat ->
                ProjectChatRow(
                    chat = chat,
                    selected = chat.id == selectedChatId,
                    isRunning = chat.id in runningSessionIds,
                    nowEpochMillis = nowEpochMillis,
                    onClick = {
                        onChatSelected(chat.id)
                        // A chat is a destination.
                        onOpenChat(chat.id)
                    },
                )
            }

            item(key = LOAD_MORE_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                ChatListFooter(
                    isLoading = isLoading,
                    // Claiming the end while more may still exist is a lie the reader sees first and then watches get retracted.
                    hasReachedEnd = !hasMore,
                )
            }
        }
    }
}
