@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.pabrik.mobile.shell

import com.pabrik.mobile.projects.ProjectsActions
import com.pabrik.mobile.projects.ProjectsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.recents.formatRelativeTime
import com.pabrik.mobile.recents.recentChatsForWorkspace
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.launch

enum class MobileDrawerLayout {
    Auto,
    Modal,
    Permanent,
}

private val ExpandedDrawerBreakpoint = 720.dp

@Composable
fun MobileHomeScreen(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    modifier: Modifier = Modifier,
    initialWorkspaceId: String? = null,
    initialChatId: String? = null,
    onWorkspaceSelected: (String) -> Unit = {},
    onChatSelected: (String) -> Unit = {},
    /** Opens a chat as its own destination. */
    onOpenChat: (String) -> Unit = {},
    onOpenNetworkInspector: () -> Unit = {},
    drawerLayout: MobileDrawerLayout = MobileDrawerLayout.Auto,
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    /** Whether the workspace holds chats the drawer is not showing, and the server's count of them all. */
    hasMoreChats: Boolean = false,
    chatsTotal: Int = 0,
    /** Leave the drawer for the full recents list. */
    onOpenAllChats: () -> Unit = {},
    /** Session ids with a live worker. */
    runningSessionIds: Set<String> = emptySet(),
    /** The signed-in account, and the one action that ends it. */
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /** The Projects section, forwarded to both drawers. */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
    /** Whether the Recents section is folded, and the tap that folds it. */
    recentsExpanded: Boolean = true,
    onToggleRecentsSection: () -> Unit = {},
    /** The top-level "New Chat" row's busy flag and its tap. */
    isCreatingChat: Boolean = false,
    onNewChat: () -> Unit = {},
) {
    val initialResolvedWorkspaceId = initialWorkspaceId
        ?.takeIf { requestedId -> workspaces.any { it.id == requestedId } }
        ?: workspaces.firstOrNull()?.id

    var selectedWorkspaceId by rememberSaveable {
        mutableStateOf(initialResolvedWorkspaceId)
    }
    val scopedChats = selectedWorkspaceId
        ?.let { workspaceId -> recentChatsForWorkspace(chats, workspaceId) }
        .orEmpty()

    var selectedChatId by rememberSaveable {
        mutableStateOf(
            initialChatId
                ?.takeIf { requestedId -> scopedChats.any { it.id == requestedId } }
                ?: scopedChats.firstOrNull()?.id,
        )
    }

    LaunchedEffect(workspaces, selectedWorkspaceId) {
        if (workspaces.none { it.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.firstOrNull()?.id
        }
    }

    LaunchedEffect(scopedChats, selectedChatId, initialChatId) {
        // Already on a real row: nothing to decide.
        if (selectedChatId != null && scopedChats.any { it.id == selectedChatId }) {
            return@LaunchedEffect
        }
        // `initialChatId` is a *request*, not a seed.
        val requested = initialChatId
        selectedChatId = if (requested != null && scopedChats.any { it.id == requested }) {
            requested
        } else {
            scopedChats.firstOrNull()?.id
        }
    }

    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val coroutineScope = rememberCoroutineScope()
    val closeDrawer: () -> Unit = {
        // A permanent drawer has no sheet to close, so asking anyway would animate a drawer that was never open on every chat tap.
        if (drawerState.isOpen) {
            coroutineScope.launch {
                drawerState.close()
            }
        }
    }

    // D13: the top-level "New Chat" CLOSES the drawer, unlike the per-project `+` beside it, which deliberately leaves it open so the reader watches the new row …
    val newChatAndClose: () -> Unit = {
        closeDrawer()
        onNewChat()
    }

    // The destination row, closed behind it.
    val openAllChatsAndClose: () -> Unit = {
        closeDrawer()
        onOpenAllChats()
    }
    val selectedWorkspace = workspaces.firstOrNull { it.id == selectedWorkspaceId }
    val selectedChat = scopedChats.firstOrNull { it.id == selectedChatId }

    val selectWorkspace: (String) -> Unit = { workspaceId ->
        selectedWorkspaceId = workspaceId
        selectedChatId = recentChatsForWorkspace(chats, workspaceId).firstOrNull()?.id
        onWorkspaceSelected(workspaceId)
    }
    val selectChat: (String) -> Unit = { chatId ->
        selectedChatId = chatId
        onChatSelected(chatId)
        onOpenChat(chatId)
    }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground),
    ) {
        val usePermanentDrawer = when (drawerLayout) {
            MobileDrawerLayout.Auto -> maxWidth >= ExpandedDrawerBreakpoint
            MobileDrawerLayout.Modal -> false
            MobileDrawerLayout.Permanent -> true
        }

        if (usePermanentDrawer) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        modifier = Modifier
                            .width(320.dp)
                            .testTag("sidebar_sheet"),
                        drawerContainerColor = PabrikBackground,
                        drawerContentColor = PabrikText,
                    ) {
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId,
                            selectedChatId = selectedChatId,
                            onWorkspaceSelected = selectWorkspace,
                            onChatSelected = selectChat,
                            onOpenChat = closeDrawer,
                            isLoading = isLoading,
                            errorMessage = errorMessage,
                            onRetry = onRetry,
                            hasMoreChats = hasMoreChats,
                            chatsTotal = chatsTotal,
                            onOpenAllChats = openAllChatsAndClose,
                            runningSessionIds = runningSessionIds,
                            isAuthEnabled = isAuthEnabled,
                            signedInEmail = signedInEmail,
                            isLoggingOut = isLoggingOut,
                            onLogout = onLogout,
                            projects = projects,
                            projectActions = projectActions,
                            recentsExpanded = recentsExpanded,
                            onToggleRecentsSection = onToggleRecentsSection,
                            isCreatingChat = isCreatingChat,
                            onNewChat = newChatAndClose,
                        )
                    }
                },
            ) {
                HomeContent(
                    workspaceName = selectedWorkspace?.displayName ?: "No workspace",
                    selectedChat = selectedChat,
                    showNavigationMenu = false,
                    onOpenNavigationMenu = {},
                    onOpenNetworkInspector = onOpenNetworkInspector,
                )
            }
        } else {
            ModalNavigationDrawer(
                drawerState = drawerState,
                drawerContent = {
                    ModalDrawerSheet(
                        modifier = Modifier.testTag("sidebar_sheet"),
                        drawerState = drawerState,
                        drawerContainerColor = PabrikBackground,
                        drawerContentColor = PabrikText,
                    ) {
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId,
                            selectedChatId = selectedChatId,
                            onWorkspaceSelected = selectWorkspace,
                            onChatSelected = selectChat,
                            onOpenChat = closeDrawer,
                            isLoading = isLoading,
                            errorMessage = errorMessage,
                            onRetry = onRetry,
                            hasMoreChats = hasMoreChats,
                            chatsTotal = chatsTotal,
                            onOpenAllChats = openAllChatsAndClose,
                            runningSessionIds = runningSessionIds,
                            isAuthEnabled = isAuthEnabled,
                            signedInEmail = signedInEmail,
                            isLoggingOut = isLoggingOut,
                            onLogout = onLogout,
                            projects = projects,
                            projectActions = projectActions,
                            recentsExpanded = recentsExpanded,
                            onToggleRecentsSection = onToggleRecentsSection,
                            isCreatingChat = isCreatingChat,
                            onNewChat = newChatAndClose,
                        )
                    }
                },
            ) {
                HomeContent(
                    workspaceName = selectedWorkspace?.displayName ?: "No workspace",
                    selectedChat = selectedChat,
                    showNavigationMenu = true,
                    onOpenNavigationMenu = {
                        coroutineScope.launch {
                            drawerState.open()
                        }
                    },
                    onOpenNetworkInspector = onOpenNetworkInspector,
                )
            }
        }
    }
}

