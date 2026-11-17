package com.pabrik.mobile.network

import com.pabrik.mobile.projects.CreateTaskHost
import com.pabrik.mobile.projects.NewTaskDialogData
import com.pabrik.mobile.projects.CreateTaskRequest
import com.pabrik.mobile.projects.NewChatProjectSheet
import com.pabrik.mobile.projects.ProjectChatsScreen
import com.pabrik.mobile.projects.ProjectSummary
import com.pabrik.mobile.projects.ProjectsActions
import com.pabrik.mobile.projects.ProjectsState
import com.pabrik.mobile.projects.TaskTypes
import com.pabrik.mobile.projects.rememberCreateTaskController
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.flow.StateFlow
import androidx.navigation.navDeepLink
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthRestoringScreen
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.server.ServerChange
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatScreen
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.chat.QuestionAnswer
import com.pabrik.mobile.chat.QueuedChatMessage
import com.pabrik.mobile.login.LoginCredentials
import com.pabrik.mobile.login.LoginScreen
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.RecentsChatsScreen
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.shell.MobileHomeScreen
import com.pabrik.mobile.shell.RecentsDrawerContent
import com.pabrik.mobile.shell.chatDrawerSelectedChatId
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.pabrik.mobile.workspace.WorkspaceDataState
import com.pabrik.mobile.workspace.WorkspaceDataViewModel
import com.pabrik.mobile.workspace.WorkspaceSettingsScreen
import com.pabrik.mobile.workspace.DocumentsScreen
import com.pabrik.mobile.workspace.NotificationsScreen
import com.pabrik.mobile.workspace.UserSettingsScreen
import com.pabrik.mobile.workspace.ItemFeatureScreen
import com.pabrik.mobile.workspace.FeatureSection
import com.pabrik.mobile.workspace.FeatureRow
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/** Every view in the app is a route, so each one survives a process restart and `adb shell am start -a android.intent.action.VIEW -d pabrik://…` lands on it … */
object PabrikRoutes {
    const val SHELL = "app"
    const val CHAT = "chat/{sessionId}"
    const val ARG_SESSION_ID = "sessionId"
    const val NETWORK = "network"
    const val RECORD_DETAIL = "network/record/{recordId}"
    const val ARG_RECORD_ID = "recordId"

    /** One project's chats, full-screen. */
    const val PROJECT = "project/{workspaceId}/{itemId}"
    const val ARG_WORKSPACE_ID = "workspaceId"
    const val ARG_ITEM_ID = "itemId"

    /** Every chat in one workspace, full-screen. */
    const val CHATS = "chats/{workspaceId}"

    fun chat(sessionId: String): String = "chat/${UriEncoding.encode(sessionId)}"

    fun recordDetail(recordId: Long): String = "network/record/$recordId"

    fun project(workspaceId: String, itemId: String): String =
        "project/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun chats(workspaceId: String): String =
        "chats/${UriEncoding.encode(workspaceId)}"

    const val SETTINGS = "settings"
    const val WORKSPACE_SETTINGS = "workspace/{workspaceId}/settings"
    const val KANBAN_SETTINGS = "kanban/{workspaceId}/{itemId}/settings"
    const val DOCUMENTS = "documents/{workspaceId}"
    const val DOCUMENT = "documents/{workspaceId}/{documentId}"
    const val ARG_DOCUMENT_ID = "documentId"
    const val AGENT = "agent/{workspaceId}/{itemId}"
    const val DESIGN = "design/{workspaceId}/{itemId}"
    const val ROUTINE = "routine/{workspaceId}/{itemId}"
    const val GIT = "git/{workspaceId}/{itemId}"
    const val MEMORY = "memory/{workspaceId}"
    const val SECRETS = "secrets/{workspaceId}"
    const val MEMBERS = "members/{workspaceId}"
    const val SKILLS = "skills/{workspaceId}"
    const val MCP = "mcp/{workspaceId}"
    const val LLM_CONFIG = "llm-config/{workspaceId}"
    const val TOOLS = "tools/{workspaceId}"
    const val NOTIFICATIONS = "notifications"

    fun settings(): String = SETTINGS

    fun workspaceSettings(workspaceId: String): String =
        "workspace/${UriEncoding.encode(workspaceId)}/settings"

    fun kanbanSettings(workspaceId: String, itemId: String): String =
        "kanban/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}/settings"

    fun documents(workspaceId: String): String =
        "documents/${UriEncoding.encode(workspaceId)}"

    fun document(workspaceId: String, documentId: String): String =
        "documents/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(documentId)}"

    fun agent(workspaceId: String, itemId: String): String =
        "agent/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun design(workspaceId: String, itemId: String): String =
        "design/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun routine(workspaceId: String, itemId: String): String =
        "routine/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun git(workspaceId: String, itemId: String): String =
        "git/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun memory(workspaceId: String): String =
        "memory/${UriEncoding.encode(workspaceId)}"

