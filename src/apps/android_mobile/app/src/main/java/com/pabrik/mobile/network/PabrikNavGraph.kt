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
import com.pabrik.mobile.ui.FeaturePlaceholderScreen
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Every view in the app is a route, so each one survives a process restart and
 * `adb shell am start -a android.intent.action.VIEW -d pabrik://…` lands on it
 * directly — the Android equivalent of opening DevTools, and of sharing a link
 * to a specific chat.
 */
object PabrikRoutes {
    const val SHELL = "app"
    const val CHAT = "chat/{sessionId}"
    const val ARG_SESSION_ID = "sessionId"
    const val NETWORK = "network"
    const val RECORD_DETAIL = "network/record/{recordId}"
    const val ARG_RECORD_ID = "recordId"

    // Feature routes (F05 scaffolding). Real screens replace placeholders.
    const val SETTINGS = "settings"
    const val WORKSPACE_SETTINGS = "workspace/{workspaceId}/settings"
    const val KANBAN_SETTINGS = "workspace/{workspaceId}/project/{itemId}/settings"
    const val DOCUMENTS = "workspace/{workspaceId}/doc/{documentId}"
    const val AGENT = "workspace/{workspaceId}/agent/{itemId}"
    const val DESIGN = "workspace/{workspaceId}/design/{itemId}"
    const val ROUTINE_DETAIL = "workspace/{workspaceId}/routine/{itemId}"
    const val GIT = "workspace/{workspaceId}/git"
    const val MEMORY = "workspace/{workspaceId}/memory/{itemId}"
    const val SECRETS = "workspace/{workspaceId}/secrets"
    const val MEMBERS = "workspace/{workspaceId}/members"
    const val SKILLS = "workspace/{workspaceId}/skills"
    const val MCP = "workspace/{workspaceId}/mcp"
    const val LLM_CONFIG = "workspace/{workspaceId}/llm"
    const val TOOLS = "workspace/{workspaceId}/tools"
    const val NOTIFICATIONS = "notifications"

    /**
     * One project's chats, full-screen.
     *
     * Two ids, not one, and that is forced by the wire rather than chosen: every
     * item endpoint in the backend is nested under
     * `/api/workspaces/:workspace_id/items/…` — including the read one — so
     * there is no endpoint anywhere that resolves a project from its id alone.
     * A short `pabrik://project/{itemId}` would arrive on a *cold process* with
     * no `HomeViewModel` state to resolve the workspace from, and the only way
     * to learn it would be the every-workspace-every-task fetch. `chat` gets
     * away with one id because
     * `GET /api/llm/session/{id}/messages?limit=1` genuinely needs nothing but
     * the session id. One id where the wire allows one, two where it does not.
     *
     * Registered as a *sibling* of [CHAT], not nested under it: a project is
     * not a chat, and nesting would make Back from one mean "pop the other".
     */
    const val PROJECT = "project/{workspaceId}/{itemId}"
    const val ARG_WORKSPACE_ID = "workspaceId"
    const val ARG_ITEM_ID = "itemId"

    /**
     * Every chat in one workspace, full-screen.
     *
     * The destination behind the drawer's `See all chats ›` row, and the third
     * piece of the shape the project section already uses: a preview inline, a
     * button, a page behind it. A *sibling* of [CHAT] and [PROJECT] for the
     * same reason they are siblings of each other — nesting it under either
     * would make Back from a chat mean "pop the list".
     *
     * One id, unlike [PROJECT]'s two, and that is forced by the wire in the
     * other direction: `/api/session?workspace_id=…` needs nothing but the
     * workspace, so a two-argument route here would be a second id with
     * nothing to resolve it from.
     */
    const val CHATS = "chats/{workspaceId}"

    fun chat(sessionId: String): String = "chat/${UriEncoding.encode(sessionId)}"

    fun recordDetail(recordId: Long): String = "network/record/$recordId"

    fun project(workspaceId: String, itemId: String): String =
        "project/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"

    fun chats(workspaceId: String): String =
        "chats/${UriEncoding.encode(workspaceId)}"
}

/**
 * What one back action should do.
 *
 * The distinction is not a nicety. `NavController.popBackStack()` with no
 * argument is **inclusive** — it pops the current destination *and* stops at the
 * graph, and `dispatchOnDestinationChanged()` then drops that graph from the top
 * of the queue as well. At a one-destination depth that single call therefore
 * leaves the controller with no destination at all, reports `false` while doing
 * it, and `NavHost` renders *nothing* for an empty back stack: no destination,
 * no screen, nothing to press, just the theme's window background. Checking the
 * return value is not a defence, because the damage is already done by the time
 * the call returns.
 *
 * The system Back button cannot cause this: `updateOnBackPressedCallbackEnabled`
 * keeps the callback disabled while `destinationCountOnBackStack <= 1`. Only an
 * app-initiated pop reaches that depth, which is what the back arrows here are.
 */
internal enum class BackAction {
    /** A real destination sits under this one, so pop back onto it. */
    PopPrevious,