@Composable
private fun HomeContent(
    workspaceName: String,
    selectedChat: ChatSummary?,
    showNavigationMenu: Boolean,
    onOpenNavigationMenu: () -> Unit,
    onOpenNetworkInspector: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // One clock for the whole composition rather than a fresh read inside the body below.
    val nowEpochMillis = remember { System.currentTimeMillis() }

    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("home_screen"),
        containerColor = PabrikBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = "Pabrik",
                            style = MaterialTheme.typography.titleMedium,
                            color = PabrikText,
                        )
                        Text(
                            text = workspaceName,
                            style = MaterialTheme.typography.labelMedium,
                            color = PabrikDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    if (showNavigationMenu) {
                        IconButton(
                            onClick = onOpenNavigationMenu,
                            modifier = Modifier.testTag("sidebar_open_menu"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Menu,
                                contentDescription = "Open navigation menu",
                            )
                        }
                    }
                },
                actions = {
                    IconButton(
                        onClick = onOpenNetworkInspector,
                        modifier = Modifier.testTag("home_open_network_inspector"),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Insights,
                            contentDescription = "Open network inspector",
                            tint = PabrikMuted,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PabrikBackground,
                    navigationIconContentColor = PabrikText,
                    titleContentColor = PabrikText,
                ),
            )
        },
    ) { contentPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(24.dp),
                color = PabrikBackgroundRaised,
                contentColor = PabrikText,
                border = BorderStroke(1.dp, PabrikBorder),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .background(PabrikAccent, RoundedCornerShape(14.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "N",
                            style = MaterialTheme.typography.titleLarge,
                            color = PabrikBackground,
                        )
                    }

                    Spacer(Modifier.height(2.dp))

                    Text(
                        text = selectedChat?.displayTitle ?: "No chat selected",
                        modifier = Modifier.testTag("home_chat_title"),
                        style = MaterialTheme.typography.headlineSmall,
                        color = PabrikText,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = selectedChat?.let { chat ->
                            if (chat.hasTimestamp) {
                                // Human-touch key, matching the sidebar pill.
                                formatRelativeTime(
                                    chat.lastHumanTouchedAtEpochMillis,
                                    nowEpochMillis,
                                )
                            } else {
                                "No timestamp for this chat yet."
                            }
                        } ?: "Choose a workspace to see its recent chats.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = PabrikMuted,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = "Open a chat from the list to read and reply to it.",
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikDim,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun MobileHomeScreenPreview() {
    // The fixtures live here rather than in a shared `Preview*` top-level so nothing outside the IDE's preview renderer can reach them — that shared indirection is …
    val previewNow = System.currentTimeMillis()
    PabrikTheme {
        MobileHomeScreen(
            workspaces = listOf(
                WorkspaceOption("ws-preview", "Preview workspace"),
                WorkspaceOption("ws-other", "Another workspace"),
            ),
            chats = listOf(
                ChatSummary("chat-preview-1", "ws-preview", "Preview chat", previewNow - 5L * 60_000L),
                ChatSummary("chat-preview-2", "ws-preview", "Second preview chat", previewNow - 3L * 60L * 60_000L),
            ),
        )
    }
}