    fun secrets(workspaceId: String): String =
        "secrets/${UriEncoding.encode(workspaceId)}"

    fun members(workspaceId: String): String =
        "members/${UriEncoding.encode(workspaceId)}"

    fun skills(workspaceId: String): String =
        "skills/${UriEncoding.encode(workspaceId)}"

    fun mcp(workspaceId: String): String =
        "mcp/${UriEncoding.encode(workspaceId)}"

    fun llmConfig(workspaceId: String): String =
        "llm-config/${UriEncoding.encode(workspaceId)}"

    fun tools(workspaceId: String): String =
        "tools/${UriEncoding.encode(workspaceId)}"

    fun notifications(): String = NOTIFICATIONS
}

/** What one back action should do. */
internal enum class BackAction {
    /** A real destination sits under this one, so pop back onto it. */
    PopPrevious,

    /** Nothing but the graph sits underneath — a `popUpTo(SHELL)` navigation, or a deep link that never pushed the shell. */
    ReturnToShell,
}

/** [hasDestinationBelow] is "is there a non-graph entry under the current one", which is false both on the shell and on a leaf with no shell beneath it. */
internal fun backActionFor(hasDestinationBelow: Boolean): BackAction =
    if (hasDestinationBelow) BackAction.PopPrevious else BackAction.ReturnToShell

