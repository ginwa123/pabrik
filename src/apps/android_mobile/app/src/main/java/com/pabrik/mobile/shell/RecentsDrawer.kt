package com.pabrik.mobile.shell

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.pabrik.mobile.projects.ProjectsActions
import com.pabrik.mobile.projects.ProjectsState
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.RecentsSidebar
import com.pabrik.mobile.recents.WorkspaceOption

/** The drawer both screens show: the workspace picker, the recents list and the account footer. */
@Composable
fun RecentsDrawerContent(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    /** Fired once a chat has been picked, because a chat is a destination. */
    onOpenChat: () -> Unit,
    modifier: Modifier = Modifier,
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    /** Whether the workspace holds chats the drawer is not showing, and the server's count of them all. */
    hasMoreChats: Boolean = false,
    chatsTotal: Int = 0,
    /** Leave the drawer for the full recents list. */
    onOpenAllChats: () -> Unit = {},
    /** Forwarded, not interpreted: the set is app-wide and the row that draws the busy dot lives in the sidebar. */
    runningSessionIds: Set<String> = emptySet(),
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /** The Projects section, forwarded to both drawers from here rather than from each call site. */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
    /** Whether the Recents section is folded, and the tap that folds it. */
    recentsExpanded: Boolean = true,
    onToggleRecentsSection: () -> Unit = {},
    /** The top-level "New Chat" row, forwarded here rather than wired in each of the two call sites — the whole reason this file exists. */
    isCreatingChat: Boolean = false,
    onNewChat: () -> Unit = {},
) {
    RecentsSidebar(
        modifier = modifier.fillMaxSize(),
        workspaces = workspaces,
        chats = chats,
        selectedWorkspaceId = selectedWorkspaceId,
        selectedChatId = selectedChatId,
        onWorkspaceSelected = onWorkspaceSelected,
        onChatSelected = onChatSelected,
        onOpenChat = onOpenChat,
        isLoading = isLoading,
        errorMessage = errorMessage,
        onRetry = onRetry,
        hasMoreChats = hasMoreChats,
        chatsTotal = chatsTotal,
        onOpenAllChats = onOpenAllChats,
        runningSessionIds = runningSessionIds,
        isAuthEnabled = isAuthEnabled,
        signedInEmail = signedInEmail,
        isLoggingOut = isLoggingOut,
        onLogout = onLogout,
        projects = projects,
        projectActions = projectActions,
        recentsExpanded = recentsExpanded,
        onToggleRecents = onToggleRecentsSection,
        isCreatingChat = isCreatingChat,
        onNewChat = onNewChat,
    )
}

/** The chat row the chat route's drawer highlights. */
internal fun chatDrawerSelectedChatId(
    routeSessionId: String,
    homeSelectedChatId: String?,
): String? = routeSessionId.takeIf { it.isNotBlank() } ?: homeSelectedChatId