    /**
     * Nothing but the graph sits underneath — a `popUpTo(SHELL)` navigation, or a
     * deep link that never pushed the shell. Rebuild onto the shell rather than
     * leave `NavHost` with nothing to draw.
     */
    ReturnToShell,
}

/**
 * [hasDestinationBelow] is "is there a non-graph entry under the current one",
 * which is false both on the shell and on a leaf with no shell beneath it. The
 * two want different answers, so the caller has to tell them apart; see
 * [goBackToPreviousOrShell].
 */
internal fun backActionFor(hasDestinationBelow: Boolean): BackAction =
    if (hasDestinationBelow) BackAction.PopPrevious else BackAction.ReturnToShell

/**
 * One back action, for an app with a single activity.
 *
 * Top level and free of Compose so it can be driven against a real
 * `NavController` on a device: the whole defect is a property of the controller,
 * not of how the screens are drawn.
 */
internal fun NavHostController.goBackToPreviousOrShell() {
    val below = previousBackStackEntry?.destination
    when (backActionFor(below != null && below !is NavGraph)) {
        BackAction.PopPrevious -> popBackStack()

        // Non-inclusive: the shell is the one entry that must survive. When it is
        // not on the stack the library logs and skips the pop, and the shell is
        // pushed on top — the user lands on the home screen either way instead of
        // on nothing.
        BackAction.ReturnToShell -> navigate(PabrikRoutes.SHELL) {
            popUpTo(PabrikRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }
}

/**
 * Minimal percent-encoding for a path segment.
 *
 * Session ids are server-generated (`sess_<ts>_<hex>`) and contain nothing that
 * needs escaping, but a deep link is attacker-shaped input and `navDeepLink`
 * matches patterns literally — an unescaped `/` or `?` in a hand-written
 * `pabrik://chat/…` URI would otherwise split the path and navigate somewhere
 * unintended.
 */
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
    /**
     * The chat transcript, as the flow it is — collected *inside* the chat
     * destination, never at the top of the tree.
     *
     * A `ChatUiState` value parameter is a `StateFlow` sample taken above the
     * `NavHost`, and every emission of it — every stream delta, every page,
     * every keystroke in the composer's draft — then recomposes the whole
     * `PabrikNavGraph`: the drawer, the `NavHost` builder, and every composed
     * destination. The transcript is the only thing that changed, and it is the
     * one thing that is already virtualized.
     *
     * **A `() -> ChatUiState` provider was the wrong fix for that, and it is
     * what made the composer untypeable.** Calling a lambda during composition
     * does not subscribe anything: `StateFlow.value` is a plain field read, not
     * a Compose snapshot read, so the destination recomposed only when some
     * *other* collected state happened to change — the home state, or the
     * worker set. Streaming therefore appeared to work, because a run does
     * register a worker and does move the home list.
     *
     * Typing is the one interaction in this app with nothing else changing
     * behind it. `onDraftChanged` wrote to the flow, the destination never
     * observed the write, the controlled `TextField` kept the `value` it was
     * composed with, and every keystroke was swallowed: the cursor blinked and
     * nothing arrived. Same for the composer clearing itself after a send and
     * for the inline Stop — each is a state change with no second source.
     *
     * So the flow is passed and collected by the destination, which is what
     * this parameter always claimed to do. `collectAsState` inside a
     * `composable {}` block subscribes that block's recompose scope and no
     * other, so the promise at the top of this comment still holds.
     */
    chatState: StateFlow<ChatUiState>,
    /**
     * The position the last run left behind. Read once per launch and never
     * written from here — a persisted position that the app edits as it resumes
     * is a position it can no longer be sure about.
     */
    positionStore: LastPositionStore,
    onSelectWorkspace: (String) -> Unit,
    onSelectChat: (String) -> Unit,
    /**
     * The four project actions the drawer and the project screen share.
     *
     * Passed in rather than reached for, so a graph rendered with inert data in
     * a test needs no `HomeViewModel` behind it.
     */
    onToggleProjectsSection: () -> Unit = {},
    onToggleProjectExpanded: (String) -> Unit = {},
    onEnsureProjectChatsLoaded: (String) -> Unit = {},
    onLoadMoreProjectChats: (String) -> Unit = {},
    /**
     * The full-screen recents list's next page.
     *
     * The drawer never pages — its five rows are one request and a destination
     * row — so this is reached only by [PabrikRoutes.CHATS]. It is a callback
     * rather than a direct `loadMoreChats()` for the same reason the project
     * actions are: a graph rendered with inert data in a test needs no
     * ViewModel behind it.
     */
    onLoadMoreChats: () -> Unit = {},
    onRetryProjects: () -> Unit = {},
    /**
     * Create a chat or a memory under a project.
     *
     * A three-argument callback rather than the whole flow, because the graph
     * owns navigation and a create's *result* is a navigation; the sheet's own
     * state stays with the UI, and this is the one thing it needs from the
     * ViewModel.
     */
    onCreateTask: (String, String, CreateTaskRequest) -> Unit = { _, _, _ -> },
    /**
     * Fill in the board's "New task" form: its columns, the profile list, and
     * the server's home for the worktree prefill.
     *
     * A callback for the same reason as [onCreateTask] — the graph composes, the
     * ViewModel fetches — and it is the graph's job because [CreateTaskHost] is
     * mounted here, over the `NavHost`, so this is the one place that sees the
     * form open and the state that answers it.
     */
    onLoadKanbanFormData: (String, String) -> Unit = { _, _ -> },
    /**
     * The drawer's top-level "New Chat": create a chat in the workspace's
     * default project and open it. Kept separate from [onCreateTask] because
     * this one chooses the project (there is only ever one) and closes the
     * drawer, which a per-project create must not do.
     */
    onNewChat: () -> Unit = {},
    /**
     * Session ids of chats that were just created, to open.
     *
     * A flow, not a callback into the graph, because the create finishes on a
     * coroutine the graph does not own and the navigation has to happen after
     * the row is painted. Collected once here so the chat opens from wherever
     * the flow was started — the drawer, or the project screen.
     */
    createdChats: Flow<String>? = null,
    /** Clear the last create's complaint. */
    onDismissTaskCreateError: () -> Unit = {},
    /**
     * Fold the sidebar's Recents section away, or unfold it.
     *
     * The chat route's drawer and the shell's drawer are one drawer, so this
     * reaches both — a fold made in one and forgotten in the other is a drawer
     * that springs open on the reader every time they switch screens.
     */
    onToggleRecentsSection: () -> Unit = {},
    /**
     * Show the whole Recents list instead of its first few rows, or put the
     * preview back.
     *
     * Reaches both drawers for the same reason [onToggleRecentsSection] does:
     * they are one drawer, and a preview the reader expanded in the shell must
     * still be expanded when they open the drawer from inside a chat.
     */
    onRetryHome: () -> Unit,
    onOpenSession: (String) -> Unit,
    onChatDraftChanged: (String) -> Unit,
    onSendChatMessage: () -> Unit,
    onStopChatRun: () -> Unit,
    /**
     * Re-read the queue behind the composer's panel, and put a waiting turn's
     * text back in the box.
     *
     * Two `ChatViewModel` methods rather than one: the panel's whole value is
     * that it is authoritative when opened, so a read that happened somewhere
     * else and was passed in would be a stale list dressed as a current one.
     */
    onRefreshChatQueue: () -> Unit = {},
    onUseQueuedChatMessage: (QueuedChatMessage) -> Unit = {},
    /**
     * Put a chat on a different profile, or clear the override with `""`.
     *
     * The `ChatViewModel`'s own method rather than something the graph builds:
     * the graph owns navigation and wiring, and this is a state change plus a
     * `PUT` that the ViewModel already knows how to fail honestly.
     */
    onSelectChatModel: (String) -> Unit = {},
    /**
     * A picked image and the removal of an attached one.
     *
     * Defaulted like every other chat action after `onStopChatRun` so a graph
     * rendered with inert data in a test does not have to spell out the
     * attachment surface to get to the part it is about.
     */
    onAttachChatImage: (String) -> Unit = {},
    onRemoveChatAttachment: (String) -> Unit = {},
    onLoadOlderChatMessages: () -> Unit,
    onDismissChatError: () -> Unit,
    onAnswerChatQuestion: (QuestionAnswer) -> Unit,
    /**
     * Sign-out from the sidebar. A separate parameter from
     * [onUseAnotherAccount] only because the two start from different screens —
     * the caller is expected to point both at the same action.
     */
    onLogout: () -> Unit = {},
    /**
     * Session ids with a live worker, for the two places that can say so: the
     * sidebar row and the chat header.
     *
     * One hoisted set for both because they are on different routes and would
     * otherwise each need their own copy of the same fact. Defaulted so a graph
     * rendered with inert data needs no worker behind it.
     */
    runningSessionIds: Set<String> = emptySet(),
    /**
     * The server this app is pointed at, and the two ways to change it.
     *
     * Sampled as a **value** above the `NavHost`, not collected here. The
     * server only ever changes from a dialog the person opened themselves, and
     * the change already re-places every auth-scoped view — so there is nothing
     * for a subscription to save here, and collecting it would put a
     * recomposition of the whole graph (drawer included) on the critical path of
     * every keystroke in the field.
     */
    serverBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    defaultServerBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    onChangeServer: (String) -> ServerChange = { ServerChange.Applied(serverBaseUrl) },
    onUseDefaultServer: () -> ServerChange = { ServerChange.Applied(defaultServerBaseUrl) },
) {
    val coroutineScope = rememberCoroutineScope()
    val openInspector: () -> Unit = { navController.navigate(PabrikRoutes.NETWORK) }

    // The one create flow in the app, built here because the graph is the only
    // thing both entry points can reach: the drawer's `+` and the project
    // screen's `+`. Two controllers would be two pickers that agree today and
    // not tomorrow.
    val createTask = rememberCreateTaskController(onCreateTask)

    // Which project the chat route's `+` is going to create in.
    //
    // Held here, above the `NavHost`, for the same reason `createTask` is: the
    // press happens on one route and the navigation that follows happens on
    // another. A local `remember` inside the chat destination would be
    // destroyed by the very navigation the create triggers, which is the same
    // trap `createdChats` is a flow rather than a callback for.
    var newChatSheetOpen by remember { mutableStateOf(false) }

    // The projects the chooser offers: the ones in the *selected* workspace,
    // because that is the workspace the create will be posted under. Offering
    // a project from another workspace here would send a `POST` whose path
    // names a workspace the reader is not looking at.
    val newChatCandidates = homeState.projects.filter {
        it.workspaceId == homeState.selectedWorkspaceId
    }

    // A `pabrik://` link or a `popUpTo(SHELL)` navigation can leave a leaf as the
    // only destination on the back stack. The back arrow on those screens used to
    // call the inclusive `popBackStack()`, which emptied the back stack and left
    // `NavHost` drawing nothing at all. See [BackAction]. The chat route has no
    // back arrow and no "All chats" row — its way out is the system Back button,
    // which the chat destination claims with a [BackHandler] for exactly that
    // reason.
    val goBack: () -> Unit = { navController.goBackToPreviousOrShell() }

    // Leave the drawer for the full recents list.
    //
    // A no-op on a blank workspace id rather than a guess: the route names its
    // own workspace, and `chats/` with an empty segment would resolve to
    // nothing while looking like it worked.
    val openChats: (String) -> Unit = { workspaceId ->
        if (workspaceId.isNotBlank()) {
            navController.navigate(PabrikRoutes.chats(workspaceId))
        }
    }

    // Built once, here, and handed to both drawers and the project screen.
    //
    // The holder exists so the wiring is a single expression the reader can
    // check against the four actions above: three that stay in the drawer
    // (reshape the list in place) and one that leaves it (a destination). The
    // split is the whole drawer contract, and naming the actions in one place
    // is what keeps a fourth caller from being added without a decision about
    // which side of that line it falls on.
    val projectActions = ProjectsActions(
        onToggleSection = onToggleProjectsSection,
        onToggleItem = onToggleProjectExpanded,
        onOpenAllChats = { workspaceId, itemId ->
            navController.navigate(PabrikRoutes.project(workspaceId, itemId))
        },
        onRetry = onRetryProjects,
        onCreateTask = createTask::start,
    )

    // Rebuilt from the state on every emission rather than held, so it cannot
    // fall one frame behind the rows it describes. It is a value class over
    // immutable data, so Compose treats an unchanged list as unchanged and skips
    // recomposing every row below it.
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
    //
    // Collected at the graph rather than inside a destination because the create
    // can be started from the drawer on the shell and the navigation has to
    // work from wherever the reader happens to be — including from inside the
    // project screen, where a plain `navigate` would leave the project list
    // underneath the new chat and make Back return to a screen the reader has
    // already finished with.
    LaunchedEffect(createdChats) {
        createdChats?.collect { sessionId ->
            if (sessionId.isBlank()) return@collect
            onSelectChat(sessionId)
            onOpenSession(sessionId)
            navController.navigate(PabrikRoutes.chat(sessionId)) {
                // Replace the shell rather than stacking on it: a chat the
                // reader just made is where they want to be, and Back from
                // there should leave the app's list rather than walk back
                // through a chat they never opened.
                popUpTo(PabrikRoutes.SHELL) { inclusive = false }
                launchSingleTop = true
            }
        }
    }

    // A chat picked from the chat route's drawer *replaces* the one on screen
    // rather than stacking on it. Pushing would make system Back walk back
    // through every chat opened this session, and the reader is switching
    // between chats, not moving through a history of them.
    //
    // On a deep-linked chat the shell is not underneath, so the popUpTo finds
    // nothing and the new chat lands on top of the old one. Back then returns
    // to the chat that was open, which is a route onwards rather than a dead
    // end — and the system Back button still reaches the shell.
    val switchChat: (String) -> Unit = { chatId ->
        onOpenSession(chatId)
        navController.navigate(PabrikRoutes.chat(chatId)) {
            popUpTo(PabrikRoutes.SHELL) { inclusive = false }
            launchSingleTop = true
        }
    }

    // Signing out is app-wide, but only the shell reads the auth phase — the
    // chat route would happily keep painting a transcript the user can no
    // longer act on. Coming back to the shell is what lets the login screen
    // replace the app instead of that.
    val signOut: () -> Unit = {
        onLogout()
        if (navController.currentDestination?.route != PabrikRoutes.SHELL) {
            goBack()
        }
    }

    // `NavHost` emits nothing at all when the controller has no destination, and
    // the window then shows only the theme's background. This guard is not a
    // substitute for [goBack] — it is what turns any future way into that state
    // into one tap instead of a dead window.
    val visibleDestinations by navController.visibleEntries.collectAsState()
    val currentBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStackEntry?.destination?.route

    // The launch's own state, hoisted here because two different things need it:
    // the effect below that resumes, and the gate that decides whether any of
    // this is on screen yet. It is state *over time* — read on IO, answered
    // when a list lands, confirmed when a transcript has been scrolled — and
    // the third of those is reported by a composable several frames away.
    //
    // `plan` is null for the first frames of a launch. That is its own state,
    // neither decided nor undecided: the read is on IO, and "not read yet" is
    // not "there is nothing to resume".
    var plan by remember(authState.userId) { mutableStateOf<ResumePlan?>(null) }
    // Re-read when the account changes, not on every recomposition: the store is
    // keyed by account, and a plan built for the previous one would resume the
    // previous one's chat.
    LaunchedEffect(authState.userId) {
        // Off the main thread: this is a launch path, and the first screen is not
        // up yet, so there is nothing to drop a frame for.
        plan = withContext(Dispatchers.IO) {
            ResumePlan(positionStore.read(authState.userId))
        }
    }

    // Whether the resume has answered, as something Compose can see.
    //
    // **`ResumePlan` is not observable**, and that is the whole reason this is a
    // separate piece of state rather than a read of `plan.isDecided` during
    // composition. The plan latches its answer from inside the effect below —
    // mutating a plain object, which invalidates nothing. The gate would go on
    // rendering the value it last composed, so an answered "there is nothing to
    // open" would leave it up for ever, on every launch that has no chat to
    // resume. So the answer is copied into state every time the plan is asked.
    var resumeDecided by remember { mutableStateOf(false) }

    // The chat this launch navigated to, if it navigated to one. Set once, by
    // the resume, and the difference between "this launch still has a screen to
    // build" and "this launch is the shell".
    var resumedSessionId by remember { mutableStateOf<String?>(null) }

    // The resumed transcript has been put where the reader left it.
    //
    // **One-way, and the latch is the point.** `ChatView` reports it for the
    // session it is showing, and a reader who has already landed in a chat and
    // switched to another one would otherwise put a launch gate back over a
    // screen they are using — a worse bug than the drift it was added to stop.
    // A launch reveals; it does not re-close.
    var transcriptSettled by remember { mutableStateOf(false) }
    val onTranscriptSettled: (String?) -> Unit = { sessionId ->
        // Matched, not just recorded: a report about the chat that was open
        // before the resume — or about no chat at all, which is what a stale
        // state paints on the route's first frame — must not pass for the
        // resumed one settling.
        if (sessionId != null && sessionId == resumedSessionId) {
            transcriptSettled = true
        }
    }

    ResumeLastPosition(
        authState = authState,
        homeState = homeState,
        navController = navController,
        // Read from the hoisted destination, not from
        // `navController.currentDestination` inside the effect. Those are the
        // same value a frame later, but the *first* run of that effect happens
        // before `NavHost` has set the graph, so the current destination is
        // still null and `sessionToResume` — which only resumes on the shell —
        // answers "not on the shell" and the resume is skipped for good. Nothing
        // else in the key list changes afterwards to bring it back, so the app
        // sat on the shell (or, once there was a gate, behind it) for ever.
        currentRoute = currentRoute,
        plan = plan,
        onSelectChat = onSelectChat,
        onOpenSession = onOpenSession,
        onResumed = { sessionId -> resumedSessionId = sessionId },
        // Every consultation, answered or not — see [resumeDecided].
        onPlanConsulted = { resumeDecided = it },
    )

    // Auth answering `/api/auth/me` is not the app being ready. This is the
    // difference, and the whole reason the shell used to be on screen for three
    // seconds before the chat the reader had left appeared over it.
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
    // The chat bar's `+` chooser, over the graph and over `CreateTaskHost` so
    // the two never stack. It renders nothing while closed, so calling it
    // unconditionally costs one boolean read.
    //
    // It hands the pick straight to [onCreateTask] rather than routing through
    // `createTask.start()`: a new *chat* skips the Standard/Memory picker the
    // drawer's `+` shows, because the button that opened this sheet already
    // answered that question. The create's result comes back through
    // [createdChats], which is what navigates — see the collector above.
    if (newChatSheetOpen) {
        NewChatProjectSheet(
            projects = newChatCandidates,
            onProjectPicked = { project ->
                // Closed *before* the create, for the reason the controller
                // closes its own steps before one: the create navigates to a
                // new chat, and a sheet left on top of that chat is a sheet the
                // reader has to dismiss on arrival.
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

                // `onRetrySession` bypasses the /me cache: the user pressed "Try
                // again" to re-check, so it has to reach the network.
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
                        // Open the session before navigating: the route stays
                        // on the back stack, so returning to it must not show
                        // an empty transcript waiting on a load that never ran.
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
                    // The shell's drawer is the same drawer the chat route's
                    // hamburger opens, so it gets the same sections and the same
                    // fold state. It used to get neither, which is why the
                    // Projects section appeared only once the reader had already
                    // opened a chat.
                    projects = projectState,
                    projectActions = projectActions,
                    recentsExpanded = homeState.isRecentsExpanded,
                    onToggleRecentsSection = onToggleRecentsSection,
                    // The destination row, fed from the same state that decides
                    // whether to offer it — one notion of "there is more", so
                    // the button can never appear over a list that already holds
                    // all of it.
                    hasMoreChats = homeState.hasMoreChats,
                    chatsTotal = homeState.chatsTotal,
                    onOpenAllChats = { openChats(homeState.selectedWorkspaceId.orEmpty()) },
                    // The drawer's top-level New Chat. The screen wraps this
                    // with the drawer dismissal; nothing here navigates — the
                    // createdChat collector above does, once the create lands.
                    isCreatingChat = homeState.creatingTaskInProjectId != null,
                    onNewChat = onNewChat,
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
            // Collected here, not sampled above the `NavHost`. This is the one
            // line that makes the composer work: it subscribes *this* block, so
            // a draft keystroke recomposes the chat and nothing else.
            val chatState by chatState.collectAsState()
            // The id in the route is the truth. When it disagrees with what is
            // loaded — a deep link, or a session that failed to open — the route
            // wins, or the screen would show the previous chat under this one's
            // title.
            // Opening a session is a side effect, so it belongs in an effect —
            // running it in the composition body would re-open on every
            // recomposition and on every Back-and-forth through this route.
            LaunchedEffect(sessionId) {
                if (sessionId.isNotBlank() && chatState.sessionId != sessionId) {
                    onOpenSession(sessionId)
                }
            }

            // The chat's only way out, and the reason it is not a dead end.
            //
            // Without this the route has no in-app navigation at all — the top
            // bar leads with a hamburger and the drawer carries no "all chats"
            // row — and `updateOnBackPressedCallbackEnabled` leaves the system's
            // callback *disabled* while `destinationCountOnBackStack <= 1`. A
            // `pabrik://chat/…` link lands exactly there, so Back would quit the
            // app from a screen the reader never navigated into and cannot
            // otherwise leave.
            //
            // Registered here rather than in `ChatScreen` because this is
            // navigation and the graph owns navigation. It is also scoped to the
            // destination, so the shell behind it keeps the default
            // "Back leaves the app" behaviour.
            //
            // `ModalNavigationDrawer` registers its own handler deeper in the
            // tree, and the dispatcher runs the most-recently-added enabled
            // callback first — so an open drawer still closes on Back and only
            // falls through to here once it is shut.
            BackHandler { goBack() }

            ChatScreen(
                state = chatState,
                chatTitle = chatTitleFor(sessionId, homeState.chats),
                // The only signal that the launch has somewhere to show. The
                // graph holds a gate over the whole route until the transcript
                // has been scrolled to where the reader left it — see
                // [launchGateIsUp] — and this is the report that lifts it.
                onTranscriptSettled = onTranscriptSettled,
                // The route's id, not `chatState.sessionId`: a deep link that
                // has not finished opening yet still has to report the run it
                // is about to show.
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
                // The hamburger opens the same sidebar the shell shows — a
                // workspace's chats, a workspace picker and sign-out — because a
                // reader in a chat is far more often on their way to a
                // *different* chat than on their way back to the list.
                //
                // `onOpenChat` is the drawer's own signal that a chat was
                // picked, so closing it hangs off that rather than off the
                // row's click: the sidebar fires both, and wiring only one
                // leaves the sheet open on top of the transcript the reader
                // just asked for.
                drawerContent = { dismissDrawer ->
                    RecentsDrawerContent(
                        workspaces = homeState.workspaces,
                        chats = homeState.chats,
                        selectedWorkspaceId = homeState.selectedWorkspaceId,
                        // The route's session, not the list's memory: a deep link
                        // opens a chat the sidebar never marked as selected.
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
                        // The same set the shell's drawer shows it in: a chat
                        // busy in the background is busy in both copies of the
                        // list, and this is the one the reader is looking at.
                        runningSessionIds = runningSessionIds,
                        isAuthEnabled = authState.isAuthEnabled,
                        signedInEmail = authState.userEmail,
                        isLoggingOut = authState.isLoggingOut,
                        onLogout = signOut,
                        projects = projectState,
                        projectActions = projectActions,
                        // Straight off `homeState` rather than a local: the
                        // reader folded these sections in the shell's drawer, and
                        // a copy held here would forget it the moment they opened
                        // a chat.
                        recentsExpanded = homeState.isRecentsExpanded,
                        onToggleRecentsSection = onToggleRecentsSection,
                        // Same row, same reason: the shell's drawer and the
                        // chat route's are one drawer, so a destination one
                        // offers and the other does not is a drawer that
                        // forgets where it was.
                        hasMoreChats = homeState.hasMoreChats,
                        chatsTotal = homeState.chatsTotal,
                        // Dismiss explicitly, the way `onOpenChat` does two
                        // lines up. The list behind the row is a place to go,
                        // and leaving this modal sheet on top of it is the
                        // drawer hiding the page the reader asked for.
                        onOpenAllChats = {
                            openChats(homeState.selectedWorkspaceId.orEmpty())
                            dismissDrawer()
                        },
                        // The drawer's "New Chat", wired here because the bar
                        // stopped offering its own. It opens the project
                        // chooser rather than creating directly, because a chat
                        // is a task row and every task endpoint is nested under
                        // a project — see [NewChatProjectSheet] for why that
                        // is a sheet and not an invented workspace-level
                        // endpoint.
                        //
                        // Dismissed explicitly, like the row above: the sheet is
                        // a place to go, and leaving this modal drawer open on
                        // top of the chat is the drawer hiding the page the
                        // reader is on.
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
            // The drawer's five rows are already in `HomeUiState` — that is the
            // point of sharing the ViewModel, so opening this page costs one
            // request and only the pages past the preview are fetched here.
            //
            // Scoped by the route's workspace rather than the state's, because a
            // deep link names a workspace the drawer may never have selected.
            val routeWorkspaceId = backStackEntry.arguments
                ?.getString(PabrikRoutes.ARG_WORKSPACE_ID)
                .orEmpty()
            val routeChats = if (routeWorkspaceId == homeState.selectedWorkspaceId) {
                homeState.chats
            } else {
                // A cold deep link: nothing was fetched for this scope, and
                // showing the previous workspace's chats under this one's title
                // would be worse than showing nothing.
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
                // The ViewModel's own "keep asking", not `has_more` re-derived
                // here — it is the only place that knows about the in-flight
                // page and whether the list has covered the server's count.
                hasMore = homeState.canLoadMoreChats,
                isLoadingMore = homeState.isLoadingMoreChats,
                // A page that did not arrive is said out loud, and retryable by
                // tapping. Nothing else on this screen can tell the reader the
                // list is short because the *request* failed rather than
                // because there is nothing more.
                loadMoreError = homeState.loadMoreChatsError,
                isLoading = homeState.isLoading && routeChats.isEmpty(),
                onChatSelected = onSelectChat,
                onOpenChat = { sessionId ->
                    // Push, not replace: there IS a list under this one and Back
                    // from the chat must return to it — the same reason the
                    // project route pushes.
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

            // Same rule as the chat route, same reason: this route sits on the
            // back stack, so returning to it must not find a project whose
            // chats were never asked for. An effect, not the composition body —
            // in the body it would re-fetch on every recomposition.
            LaunchedEffect(itemId) {
                if (itemId.isNotBlank()) onEnsureProjectChatsLoaded(itemId)
            }

            ProjectChatsScreen(
                // The route's ids, not the loaded list's memory: a deep link
                // names a project the drawer never touched.
                projectName = homeState.projects
                    .firstOrNull { it.id == itemId }
                    ?.displayName
                    ?: "Project",
                // A narrow slice, not the whole `HomeUiState`. Sharing the
                // state with the drawer is what makes "See all" free — one
                // fetch instead of two — but handing the whole object to this
                // screen would recompose its `LazyColumn` on every unrelated
                // emission, including a recents page the reader is not looking
                // at. A slice whose `List` reference is unchanged does not
                // rebuild.
                page = homeState.projectChats[itemId],
                selectedChatId = homeState.selectedChatId,
                runningSessionIds = runningSessionIds,
                isLoading = itemId in homeState.isLoadingMoreProjectChats ||
                    (homeState.isLoadingProjects && homeState.projectChats[itemId] == null),
                onChatSelected = onSelectChat,
                onOpenChat = { sessionId ->
                    // The shell's own `onOpenChat` navigates normally, because
                    // there is no project list under it. Here there is: pushing
                    // the chat normally would make Back return to this project,
                    // which is where the reader came from.
                    onOpenSession(sessionId)
                    navController.navigate(PabrikRoutes.chat(sessionId))
                },
                onLoadMore = { onLoadMoreProjectChats(itemId) },
                onCreateTask = {
                    // The same `start` the drawer's `+` uses, with a summary
                    // rebuilt from this route's ids. A deep link names a project
                    // the drawer may never have loaded, so the row is
                    // synthesised rather than looked up — and its `item_type` is
                    // empty, which lands on the picker, the safe default: a
                    // project whose type is unknown gets both options offered
                    // rather than one guessed.
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

        // F05 scaffolding: placeholder routes for not-yet-implemented features.
        composable(PabrikRoutes.SETTINGS) {
            FeaturePlaceholderScreen(title = "Settings", onBack = goBack)
        }
        composable(PabrikRoutes.NOTIFICATIONS) {
            FeaturePlaceholderScreen(title = "Notifications", onBack = goBack)
        }
    }

    // AFTER the `NavHost`, not before it: a `Box` draws its later children
    // on top, and the board's create form is a full-screen overlay in this
    // composition rather than a window of its own (see `NewTaskDialog`), so
    // declaring it first left the board painted *over* the form. It composes
    // nothing while the flow is idle.
    CreateTaskHost(
        controller = createTask,
        isSubmitting = homeState.creatingTaskInProjectId != null,
        errorMessage = homeState.taskCreateError,
        // The board's form opens straight onto the card form (there is no type
        // picker for a board — see `createTaskStartDecision`), so these three
        // reads start the moment the reader presses `+` and land while they are
        // typing the title rather than after they press commit.
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

        // Over the graph, and *after* the recovery screen, so a dead back stack
        // keeps the one button that fixes it. A gate over `NavigationLostScreen`
        // would turn "the app lost track of where it was" into a splash with no
        // way out, which is the one thing that screen is not allowed to become.
        //
        // It covers the `NavHost` rather than replacing it, and that ordering is
        // the fix rather than a detail of the layout: the chat the resume just
        // navigated to is composed, measured and scrolled underneath this, so
        // the frame the reader finally sees is the frame the transcript is
        // already standing at the end of. Drawing nothing here instead would
        // move that work to *after* the reveal, which is the drift.
        if (gateIsUp && visibleDestinations.isNotEmpty()) {
            LaunchGateScreen()
        }
    }
}

/**
 * Reopens the chat the user was last in, when the app was closed and opened
 * again.
 *
 * The workspace half of the position is not here — `HomeViewModel` applies it
 * before its first fetch, so the drawer opens on the right workspace without a
 * wasted request. Only the chat is a route, and a route needs a destination to
 * navigate to, so it is navigated to from here.
 *
 * All of the policy is in [sessionToResume]; what is left here is reading the
 * current values and acting on the answer. That split is deliberate — the
 * conditions (authenticated, on the shell, the list settled, the chat still
 * there) are what is easy to get subtly wrong, and none of them can be asserted
 * from inside a composable.
 *
 * The auth phase is a *key* of the effect, not just a value it reads: the
 * sidebar's data often settles while the phase is still `Restoring`, and an
 * effect that only re-ran on the data would never revisit that answer.
 */
@Composable
private fun ResumeLastPosition(
    authState: AuthUiState,
    homeState: HomeUiState,
    navController: NavHostController,
    /**
     * Hoisted, because the launch gate above reads whether it has answered.
     * Passing it in rather than building it here is what lets the two be
     * answered from the same frame — the gate deciding "still asking" while the
     * effect is deciding "here is the chat" is a one-frame hole in the launch.
     */
    plan: ResumePlan?,
    /**
     * The current destination, hoisted from `currentBackStackEntryAsState`.
     *
     * **A key of the effect below, not a value it reads for itself.** The
     * destination is null for the frame or two before `NavHost` sets the graph,
     * and the effect's first run lands in that window. Reading
     * `navController.currentDestination` there is the same null the policy would
     * reject, and because the destination is in no other key, the effect never
     * runs again and the resume is dropped for the rest of the launch. Hoisting
     * it puts the arrival of the start destination into the key list, so the
     * question is re-asked the moment there is somewhere to ask it from.
     */
    currentRoute: String?,
    onSelectChat: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    /**
     * The chat that was navigated to, handed up so the gate can wait for its
     * transcript. A `LaunchedEffect` cannot return a value, and a session id is
     * a fact the next composable has to act on rather than one it can re-derive.
     */
    onResumed: (String) -> Unit,
    /**
     * Called every time the plan is asked, with whether it has answered.
     *
     * Not only when it answers: `ResumePlan` latches its own decision and is
     * not observable, so nothing would tell the gate that the answer changed.
     * Every consultation reports, because a report that only arrived *with* an
     * answer would leave "there is nothing to resume" invisible to the one
     * thing waiting on it.
     */
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

        // The session is opened before the navigation for the same reason the
        // sidebar's own `onOpenChat` is: the route stays on the back stack, so
        // returning to it must not show an empty transcript waiting on a load
        // that never ran.
        onSelectChat(sessionId)
        onOpenSession(sessionId)
        // Before the navigation, so the frame the gate lifts in already knows
        // which transcript it is waiting for. Reversed, the gate would read a
        // null id on its first pass and keep waiting.
        onResumed(sessionId)
        navController.navigate(PabrikRoutes.chat(sessionId))
    }
}

/**
 * The app is showing no destination at all.
 *
 * A `NavHost` with an empty back stack composes nothing, so without this the
 * window keeps the theme's background and the reader has no way out: Back exits
 * the app because there is no entry to pop. The reason is never worth making the
 * reader guess at, so it is stated and one tap is offered.
 */
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

/**
 * The title for a chat route.
 *
 * The session-detail endpoint carries the name too, but the route can be opened
 * by deep link before any list has loaded, so the sidebar is the only source
 * that can be consulted synchronously. Falling back to the raw id beats a blank
 * bar.
 */
private fun chatTitleFor(sessionId: String, chats: List<ChatSummary>): String =
    chats.firstOrNull { chat -> chat.id == sessionId }?.displayTitle
        ?: sessionId.ifBlank { "Chat" }