/** One back action, for an app with a single activity. */
internal fun NavHostController.goBackToPreviousOrShell() {
    val below = previousBackStackEntry?.destination
    when (backActionFor(below != null && below !is NavGraph)) {
        BackAction.PopPrevious -> popBackStack()

        // Non-inclusive: the shell is the one entry that must survive.
        BackAction.ReturnToShell -> navigate(PabrikRoutes.SHELL) {
            popUpTo(PabrikRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }
}

/** Minimal percent-encoding for a path segment. */
internal object UriEncoding {
    fun encode(value: String): String = buildString {
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            val code = byte.toInt() and 0xFF
            val isUnreserved = code in 'a'.code..'z'.code ||
                code in 'A'.code..'Z'.code ||
                code in '0'.code..'9'.code ||
                code == '-'.code || code == '_'.code || code == '.'.code || code == '~'.code
            if (isUnreserved) {
                append(code.toChar())
            } else {
                append('%').append(HEX[(code shr 4) and 0xF]).append(HEX[code and 0xF])
            }
        }
    }

    private const val HEX = "0123456789ABCDEF"
}

@Composable
fun PabrikNavGraph(
    authState: AuthUiState,
    onSignIn: (String, String) -> Unit,
    onRetrySession: () -> Unit,
    onUseAnotherAccount: () -> Unit,
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    homeState: HomeUiState,
    /** The chat transcript, as the flow it is — collected *inside* the chat destination, never at the top of the tree. */
    chatState: StateFlow<ChatUiState>,
    /** The position the last run left behind. */
    positionStore: LastPositionStore,
    onSelectWorkspace: (String) -> Unit,
    onSelectChat: (String) -> Unit,
    /** The four project actions the drawer and the project screen share. */
    onToggleProjectsSection: () -> Unit = {},
    onToggleProjectExpanded: (String) -> Unit = {},
    onEnsureProjectChatsLoaded: (String) -> Unit = {},
    onLoadMoreProjectChats: (String) -> Unit = {},
    /** The full-screen recents list's next page. */
    onLoadMoreChats: () -> Unit = {},
    onRetryProjects: () -> Unit = {},
    /** Create a chat or a memory under a project. */
    onCreateTask: (String, String, CreateTaskRequest) -> Unit = { _, _, _ -> },
    /** Fill in the board's "New task" form: its columns, the profile list, and the server's home for the worktree prefill. */
    onLoadKanbanFormData: (String, String) -> Unit = { _, _ -> },
    /** The drawer's top-level "New Chat": create a chat in the workspace's default project and open it. */
    onNewChat: () -> Unit = {},
    /** Session ids of chats that were just created, to open. */
    createdChats: Flow<String>? = null,
    /** Clear the last create's complaint. */
    onDismissTaskCreateError: () -> Unit = {},
    /** Fold the sidebar's Recents section away, or unfold it. */
    onToggleRecentsSection: () -> Unit = {},
    /** Show the whole Recents list instead of its first few rows, or put the preview back. */
    onRetryHome: () -> Unit,
    onOpenSession: (String) -> Unit,
    onChatDraftChanged: (String) -> Unit,
    onSendChatMessage: () -> Unit,
    onStopChatRun: () -> Unit,
    /** Re-read the queue behind the composer's panel, and put a waiting turn's text back in the box. */
    onRefreshChatQueue: () -> Unit = {},
    onUseQueuedChatMessage: (QueuedChatMessage) -> Unit = {},
    /** Put a chat on a different profile, or clear the override with `""`. */
    onSelectChatModel: (String) -> Unit = {},
    /** A picked image and the removal of an attached one. */
    onAttachChatImage: (String) -> Unit = {},
    onRemoveChatAttachment: (String) -> Unit = {},
    onLoadOlderChatMessages: () -> Unit,
    onDismissChatError: () -> Unit,
    onAnswerChatQuestion: (QuestionAnswer) -> Unit,
    /** Sign-out from the sidebar. */
    onLogout: () -> Unit = {},
    /** Session ids with a live worker, for the two places that can say so: the sidebar row and the chat header. */
    runningSessionIds: Set<String> = emptySet(),
    /** The server this app is pointed at, and the two ways to change it. */
    serverBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    defaultServerBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    onChangeServer: (String) -> ServerChange = { ServerChange.Applied(serverBaseUrl) },
    onUseDefaultServer: () -> ServerChange = { ServerChange.Applied(defaultServerBaseUrl) },
    workspaceDataViewModel: WorkspaceDataViewModel? = null,
) {
    val coroutineScope = rememberCoroutineScope()
    val openInspector: () -> Unit = { navController.navigate(PabrikRoutes.NETWORK) }

    val collectedWorkspaceData by workspaceDataViewModel?.uiState?.collectAsStateWithLifecycle()
        ?: remember { mutableStateOf(WorkspaceDataState()) }
    val workspaceDataState: WorkspaceDataState = collectedWorkspaceData

    val loadWorkspaceData: (String) -> Unit = { workspaceId ->
        workspaceDataViewModel?.load(workspaceId)
    }

    // The one create flow in the app, built here because the graph is the only thing both entry points can reach: the drawer's `+` and the project screen's `+`.
    val createTask = rememberCreateTaskController(onCreateTask)

    // Which project the chat route's `+` is going to create in.
    var newChatSheetOpen by remember { mutableStateOf(false) }

    // The projects the chooser offers: the ones in the *selected* workspace, because that is the workspace the create will be posted under.
    val newChatCandidates = homeState.projects.filter {
        it.workspaceId == homeState.selectedWorkspaceId
    }

    // A `pabrik://` link or a `popUpTo(SHELL)` navigation can leave a leaf as the only destination on the back stack.
    val goBack: () -> Unit = { navController.goBackToPreviousOrShell() }

    // Leave the drawer for the full recents list.
    val openChats: (String) -> Unit = { workspaceId ->
        if (workspaceId.isNotBlank()) {
            navController.navigate(PabrikRoutes.chats(workspaceId))
        }
    }

    // Built once, here, and handed to both drawers and the project screen.
    val projectActions = ProjectsActions(
        onToggleSection = onToggleProjectsSection,
        onToggleItem = onToggleProjectExpanded,
        onOpenAllChats = { workspaceId, itemId ->
            navController.navigate(PabrikRoutes.project(workspaceId, itemId))
        },
        onRetry = onRetryProjects,
        onCreateTask = createTask::start,
    )

    // Rebuilt from the state on every emission rather than held, so it cannot fall one frame behind the rows it describes.
    val projectState = remember(homeState) {
        ProjectsState(
            expanded = homeState.isProjectsExpanded,
            items = homeState.projects,
            expandedItemIds = homeState.expandedProjectIds,
            chats = homeState.projectChats,
            isLoading = homeState.isLoadingProjects,
            errorMessage = homeState.projectsError,
            creatingTaskItemId = homeState.creatingTaskInProjectId,
        )
    }

    // A chat this app just created is opened here, and nowhere else.
    LaunchedEffect(createdChats) {
        createdChats?.collect { sessionId ->
            if (sessionId.isBlank()) return@collect
            onSelectChat(sessionId)
            onOpenSession(sessionId)
            navController.navigate(PabrikRoutes.chat(sessionId)) {
                // Replace the shell rather than stacking on it: a chat the reader just made is where they want to be, and Back from there should leave the app's list rather than …
                popUpTo(PabrikRoutes.SHELL) { inclusive = false }
                launchSingleTop = true
            }
        }
    }

    // A chat picked from the chat route's drawer *replaces* the one on screen rather than stacking on it.
    val switchChat: (String) -> Unit = { chatId ->
        onOpenSession(chatId)
        navController.navigate(PabrikRoutes.chat(chatId)) {
            popUpTo(PabrikRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }

    // Signing out is app-wide, but only the shell reads the auth phase — the chat route would happily keep painting a transcript the user can no longer act on.
    val signOut: () -> Unit = {
        onLogout()
        if (navController.currentDestination?.route != PabrikRoutes.SHELL) {
            goBack()
        }
    }

    // `NavHost` emits nothing at all when the controller has no destination, and the window then shows only the theme's background.
    val visibleDestinations by navController.visibleEntries.collectAsState()
    val currentBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStackEntry?.destination?.route

    // The launch's own state, hoisted here because two different things need it
    var plan by remember(authState.userId) { mutableStateOf<ResumePlan?>(null) }
    // Re-read when the account changes, not on every recomposition: the store is keyed by account, and a plan built for the previous one would resume the previous …
    LaunchedEffect(authState.userId) {
        // Off the main thread: this is a launch path, and the first screen is not up yet, so there is nothing to drop a frame for.
        plan = withContext(Dispatchers.IO) {
            ResumePlan(positionStore.read(authState.userId))
        }
    }

    // Whether the resume has answered, as something Compose can see.
    var resumeDecided by remember { mutableStateOf(false) }

    // The chat this launch navigated to, if it navigated to one.
    var resumedSessionId by remember { mutableStateOf<String?>(null) }

    // The resumed transcript has been put where the reader left it.
    var transcriptSettled by remember { mutableStateOf(false) }
    val onTranscriptSettled: (String?) -> Unit = { sessionId ->
        // Matched, not just recorded: a report about the chat that was open before the resume — or about no chat at all, which is what a stale state paints on the …
        if (sessionId != null && sessionId == resumedSessionId) {
            transcriptSettled = true
        }
    }

    ResumeLastPosition(
        authState = authState,
        homeState = homeState,
        navController = navController,
        // Read from the hoisted destination, not from `navController.currentDestination` inside the effect.
        currentRoute = currentRoute,
        plan = plan,
        onSelectChat = onSelectChat,
        onOpenSession = onOpenSession,
        onResumed = { sessionId -> resumedSessionId = sessionId },
        // Every consultation, answered or not — see [resumeDecided].
        onPlanConsulted = { resumeDecided = it },
    )

    // Auth answering `/api/auth/me` is not the app being ready.
    val gateIsUp = launchGateIsUp(
        authPhase = authState.phase,
        currentRoute = currentRoute,
        resumeDecided = resumeDecided,
        resumedSessionId = resumedSessionId,
        transcriptSettled = transcriptSettled,
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground),
    ) {
    // The chat bar's `+` chooser, over the graph and over `CreateTaskHost` so the two never stack.
    if (newChatSheetOpen) {
        NewChatProjectSheet(
            projects = newChatCandidates,
            onProjectPicked = { project ->
                // Closed *before* the create, for the reason the controller closes its own steps before one: the create navigates to a new chat, and a sheet left on top of that …
                newChatSheetOpen = false
                onCreateTask(
                    project.workspaceId,
                    project.id,
                    CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
                )
            },
            onDismiss = { newChatSheetOpen = false },
        )
    }

    NavHost(
        navController = navController,
        startDestination = PabrikRoutes.SHELL,
        modifier = Modifier.fillMaxSize(),
    ) {
        composable(PabrikRoutes.SHELL) {
            when (authState.phase) {
                SessionPhase.Restoring -> AuthRestoringScreen()

                // `onRetrySession` bypasses the /me cache: the user pressed "Try again" to re-check, so it has to reach the network.
                SessionPhase.NeedsRetry -> AuthRestoringScreen(
                    errorMessage = authState.errorMessage,
                    onRetry = onRetrySession,
                    onUseAnotherAccount = onUseAnotherAccount,
                    serverBaseUrl = serverBaseUrl,
                    defaultServerBaseUrl = defaultServerBaseUrl,
                    onChangeServer = onChangeServer,
                    onUseDefaultServer = onUseDefaultServer,
                )

                SessionPhase.NeedsLogin -> LoginScreen(
                    authError = authState.errorMessage,
                    isAuthenticating = authState.isAuthenticating,
                    onSignIn = { credentials: LoginCredentials ->
                        onSignIn(credentials.email, credentials.password)
                    },
                    onOpenNetworkInspector = openInspector,
                    serverBaseUrl = serverBaseUrl,
                    defaultServerBaseUrl = defaultServerBaseUrl,
                    onChangeServer = onChangeServer,
                    onUseDefaultServer = onUseDefaultServer,
                )

                SessionPhase.Authenticated -> MobileHomeScreen(
                    workspaces = homeState.workspaces,
                    chats = homeState.chats,
                    initialWorkspaceId = homeState.selectedWorkspaceId,
                    initialChatId = homeState.selectedChatId,
                    onWorkspaceSelected = onSelectWorkspace,
                    onChatSelected = onSelectChat,
                    onOpenChat = { sessionId ->
                        // Open the session before navigating: the route stays on the back stack, so returning to it must not show an empty transcript waiting on a load that never ran.
                        onOpenSession(sessionId)
                        navController.navigate(PabrikRoutes.chat(sessionId))
                    },
                    onOpenNetworkInspector = openInspector,
                    isLoading = homeState.isLoading,
                    errorMessage = homeState.errorMessage,
                    onRetry = onRetryHome,
                    runningSessionIds = runningSessionIds,
                    isAuthEnabled = authState.isAuthEnabled,
                    signedInEmail = authState.userEmail,
                    isLoggingOut = authState.isLoggingOut,
                    onLogout = signOut,
                    // The shell's drawer is the same drawer the chat route's hamburger opens, so it gets the same sections and the same fold state.
                    projects = projectState,
                    projectActions = projectActions,
                    recentsExpanded = homeState.isRecentsExpanded,
                    onToggleRecentsSection = onToggleRecentsSection,
                    // The destination row, fed from the same state that decides whether to offer it — one notion of "there is more", so the button can never appear over a list that …
                    hasMoreChats = homeState.hasMoreChats,
                    chatsTotal = homeState.chatsTotal,
                    onOpenAllChats = { openChats(homeState.selectedWorkspaceId.orEmpty()) },
                    // The drawer's top-level New Chat.
                    isCreatingChat = homeState.creatingTaskInProjectId != null,
                    onNewChat = onNewChat,
                    onOpenDocuments = {
                        homeState.selectedWorkspaceId?.let {
                            navController.navigate(PabrikRoutes.documents(it))
                        }
                    },
                    onOpenSettings = { navController.navigate(PabrikRoutes.SETTINGS) },
                    onOpenNotifications = { navController.navigate(PabrikRoutes.NOTIFICATIONS) },
                )
            }
        }

        composable(
            route = PabrikRoutes.CHAT,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_SESSION_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "pabrik://chat/{sessionId}" },
            ),
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString(PabrikRoutes.ARG_SESSION_ID).orEmpty()
            // Collected here, not sampled above the `NavHost`.
            val chatState by chatState.collectAsState()
            // The id in the route is the truth.
            LaunchedEffect(sessionId) {
                if (sessionId.isNotBlank() && chatState.sessionId != sessionId) {
                    onOpenSession(sessionId)
                }
            }

            // The chat's only way out, and the reason it is not a dead end.
            BackHandler { goBack() }

            ChatScreen(
                state = chatState,
                chatTitle = chatTitleFor(sessionId, homeState.chats),
                // The only signal that the launch has somewhere to show.
                onTranscriptSettled = onTranscriptSettled,
                // The route's id, not `chatState.sessionId`: a deep link that has not finished opening yet still has to report the run it is about to show.
                isRunning = sessionId in runningSessionIds,
                onDraftChanged = onChatDraftChanged,
                onSend = onSendChatMessage,
                onStop = onStopChatRun,
                onRefreshQueue = onRefreshChatQueue,
                onUseQueuedMessage = onUseQueuedChatMessage,
                onSelectModel = onSelectChatModel,
                onAttachmentPicked = onAttachChatImage,
                onRemoveAttachment = onRemoveChatAttachment,
                onLoadOlder = onLoadOlderChatMessages,
                onDismissError = onDismissChatError,
                onAnswer = onAnswerChatQuestion,
                // The hamburger opens the same sidebar the shell shows — a workspace's chats, a workspace picker and sign-out — because a reader in a chat is far more often on …
                drawerContent = { dismissDrawer ->
                    RecentsDrawerContent(
                        workspaces = homeState.workspaces,
                        chats = homeState.chats,
                        selectedWorkspaceId = homeState.selectedWorkspaceId,
                        // The route's session, not the list's memory: a deep link opens a chat the sidebar never marked as selected.
                        selectedChatId = chatDrawerSelectedChatId(sessionId, homeState.selectedChatId),
                        onWorkspaceSelected = onSelectWorkspace,
                        onChatSelected = { chatId ->
                            onSelectChat(chatId)
                            switchChat(chatId)
                        },
                        onOpenChat = dismissDrawer,
                        isLoading = homeState.isLoading,
                        errorMessage = homeState.errorMessage,
                        onRetry = onRetryHome,
                        // The same set the shell's drawer shows it in: a chat busy in the background is busy in both copies of the list, and this is the one the reader is looking at.
                        runningSessionIds = runningSessionIds,
                        isAuthEnabled = authState.isAuthEnabled,
                        signedInEmail = authState.userEmail,
                        isLoggingOut = authState.isLoggingOut,
                        onLogout = signOut,
                        projects = projectState,
                        projectActions = projectActions,
                        // Straight off `homeState` rather than a local: the reader folded these sections in the shell's drawer, and a copy held here would forget it the moment they …
                        recentsExpanded = homeState.isRecentsExpanded,
                        onToggleRecentsSection = onToggleRecentsSection,
                        // Same row, same reason: the shell's drawer and the chat route's are one drawer, so a destination one offers and the other does not is a drawer that forgets …
                        hasMoreChats = homeState.hasMoreChats,
                        chatsTotal = homeState.chatsTotal,
                        // Dismiss explicitly, the way `onOpenChat` does two lines up.
                        onOpenAllChats = {
                            openChats(homeState.selectedWorkspaceId.orEmpty())
                            dismissDrawer()
                        },
                        // The drawer's "New Chat", wired here because the bar stopped offering its own.
                        onNewChat = {
                            newChatSheetOpen = true
                            dismissDrawer()
                        },
                        isCreatingChat = homeState.creatingTaskInProjectId != null,
                    )
                },
            )
        }

        composable(
            route = PabrikRoutes.CHATS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "pabrik://chats/{workspaceId}" },
            ),
        ) { backStackEntry ->
            // The drawer's five rows are already in `HomeUiState` — that is the point of sharing the ViewModel, so opening this page costs one request and only the pages …
            val routeWorkspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID)
                .orEmpty()
            val routeChats = if (routeWorkspaceId == homeState.selectedWorkspaceId) {
                homeState.chats
            } else {
                // A cold deep link: nothing was fetched for this scope, and showing the previous workspace's chats under this one's title would be worse than showing nothing.
                emptyList()
            }

            RecentsChatsScreen(
                workspaceName = homeState.workspaces
                    .firstOrNull { it.id == routeWorkspaceId }
                    ?.displayName
                    ?: "Chats",
                chats = routeChats,
                selectedChatId = homeState.selectedChatId,
                runningSessionIds = runningSessionIds,
                // The ViewModel's own "keep asking", not `has_more` re-derived here — it is the only place that knows about the in-flight page and whether the list has covered …
                hasMore = homeState.canLoadMoreChats,
                isLoadingMore = homeState.isLoadingMoreChats,
                // A page that did not arrive is said out loud, and retryable by tapping.
                loadMoreError = homeState.loadMoreChatsError,
                isLoading = homeState.isLoading && routeChats.isEmpty(),
                onChatSelected = onSelectChat,
                onOpenChat = { sessionId ->
                    // Push, not replace: there IS a list under this one and Back from the chat must return to it — the same reason the project route pushes.
                    onOpenSession(sessionId)
                    navController.navigate(PabrikRoutes.chat(sessionId))
                },
                onLoadMore = onLoadMoreChats,
                onBack = goBack,
            )
        }

        composable(
            route = PabrikRoutes.PROJECT,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "pabrik://project/{workspaceId}/{itemId}" },
            ),
        ) { backStackEntry ->
            val itemId = backStackEntry.arguments?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()

            // Same rule as the chat route, same reason: this route sits on the back stack, so returning to it must not find a project whose chats were never asked for.
            LaunchedEffect(itemId) {
                if (itemId.isNotBlank()) onEnsureProjectChatsLoaded(itemId)
            }

            ProjectChatsScreen(
                // The route's ids, not the loaded list's memory: a deep link names a project the drawer never touched.
                projectName = homeState.projects
                    .firstOrNull { it.id == itemId }
                    ?.displayName
                    ?: "Project",
                // A narrow slice, not the whole `HomeUiState`.
                page = homeState.projectChats[itemId],
                selectedChatId = homeState.selectedChatId,
                runningSessionIds = runningSessionIds,
                isLoading = itemId in homeState.isLoadingMoreProjectChats ||
                    (homeState.isLoadingProjects && homeState.projectChats[itemId] == null),
                onChatSelected = onSelectChat,
                onOpenChat = { sessionId ->
                    // The shell's own `onOpenChat` navigates normally, because there is no project list under it.
                    onOpenSession(sessionId)
                    navController.navigate(PabrikRoutes.chat(sessionId))
                },
                onLoadMore = { onLoadMoreProjectChats(itemId) },
                onCreateTask = {
                    // The same `start` the drawer's `+` uses, with a summary rebuilt from this route's ids.
                    createTask.start(
                        ProjectSummary(
                            id = itemId,
                            workspaceId = backStackEntry.arguments
                                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID)
                                .orEmpty(),
                            itemType = homeState.projects
                                .firstOrNull { it.id == itemId }
                                ?.itemType
                                .orEmpty(),
                            name = homeState.projects
                                .firstOrNull { it.id == itemId }
                                ?.name
                                .orEmpty(),
                        ),
                    )
                },
                isCreatingTask = homeState.creatingTaskInProjectId == itemId,
                onBack = goBack,
            )
        }

        composable(
            route = PabrikRoutes.NETWORK,
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://network" }),
        ) {
            NetworkInspectorScreen(
                onBack = goBack,
                onOpenRecord = { recordId -> navController.navigate(PabrikRoutes.recordDetail(recordId)) },
            )
        }

        composable(
            route = PabrikRoutes.RECORD_DETAIL,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_RECORD_ID) { type = NavType.LongType },
            ),
            deepLinks = listOf(
                navDeepLink { uriPattern = "pabrik://network/record/{recordId}" },
            ),
        ) { backStackEntry ->
            val recordId = backStackEntry.arguments?.getLong(PabrikRoutes.ARG_RECORD_ID)
            NetworkRecordDetailScreen(
                recordId = recordId,
                onBack = goBack,
                onReplay = { entry ->
                    coroutineScope.launch {
                        withContext(Dispatchers.IO) { replayNetworkEntry(entry) }
                    }
                },
            )
        }

        composable(
            route = PabrikRoutes.SETTINGS,
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://settings" }),
        ) {
            UserSettingsScreen(
                userEmail = authState.userEmail,
                serverBaseUrl = serverBaseUrl,
                onBack = goBack,
            )
        }

        composable(
            route = PabrikRoutes.WORKSPACE_SETTINGS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://workspace/{workspaceId}/settings" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            WorkspaceSettingsScreen(state = workspaceDataState, onBack = goBack)
        }

        composable(
            route = PabrikRoutes.DOCUMENTS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://documents/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            DocumentsScreen(state = workspaceDataState, onBack = goBack)
        }

        composable(
            route = PabrikRoutes.DOCUMENT,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_DOCUMENT_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://doc/{workspaceId}/{documentId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val documentId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_DOCUMENT_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Document",
                workspaceId = workspaceId,
                itemId = documentId,
                sections = listOf(
                    FeatureSection("Document", listOf(FeatureRow("ID", documentId))),
                ),
                onBack = goBack,
            )
        }

        composable(
            route = PabrikRoutes.NOTIFICATIONS,
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://notifications" }),
        ) {
            NotificationsScreen(notifications = emptyList(), onBack = goBack)
        }

        composable(
            route = PabrikRoutes.KANBAN_SETTINGS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://kanban-settings/{workspaceId}/{itemId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val itemId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Kanban settings",
                workspaceId = workspaceId,
                itemId = itemId,
                sections = listOf(
                    FeatureSection("Overview", listOf(
                        FeatureRow("Workspace", workspaceId),
                        FeatureRow("Item", itemId),
                    )),
                ),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.AGENT,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://agent/{workspaceId}/{itemId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val itemId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Agent",
                workspaceId = workspaceId,
                itemId = itemId,
                sections = listOf(
                    FeatureSection("Overview", listOf(
                        FeatureRow("Workspace", workspaceId),
                        FeatureRow("Item", itemId),
                    )),
                ),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.DESIGN,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://design/{workspaceId}/{itemId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val itemId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Design",
                workspaceId = workspaceId,
                itemId = itemId,
                sections = listOf(
                    FeatureSection("Overview", listOf(
                        FeatureRow("Workspace", workspaceId),
                        FeatureRow("Item", itemId),
                    )),
                ),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.ROUTINE,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://routine/{workspaceId}/{itemId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val itemId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Routine",
                workspaceId = workspaceId,
                itemId = itemId,
                sections = listOf(
                    FeatureSection("Overview", listOf(
                        FeatureRow("Workspace", workspaceId),
                        FeatureRow("Item", itemId),
                    )),
                ),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.GIT,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
                navArgument(PabrikRoutes.ARG_ITEM_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://git/{workspaceId}/{itemId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            val itemId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_ITEM_ID).orEmpty()
            ItemFeatureScreen(
                featureName = "Git",
                workspaceId = workspaceId,
                itemId = itemId,
                sections = listOf(
                    FeatureSection("Overview", listOf(
                        FeatureRow("Workspace", workspaceId),
                        FeatureRow("Item", itemId),
                    )),
                ),
                onBack = goBack,
            )
        }

        composable(
            route = PabrikRoutes.MEMORY,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://memory/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "Memory",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "Memory"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.SECRETS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://secrets/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "Secrets",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "Secrets"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.MEMBERS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://members/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "Members",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "Members"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.SKILLS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://skills/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "Skills",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "Skills"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.MCP,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://mcp/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "MCP servers",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "MCP servers"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.LLM_CONFIG,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://llm-config/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "LLM config",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "LLM config"),
                onBack = goBack,
            )
        }
        composable(
            route = PabrikRoutes.TOOLS,
            arguments = listOf(
                navArgument(PabrikRoutes.ARG_WORKSPACE_ID) { type = NavType.StringType },
            ),
            deepLinks = listOf(navDeepLink { uriPattern = "pabrik://tools/{workspaceId}" }),
        ) { backStackEntry ->
            val workspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID).orEmpty()
            LaunchedEffect(workspaceId) { loadWorkspaceData(workspaceId) }
            ItemFeatureScreen(
                featureName = "Tools",
                workspaceId = workspaceId,
                itemId = null,
                sections = workspaceFeatureSections(workspaceId, workspaceDataState, "Tools"),
                onBack = goBack,
            )
        }
    }

    // AFTER the `NavHost`, not before it: a `Box` draws its later children on top, and the board's create form is a full-screen overlay in this composition rather …
    CreateTaskHost(
        controller = createTask,
        isSubmitting = homeState.creatingTaskInProjectId != null,
        errorMessage = homeState.taskCreateError,
        // The board's form opens straight onto the card form (there is no type picker for a board — see `createTaskStartDecision`), so these three reads start the moment …
        kanbanData = NewTaskDialogData(
            columns = homeState.kanbanColumns,
            profiles = homeState.kanbanProfiles,
            serverHome = homeState.kanbanServerHome,
            isLoading = homeState.isLoadingKanbanFormData,
        ),
        onRequestKanbanData = onLoadKanbanFormData,
    )

        if (visibleDestinations.isEmpty()) {
            NavigationLostScreen(onReturnHome = goBack)
        }

        // Over the graph, and *after* the recovery screen, so a dead back stack keeps the one button that fixes it.
        if (gateIsUp && visibleDestinations.isNotEmpty()) {
            LaunchGateScreen()
        }
    }
}

