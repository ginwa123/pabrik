package com.pabrik.mobile

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthViewModel
import com.pabrik.mobile.server.PrefsBaseUrlStore
import com.pabrik.mobile.server.ServerChange
import com.pabrik.mobile.server.ServerUrl
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.chat.ChatViewModel
import com.pabrik.mobile.chat.SseBus
import com.pabrik.mobile.chat.SseBusHolder
import com.pabrik.mobile.network.PabrikNavGraph
import com.pabrik.mobile.recents.HomeViewModel
import com.pabrik.mobile.storage.PrefsLastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import com.pabrik.mobile.worker.WorkerActivityViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.rgb(24, 22, 22)),
        )
        setContent {
            PabrikTheme {
                val application = application
                val authViewModel: AuthViewModel = viewModel()
                val authState by authViewModel.uiState.collectAsState()

                // One store for the process.
                val positionStore = remember { PrefsLastPositionStore(application) }

                val homeViewModel: HomeViewModel = viewModel(
                    factory = HomeViewModel.factory(application, positionStore),
                )
                val homeState by homeViewModel.uiState.collectAsState()

                val chatViewModel: ChatViewModel = viewModel(
                    factory = ChatViewModel.factory(application),
                )
                // Handed over as the flow, not sampled into a value or a `() -> ChatUiState` provider.
                val chatState: StateFlow<ChatUiState> = chatViewModel.uiState

                // Which sessions have a live worker.
                val workerViewModel: WorkerActivityViewModel = viewModel(
                    factory = WorkerActivityViewModel.factory(application),
                )
                val runningSessionIds by workerViewModel.runningSessionIds.collectAsState()

                // The app's ONE event connection, opened here and nowhere else.
                val sseBus: SseBus = remember(application) {
                    SseBusHolder.get(SessionCookieStore(application))
                }

                // Sampled here so the server row redraws the moment the holder changes.
                val serverBaseUrl by ServerUrl.current.collectAsState()

                // The one place a server change becomes an app-wide reset.
                val onChangeServer: (String) -> ServerChange = { raw ->
                    val change = ServerUrl.update(raw)
                    // Re-saving the address already in use changes nothing, and must cost nothing: signing the person out to re-point the app at the same server would be a …
                    if (change is ServerChange.Applied && change.baseUrl != serverBaseUrl) {
                        homeViewModel.onSignedOut()
                        chatViewModel.onSignedOut()
                        workerViewModel.onSignedOut()
                        sseBus.close()
                        authViewModel.onServerChanged()
                    }
                    change
                }

                val onUseDefaultServer: () -> ServerChange = {
                    val change = ServerUrl.resetToBuildDefault()
                    // Same shape as the branch above, reached from a button rather than a field, so it shares its "changed or not" question instead of assuming the answer.
                    if (change is ServerChange.Applied && change.baseUrl != serverBaseUrl) {
                        homeViewModel.onSignedOut()
                        chatViewModel.onSignedOut()
                        workerViewModel.onSignedOut()
                        sseBus.close()
                        authViewModel.onServerChanged()
                    }
                    change
                }

                // One sign-out, three entry points: the sidebar's "Log out", the retry screen's "Sign in", and a 401 from either cache.
                val signOut: () -> Unit = {
                    homeViewModel.onSignedOut()
                    chatViewModel.onSignedOut()
                    workerViewModel.onSignedOut()
                    sseBus.close()
                    authViewModel.logout()
                }

                // The signed-in account namespaces both caches AND owns the socket, whose handshake is a cookie the server answers once and never retries.
                LaunchedEffect(authState.userId) {
                    homeViewModel.onUserChanged(authState.userId)
                    chatViewModel.onUserChanged(authState.userId)
                    workerViewModel.onUserChanged(authState.userId)
                    if (authState.userId.isNullOrBlank()) sseBus.close() else sseBus.open()
                }

                // The workers socket is open for the whole process, so a run that ended while the app was backgrounded produced a `worker_deleted` this process never dispatched …
                val lifecycleOwner = LocalLifecycleOwner.current
                DisposableEffect(lifecycleOwner, authState.userId) {
                    val observer = LifecycleEventObserver { _, event ->
                        if (event == Lifecycle.Event.ON_START) {
                            workerViewModel.onForeground()
                        }
                    }
                    lifecycleOwner.lifecycle.addObserver(observer)
                    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
                }

                // A 401 on any call means the saved cookie is dead; signing out is the only outcome a retry cannot fix.
                LaunchedEffect(homeViewModel, chatViewModel) {
                    launch {
                        homeViewModel.sessionExpired.collect { signOut() }
                    }
                    launch {
                        chatViewModel.sessionExpired.collect { signOut() }
                    }
                }

                PabrikNavGraph(
                    authState = authState,
                    onSignIn = authViewModel::login,
                    // The retry screen's whole purpose is to re-check the session, so it must bypass the /me cache.
                    onRetrySession = { authViewModel.restoreSession(forceRefresh = true) },
                    onUseAnotherAccount = signOut,
                    onLogout = signOut,
                    homeState = homeState,
                    chatState = chatState,
                    positionStore = positionStore,
                    onSelectWorkspace = homeViewModel::selectWorkspace,
                    onSelectChat = homeViewModel::selectChat,
                    onToggleProjectsSection = homeViewModel::toggleProjectsSection,
                    onToggleProjectExpanded = homeViewModel::toggleProjectExpanded,
                    onEnsureProjectChatsLoaded = homeViewModel::ensureProjectChatsLoaded,
                    onLoadMoreProjectChats = homeViewModel::loadMoreProjectChats,
                    // The full-screen recents list's next page.
                    onLoadMoreChats = homeViewModel::loadMoreChats,
                    onRetryProjects = homeViewModel::retryProjects,
                    // The create's only ViewModel-facing half.
                    onCreateTask = { workspaceId, itemId, request ->
                        // The workspace the row carries is the one the drawer's copy may be blank on (a project read from cache), and the endpoint is nested under it, so a blank here is …
                        if (workspaceId.isNotBlank()) {
                            homeViewModel.createTask(itemId, request)
                        }
                    },
                    // A board's "New task" form opens the moment `+` is pressed on a kanban project, so its columns, the profile list and the server's home start loading here rather …
                    onLoadKanbanFormData = homeViewModel::loadKanbanFormData,
                    // The drawer's top-level "New Chat".
                    onNewChat = homeViewModel::newChat,
                    createdChats = homeViewModel.createdChat,
                    onDismissTaskCreateError = homeViewModel::dismissTaskCreateError,
                    onToggleRecentsSection = homeViewModel::toggleRecentsSection,
                    onRetryHome = homeViewModel::refresh,
                    onOpenSession = chatViewModel::openSession,
                    onChatDraftChanged = chatViewModel::onDraftChanged,
                    onSendChatMessage = chatViewModel::sendMessage,
                    onStopChatRun = chatViewModel::stopRun,
                    onRefreshChatQueue = chatViewModel::refreshQueuedMessages,
                    onUseQueuedChatMessage = chatViewModel::useQueuedMessage,
                    onSelectChatModel = chatViewModel::selectProfile,
                    onAttachChatImage = chatViewModel::attachImage,
                    onRemoveChatAttachment = chatViewModel::removeAttachment,
                    onLoadOlderChatMessages = chatViewModel::loadOlderMessages,
                    onDismissChatError = chatViewModel::clearError,
                    onAnswerChatQuestion = {
                        chatViewModel.answerQuestion(
                            questionId = it.questionId,
                            toolCallId = it.toolCallId,
                            answer = it.answer,
                            skip = it.skip,
                        )
                    },
                    runningSessionIds = runningSessionIds,
                    serverBaseUrl = serverBaseUrl,
                    defaultServerBaseUrl = AuthConfig.BUILD_DEFAULT_BASE_URL,
                    onChangeServer = onChangeServer,
                    onUseDefaultServer = onUseDefaultServer,
                )
            }
        }
    }
}