/** Reopens the chat the user was last in, when the app was closed and opened again. */
@Composable
private fun ResumeLastPosition(
    authState: AuthUiState,
    homeState: HomeUiState,
    navController: NavHostController,
    /** Hoisted, because the launch gate above reads whether it has answered. */
    plan: ResumePlan?,
    /** The current destination, hoisted from `currentBackStackEntryAsState`. */
    currentRoute: String?,
    onSelectChat: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    /** The chat that was navigated to, handed up so the gate can wait for its transcript. */
    onResumed: (String) -> Unit,
    /** Called every time the plan is asked, with whether it has answered. */
    onPlanConsulted: (Boolean) -> Unit,
) {
    LaunchedEffect(
        authState.phase,
        currentRoute,
        homeState.selectedWorkspaceId,
        homeState.chats,
        homeState.isLoading,
        plan,
    ) {
        val sessionId = sessionToResume(
            authPhase = authState.phase,
            currentRoute = currentRoute,
            plan = plan,
            chats = homeState.chats,
            selectedWorkspaceId = homeState.selectedWorkspaceId,
            isLoading = homeState.isLoading,
        )
        // Read *after* the question, because `resolveSession` is what latches.
        onPlanConsulted(plan?.isDecided == true)
        if (sessionId == null) return@LaunchedEffect

        // The session is opened before the navigation for the same reason the sidebar's own `onOpenChat` is: the route stays on the back stack, so returning to it must …
        onSelectChat(sessionId)
        onOpenSession(sessionId)
        // Before the navigation, so the frame the gate lifts in already knows which transcript it is waiting for.
        onResumed(sessionId)
        navController.navigate(PabrikRoutes.chat(sessionId))
    }
}

/** The app is showing no destination at all. */
@Composable
internal fun NavigationLostScreen(
    onReturnHome: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(24.dp)
            .testTag("navigation_lost"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "This screen is not available",
            style = MaterialTheme.typography.titleMedium,
            color = PabrikText,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "The app lost track of where it was. Nothing is missing from your chats.",
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikMuted,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        Button(
            onClick = onReturnHome,
            modifier = Modifier.testTag("navigation_lost_home"),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = PabrikAccent,
                contentColor = PabrikBackground,
            ),
        ) {
            Text(text = "Back to chats")
        }
    }
}

/** The title for a chat route. */
private fun chatTitleFor(sessionId: String, chats: List<ChatSummary>): String =
    chats.firstOrNull { chat -> chat.id == sessionId }?.displayTitle
        ?: sessionId.ifBlank { "Chat" }

private fun workspaceFeatureSections(
    workspaceId: String,
    state: WorkspaceDataState,
    featureName: String,
): List<FeatureSection> = when (featureName) {
    "Secrets" -> listOf(
        FeatureSection("Secrets (${state.secrets.size})", state.secrets.map {
            FeatureRow(it.name, "••••••••", it.description.ifBlank { it.createdAt })
        }),
    )
    "Members" -> listOf(
        FeatureSection("Members (${state.members.size})", state.members.map {
            FeatureRow(it.name.ifBlank { it.email }, it.role, it.email)
        }),
    )
    "Skills" -> listOf(
        FeatureSection("Skills (${state.skills.size})", state.skills.map {
            FeatureRow(it.name, if (it.isCanAutoImprove) "auto-improve" else "", it.description)
        }),
    )
    "Memory" -> listOf(
        FeatureSection("Memories (${state.memories.size})", state.memories.map {
            FeatureRow(it.id, it.tags.joinToString(", "), it.content)
        }),
    )
    "MCP servers" -> listOf(
        FeatureSection("MCP servers (${state.config?.mcpServers?.size ?: 0})",
            state.config?.mcpServers?.map {
                FeatureRow(it.name, it.url)
            }.orEmpty()),
    )
    "LLM config" -> listOf(
        FeatureSection("Profiles (${state.config?.profiles?.size ?: 0})",
            state.config?.profiles?.map {
                FeatureRow(it.name, it.model, it.baseUrl)
            }.orEmpty()),
    )
    "Tools" -> listOf(
        FeatureSection("Runtime", listOf(
            FeatureRow("Chat view", state.config?.chatView.orEmpty()),
            FeatureRow("Active profile", state.config?.activeProfile.orEmpty()),
        )),
    )
    else -> listOf(
        FeatureSection("Overview", listOf(FeatureRow("Workspace", workspaceId))),
    )
}
