package com.pabrik.mobile.recents

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState
import com.pabrik.mobile.chat.SseBus
import com.pabrik.mobile.chat.SseBusHolder
import com.pabrik.mobile.network.RecordingAuthTransport
import com.pabrik.mobile.projects.CreateTaskRequest
import com.pabrik.mobile.projects.KanbanClient
import com.pabrik.mobile.projects.KanbanColumn
import com.pabrik.mobile.projects.canSubmitTask
import com.pabrik.mobile.projects.ProjectsApi
import com.pabrik.mobile.projects.ProjectsCache
import com.pabrik.mobile.projects.ProjectChatsPage
import com.pabrik.mobile.projects.ProjectsClient
import com.pabrik.mobile.projects.RoomProjectsCache
import com.pabrik.mobile.projects.ProjectSummary
import com.pabrik.mobile.projects.TaskTypes
import com.pabrik.mobile.projects.isValidMemoryName
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.worker.RunningSessionsStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HomeUiState(
    val isLoading: Boolean = true,
    val workspaces: List<WorkspaceOption> = emptyList(),
    val selectedWorkspaceId: String? = null,
    val chats: List<ChatSummary> = emptyList(),
    val selectedChatId: String? = null,
    val errorMessage: String? = null,
    /** A *later* page is in flight on the full-screen list. */
    val isLoadingMoreChats: Boolean = false,
    /** Whether the server says another page exists. */
    val hasMoreChats: Boolean = false,
    /** The server's full filtered count for this workspace; 0 when unreported. */
    val chatsTotal: Int = 0,
    /** Why the last *later* page failed, or null. */
    val loadMoreChatsError: String? = null,
    // ── Projects (the sidebar's Projects section) ──────────────────────────
    val isRecentsExpanded: Boolean = true,
    /** Whether the Projects section is unfolded. */
    val isProjectsExpanded: Boolean = true,
    val projects: List<ProjectSummary> = emptyList(),
    val isLoadingProjects: Boolean = false,
    /** The projects fetch failed while rows are on screen. */
    val projectsError: String? = null,
    /** Which project rows are unfolded. View-model state, not composable state. */
    val expandedProjectIds: Set<String> = emptySet(),
    /** One page per expanded project, keyed by project id. See [ProjectChatsPage]. */
    val projectChats: Map<String, ProjectChatsPage> = emptyMap(),
    /** Which projects have a later page in flight. */
    val isLoadingMoreProjectChats: Set<String> = emptySet(),
    // ── Creating a chat / task under a project ─────────────────────────────
    val creatingTaskInProjectId: String? = null,
    /** Why the last create failed, or null. */
    val taskCreateError: String? = null,
    // ── What the board's "New task" form needs before it can be filled in ────
    val kanbanColumns: List<KanbanColumn> = emptyList(),
    /** Profile names for the form's picker. Empty = "Default" is the only row. */
    val kanbanProfiles: List<String> = emptyList(),
    /** The server's `$HOME`, for the worktree prefill. */
    val kanbanServerHome: String = "",
    /** The board whose form data is in flight, or null. */
    val isLoadingKanbanFormData: Boolean = false,
) {
    fun isProjectExpanded(itemId: String): Boolean = itemId in expandedProjectIds

    fun projectChatsFor(itemId: String): ProjectChatsPage? = projectChats[itemId]

    /** The scroll should keep asking for another page of this project. */
    fun canLoadMoreProjectChats(itemId: String): Boolean {
        val page = projectChats[itemId] ?: return false
        return page.hasMore &&
            itemId !in isLoadingMoreProjectChats &&
            !isLoadingProjects &&
            page.chats.isNotEmpty()
    }

    /** Whether the drawer should offer "See all chats" under this project. */
    fun shouldOfferSeeAllChats(itemId: String): Boolean {
        val page = projectChats[itemId] ?: return false
        return page.chats.size > ProjectsApi.DRAWER_PREVIEW_ROWS || page.hasMore
    }
    /** Nothing to show and nothing wrong — the account genuinely has no workspaces. */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && workspaces.isEmpty()

    /** Rows are on screen but the last refresh failed. */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && workspaces.isNotEmpty()

    /** The screen's scroll should keep asking. */
    val canLoadMoreChats: Boolean
        get() = hasMoreChats && !isLoadingMoreChats && !isLoading && !hasReachedTotal

    private val hasReachedTotal: Boolean
        get() = chatsTotal > 0 && chats.size >= chatsTotal
}

/** Owns the sidebar's real data. There is no preview fallback here on purpose */
class HomeViewModel(
    private val client: RecentsClient,
    private val cache: RecentsCache,
    /** A second client, not a widened [RecentsClient]. */
    private val projectsClient: ProjectsClient,
    /** Separate from [cache] on purpose. */
    private val projectsCache: ProjectsCache,
    /** The board-only endpoints the "New task" form needs: a board's columns, the profile list, the server's home, and the move that lands a card in the column the … */
    private val kanbanClient: KanbanClient,
    /** Where the position outlives the process. */
    private val positionStore: LastPositionStore,
    // Injected so tests can drive the fetch on the same scheduler as the paint; `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** The app's ONE event connection, shared with the chat and the worker set. */
    private val bus: SseBus? = null,
) : ViewModel() {
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    /** Detaches from [bus]. */
    private var unsubscribeFromBus: (() -> Unit)? = null

    /** The pending debounced reload, cancelled and re-armed by every event. */
    private var sseReloadJob: Job? = null

    init {
        unsubscribeFromBus = bus?.subscribe(
            onEvent = { event -> handleBusEvent(event) },
            onState = { state -> handleBusState(state) },
        )
    }

    /** Session ids of chats this app just created, for the nav graph to open. */
    private val _createdChat = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val createdChat: SharedFlow<String> = _createdChat.asSharedFlow()

    private var userId: String? = null
    private var hasStarted = false
    private var workspacesJob: Job? = null
    private var chatsJob: Job? = null

    /** The workspace the last run ended on, read once per launch. */
    private var resumeWorkspaceSeed: String? = null

    /** A later page's fetch, on behalf of the full-screen list. */
    private var moreChatsJob: Job? = null

    /** The server's resume value for the next page, held here rather than in [HomeUiState] because it is protocol, not view state: nothing renders it and a rotation … */
    private var chatsCursor: String? = null

    /** Bumped whenever the recents list is replaced from scratch. */
    private var chatsGeneration = 0

    // ── Projects ───────────────────────────────────────────────────────────
    private var projectsJob: Job? = null

    /** Per-project resume values, held here rather than in [HomeUiState] for the same reason [chatsCursor] is: it is protocol, not view state. */
    private val projectCursors = mutableMapOf<String, String>()

    /** A later page per project. Separate job per project, like [moreChatsJob]. */
    private val moreProjectChatsJobs = mutableMapOf<String, Job>()

    /** Per-project generation counter, bumped whenever a project's page 1 is replaced from scratch. */
    private val projectGenerations = mutableMapOf<String, Int>()

    /** A page-1 reload invalidates every project, so one job for the section. */
    private var projectsGeneration = 0

    /** The single entry point. */
    fun onUserChanged(newUserId: String?) {
        if (hasStarted && newUserId == userId) return
        hasStarted = true

        val accountChanged = newUserId != userId
        userId = newUserId
        // Read before the first paint, not after: the drawer has to open on the workspace the user left, and a seed applied once the list is already on screen is a …
        resumeWorkspaceSeed = positionStore.read(newUserId).workspaceId
        if (accountChanged) {
            // Blank rather than keep: the old rows belong to someone else.
            _uiState.value = HomeUiState()
        }
        refresh()
    }

    fun refresh() {
        // A refresh is a new question with a new answer, so the *previous* page's failure stops being true here — cleared before the request, because whether the refresh …
        _uiState.update { it.copy(loadMoreChatsError = null) }

        primeWorkspacesFromCache()
        // The workspace the prime above selected needs its own paint, and it must happen NOW — waiting for the workspaces fetch to return first would put a spinner over …
        _uiState.value.selectedWorkspaceId?.let { primeChatsFromCache(it) }

        workspacesJob?.cancel()
        workspacesJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { client.loadWorkspaces() }) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update {
                    // Keep whatever is on screen — cached or not.
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is RecentsResult.Loaded -> {
                    val workspaces = result.value
                    // Hold the current selection across a refresh so the drawer does not jump back to the top on every pull-to-refresh.
                    val selected = selectWorkspaceId(
                        workspaces = workspaces,
                        currentSelection = _uiState.value.selectedWorkspaceId,
                        resumeSeed = resumeWorkspaceSeed,
                    )
                    // The live list has now had its say on the seed: either it was applied just above, or the workspace is gone.
                    resumeWorkspaceSeed = null

                    _uiState.update {
                        it.copy(
                            isLoading = false,
                            workspaces = workspaces,
                            selectedWorkspaceId = selected,
                            errorMessage = null,
                        )
                    }

                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) { cache.writeWorkspaces(id, workspaces) }
                    }
                    if (selected != null) loadChats(selected)
                    // After loadChats, so the section's state clears and paints behind the recents it belongs to rather than in front of a spinner the reader is still waiting on.
                    if (selected != null) loadProjects(selected)
                }
            }
        }
    }

    /** Folds one server event into "re-read the recents list". */
    private fun handleBusEvent(event: ChatStreamEvent) {
        // No account, no rows to correct.
        if (userId == null) return
        when (event) {
            is ChatStreamEvent.SessionChanged -> {
                // Evicted now rather than after the debounce: a deleted chat is a row the reader must not be able to tap for the next 400ms, and the reload behind it only …
                if (event.action == ACTION_SESSION_DELETED) {
                    _uiState.update { state ->
                        state.copy(chats = state.chats.filterNot { it.id == event.sessionId })
                    }
                }
                scheduleSseReload()
            }

            is ChatStreamEvent.WorkerChanged ->
                if (event.action != RunningSessionsStore.ACTION_UPDATED) scheduleSseReload()

            else -> Unit
        }
    }

    /** Re-reads on every return to [ChatStreamState.Live]. */
    private fun handleBusState(state: ChatStreamState) {
        if (userId == null) return
        if (state is ChatStreamState.Live) scheduleSseReload()
    }

    /** Reloads page 1 of the recents, coalescing a burst of events into one GET. */
    private fun scheduleSseReload() {
        if (_uiState.value.selectedWorkspaceId == null) return
        sseReloadJob?.cancel()
        sseReloadJob = viewModelScope.launch {
            delay(SSE_RELOAD_DEBOUNCE_MILLIS)
            // Re-read at fire time, not at schedule time: a workspace switch inside the window has to load the workspace now selected.
            _uiState.value.selectedWorkspaceId?.let { loadChats(it) }
        }
    }

    override fun onCleared() {
        sseReloadJob?.cancel()
        sseReloadJob = null
        unsubscribeFromBus?.invoke()
        unsubscribeFromBus = null
        super.onCleared()
    }

    /** Paints the last-known workspace list synchronously, before any network call. */
    private fun primeWorkspacesFromCache() {
        val cachedWorkspaces = cache.readWorkspaces(userId).orEmpty()

        if (cachedWorkspaces.isEmpty()) {
            // A genuine first launch has nothing to paint; the spinner is honest.
            _uiState.update { it.copy(isLoading = true, errorMessage = null) }
            return
        }

        val current = _uiState.value
        val selected = selectWorkspaceId(
            workspaces = cachedWorkspaces,
            currentSelection = current.selectedWorkspaceId,
            resumeSeed = resumeWorkspaceSeed,
        )

        _uiState.value = current.copy(
            isLoading = true,
            workspaces = cachedWorkspaces,
            selectedWorkspaceId = selected,
            errorMessage = null,
        )
    }

    fun selectWorkspace(workspaceId: String) {
        if (_uiState.value.selectedWorkspaceId == workspaceId) return
        // Clear first: leaving the old workspace's chats under the new workspace's name for the length of the fetch reads as real data.
        _uiState.update {
            it.copy(
                selectedWorkspaceId = workspaceId,
                chats = emptyList(),
                selectedChatId = null,
                isLoading = true,
                errorMessage = null,
                // The cursor belongs to the workspace we are leaving.
                isLoadingMoreChats = false,
                hasMoreChats = false,
                chatsTotal = 0,
                // The same rule for the same reason: the old workspace's projects, and which of them were unfolded, belong to the workspace we are leaving.
                isLoadingProjects = false,
                projectsError = null,
                expandedProjectIds = emptySet(),
                projectChats = emptyMap(),
                isLoadingMoreProjectChats = emptySet(),
            )
        }
        loadChats(workspaceId)
        loadProjects(workspaceId)
        // After the state, not before: a tap that lands somewhere the app cannot recover from must not leave a position behind that the next launch would try to resume.
        positionStore.saveWorkspace(userId, workspaceId)
    }

    /** The user is now in this chat, which is the other half of the position. */
    fun selectChat(chatId: String) {
        if (chatId.isBlank()) return
        _uiState.update { it.copy(selectedChatId = chatId) }
        positionStore.save(
            userId,
            LastPosition(
                workspaceId = _uiState.value.selectedWorkspaceId,
                sessionId = chatId,
            ),
        )
    }

    /** Paints one workspace's cached recents, if any survive. */
    private fun primeChatsFromCache(workspaceId: String) {
        val cached = cache.readChats(userId, workspaceId)
            ?.filter { chat -> chat.workspaceId == workspaceId }
            ?: return

        _uiState.update { state ->
            // A paint for a workspace the user already left is not ours to apply.
            if (state.selectedWorkspaceId != workspaceId) {
                state
            } else {
                state.copy(
                    chats = cached,
                    selectedChatId = cached.firstOrNull()?.id,
                )
            }
        }
    }

    /** Paint this workspace's cached recents, then revalidate. */
    private fun loadChats(workspaceId: String) {
        primeChatsFromCache(workspaceId)

        // A page-1 reload invalidates both the cursor and any page in flight
        chatsGeneration++
        moreChatsJob?.cancel()
        chatsCursor = null
        _uiState.update {
            it.copy(
                isLoadingMoreChats = false,
                hasMoreChats = false,
                chatsTotal = 0,
                loadMoreChatsError = null,
            )
        }

        val generation = chatsGeneration
        chatsJob?.cancel()
        chatsJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.loadChats(
                    workspaceId = workspaceId,
                    limit = RecentsApi.DRAWER_PREVIEW_ROWS,
                )
            }
            when (result) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { state ->
                    // A slow response for a workspace the user has already left must not land under the new one.
                    if (state.selectedWorkspaceId != workspaceId) {
                        state
                    } else {
                        state.copy(isLoading = false, errorMessage = result.message)
                    }
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val chats = page.chats
                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            cache.writeChats(id, workspaceId, chats)
                        }
                    }
                    if (generation != chatsGeneration) return@launch
                    _uiState.update { state ->
                        if (state.selectedWorkspaceId != workspaceId) {
                            state
                        } else {
                            state.copy(
                                isLoading = false,
                                chats = chats,
                                selectedChatId = state.selectedChatId
                                    ?.takeIf { chatId -> chats.any { it.id == chatId } }
                                    ?: chats.firstOrNull()?.id,
                                // `has_more` is what tells the drawer whether a `See all chats ›` row is honest to offer; five rows on screen cannot answer that on their own.
                                hasMoreChats = page.hasMore,
                                chatsTotal = page.total,
                            )
                        }
                    }
                    // Set only after the state applied, so the screen's scroll can never fire against a cursor the list does not match.
                    chatsCursor = page.nextCursor
                }
            }
        }
    }

    /** Append the next page of recents. */
    fun loadMoreChats() {
        val state = _uiState.value
        if (!state.canLoadMoreChats) return
        val workspaceId = state.selectedWorkspaceId ?: return
        // An empty list means page 1 has not landed yet; paging from here would append onto nothing.
        if (state.chats.isEmpty()) return
        val cursor = chatsCursor ?: return

        val generation = chatsGeneration
        moreChatsJob?.cancel()
        moreChatsJob = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingMoreChats = true, loadMoreChatsError = null) }

            val result = withContext(ioDispatcher) {
                client.loadChats(
                    workspaceId = workspaceId,
                    cursor = cursor,
                    limit = RecentsApi.CHATS_PAGE_LIMIT,
                )
            }
            if (generation != chatsGeneration) return@launch
            // The workspace changed (or the list was reloaded) while the request was out.
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingMoreChats = false) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    // Keep the rows we already have and keep `hasMore` true, so asking again retries the same page.
                    current.copy(
                        isLoadingMoreChats = false,
                        loadMoreChatsError = result.message,
                    )
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val known = _uiState.value.chats
                    val fresh = page.chats.filterNot { chat -> known.any { it.id == chat.id } }

                    _uiState.update { current ->
                        current.copy(
                            isLoadingMoreChats = false,
                            loadMoreChatsError = null,
                            chats = RecentsApi.mergeChatsById(current.chats, page.chats),
                            // A page that added nothing new means the cursor is not advancing — either the end of the list or a server that keeps replaying rows.
                            hasMoreChats = page.hasMore && fresh.isNotEmpty(),
                        )
                    }

                    // An empty page must not advance the cursor: holding the old one is what lets a retry re-request the same window.
                    if (fresh.isNotEmpty()) {
                        chatsCursor = page.nextCursor
                    } else {
                        chatsCursor = null
                    }

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            // Write the *merged* list, not this page: the cache is what a cold boot paints, and writing only the page would replace the rows above it.
                            withContext(ioDispatcher) {
                                cache.writeChats(id, workspaceId, _uiState.value.chats)
                            }
                        }
                    }
                }
            }
        }
    }



    // ── Projects ───────────────────────────────────────────────────────────

    /** Paint one workspace's projects, then revalidate — the same cache-then-revalidate shape as [loadChats], and deliberately in one function so a cache paint with … */
    private fun loadProjects(workspaceId: String) {
        primeProjectsFromCache(workspaceId)

        projectsGeneration++
        moreProjectChatsJobs.values.forEach { it.cancel() }
        moreProjectChatsJobs.clear()
        projectCursors.clear()
        projectGenerations.clear()
        _uiState.update {
            it.copy(
                isLoadingProjects = true,
                projectsError = null,
                expandedProjectIds = emptySet(),
                projectChats = emptyMap(),
                isLoadingMoreProjectChats = emptySet(),
            )
        }

        val generation = projectsGeneration
        projectsJob?.cancel()
        projectsJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { projectsClient.loadProjects(workspaceId) }) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { state ->
                    // A slow response for a workspace the user has already left must not land under the new one.
                    if (state.selectedWorkspaceId != workspaceId) {
                        state
                    } else {
                        state.copy(isLoadingProjects = false, projectsError = result.message)
                    }
                }

                is RecentsResult.Loaded -> {
                    val projects = result.value
                    if (generation != projectsGeneration) return@launch
                    _uiState.update { state ->
                        if (state.selectedWorkspaceId != workspaceId) {
                            state
                        } else {
                            state.copy(
                                isLoadingProjects = false,
                                projects = projects,
                                projectsError = null,
                            )
                        }
                    }
                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            projectsCache.writeProjects(id, workspaceId, projects)
                        }
                    }
                }
            }
        }
    }

    /** Paints cached projects synchronously, before the network call. */
    private fun primeProjectsFromCache(workspaceId: String) {
        val cached = projectsCache.readProjects(userId, workspaceId) ?: return
        if (cached.isEmpty()) return

        _uiState.update { state ->
            // A paint for a workspace the user already left is not ours to apply.
            if (state.selectedWorkspaceId != workspaceId) {
                state
            } else {
                state.copy(projects = cached)
            }
        }
    }

    /** Re-fetch just this section, for its own error surface's Retry. */
    fun retryProjects() {
        val workspaceId = _uiState.value.selectedWorkspaceId ?: return
        loadProjects(workspaceId)
    }

    /** Fold the whole section away, or unfold it. The state lives here, not in a composable. */
    fun toggleProjectsSection() {
        _uiState.update { it.copy(isProjectsExpanded = !it.isProjectsExpanded) }
    }

    /** Fold the Recents section away, or unfold it. */
    fun toggleRecentsSection() {
        _uiState.update { it.copy(isRecentsExpanded = !it.isRecentsExpanded) }
    }

    /** Fold one project open or shut. */
    fun toggleProjectExpanded(itemId: String) {
        val wasExpanded = _uiState.value.isProjectExpanded(itemId)
        _uiState.update { state ->
            state.copy(
                expandedProjectIds = if (wasExpanded) {
                    state.expandedProjectIds - itemId
                } else {
                    state.expandedProjectIds + itemId
                },
            )
        }
        if (wasExpanded) return
        ensureProjectChatsLoaded(itemId)
    }

    /** Fetch page 1 for [itemId] if it is not already held. */
    fun ensureProjectChatsLoaded(itemId: String) {
        val state = _uiState.value
        val workspaceId = state.selectedWorkspaceId ?: return
        // A page already held — from the cache, from the drawer, or from the screen itself.
        if (state.projectChats.containsKey(itemId)) return
        if (state.isLoadingMoreProjectChats.contains(itemId)) return

        val generation = (projectGenerations[itemId] ?: 0) + 1
        projectGenerations[itemId] = generation
        projectCursors.remove(itemId)

        moreProjectChatsJobs.remove(itemId)?.cancel()
        moreProjectChatsJobs[itemId] = viewModelScope.launch {
            when (
                val result = withContext(ioDispatcher) {
                    projectsClient.loadProjectChats(workspaceId, itemId)
                }
            ) {
                is RecentsResult.SignedOut -> expireSession()

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    current.copy(
                        isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                    )
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    if (projectGenerations[itemId] != generation) return@launch
                    if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

                    _uiState.update { current ->
                        current.copy(
                            projectChats = current.projectChats + (itemId to page),
                            isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                        )
                    }
                    // Set only after the state applied, so a scroll can never fire against a cursor the list does not match.
                    projectCursors[itemId] = page.nextCursor.orEmpty()

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            withContext(ioDispatcher) {
                                projectsCache.writeProjectChats(
                                    id,
                                    workspaceId,
                                    itemId,
                                    page.chats,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /** Append the next page of one project's chats. */
    fun loadMoreProjectChats(itemId: String) {
        val state = _uiState.value
        if (!state.canLoadMoreProjectChats(itemId)) return
        val workspaceId = state.selectedWorkspaceId ?: return
        val cursor = projectCursors[itemId]?.takeIf { it.isNotBlank() } ?: return

        val generation = projectGenerations[itemId] ?: return

        moreProjectChatsJobs.remove(itemId)?.cancel()
        moreProjectChatsJobs[itemId] = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingMoreProjectChats = it.isLoadingMoreProjectChats + itemId) }

            val result = withContext(ioDispatcher) {
                projectsClient.loadProjectChats(
                    workspaceId = workspaceId,
                    itemId = itemId,
                    cursor = cursor,
                )
            }
            if (projectGenerations[itemId] != generation) return@launch
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingMoreProjectChats = it.isLoadingMoreProjectChats - itemId) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update { current ->
                    // Keep the rows we already have and keep `hasMore` true, so scrolling again retries the same page.
                    current.copy(isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId)
                }

                is RecentsResult.Loaded -> {
                    val page = result.value
                    val known = _uiState.value.projectChats[itemId]?.chats.orEmpty()
                    val fresh = page.chats.filterNot { chat -> known.any { it.id == chat.id } }

                    _uiState.update { current ->
                        val existing = current.projectChats[itemId]
                        current.copy(
                            projectChats = current.projectChats + (
                                itemId to ProjectChatsPage(
                                    chats = ProjectsApi.mergeProjectChatsById(
                                        existing?.chats.orEmpty(),
                                        page.chats,
                                    ),
                                    // A page that added nothing new means the cursor is not advancing.
                                    hasMore = page.hasMore && fresh.isNotEmpty(),
                                    nextCursor = page.nextCursor,
                                )
                                ),
                            isLoadingMoreProjectChats = current.isLoadingMoreProjectChats - itemId,
                        )
                    }

                    // An empty page must not advance the cursor: holding the old one is what lets a retry re-request the same window.
                    if (fresh.isNotEmpty()) {
                        projectCursors[itemId] = page.nextCursor.orEmpty()
                    } else {
                        projectCursors.remove(itemId)
                    }

                    if (page.chats.isNotEmpty()) {
                        val id = userId
                        if (id != null) {
                            withContext(ioDispatcher) {
                                projectsCache.writeProjectChats(
                                    id,
                                    workspaceId,
                                    itemId,
                                    _uiState.value.projectChats[itemId]?.chats.orEmpty(),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Creating a chat / task under a project ─────────────────────────────

    // Create a chat or a memory under [itemId], and paint the result.
    fun newChat() {
        val state = _uiState.value
        val workspaceId = state.selectedWorkspaceId ?: return
        // The existing global guard.
        if (state.creatingTaskInProjectId != null) return

        viewModelScope.launch {
            // Normally this is a LOCAL FIND and no request happens: the server ensures the default on every items read, so the list already held here carries it.
            val defaultId = defaultProjectId(state.projects)
            val project: ProjectSummary? = if (defaultId != null) {
                state.projects.first { it.id == defaultId }
            } else {
                // Cold start — the app was open when the migration ran.
                when (val resolved = projectsClient.getOrCreateDefaultProject(workspaceId)) {
                    is RecentsResult.Loaded -> resolved.value
                    is RecentsResult.Unavailable,
                    RecentsResult.SignedOut,
                    -> null
                }
            }
            if (project == null) {
                // Surface it in the same slot the per-project create uses, and do NOT navigate.
                _uiState.update { it.copy(taskCreateError = DEFAULT_PROJECT_ERROR_MESSAGE) }
                return@launch
            }
            createTask(project.id, CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        }
    }

    /** Fill in the board's "New task" form: its columns, the profile list, and the server's home for the worktree prefill. */
    fun loadKanbanFormData(workspaceId: String, itemId: String) {
        // A second open of the same form while the first read is still out must not start a second one.
        if (_uiState.value.isLoadingKanbanFormData) return

        _uiState.update { it.copy(isLoadingKanbanFormData = true) }
        viewModelScope.launch {
            val columns = withContext(ioDispatcher) { kanbanClient.loadColumns(workspaceId, itemId) }
            val profiles = withContext(ioDispatcher) { kanbanClient.loadProfileNames() }
            val home = withContext(ioDispatcher) { kanbanClient.loadServerHome() }
            _uiState.update { current ->
                current.copy(
                    // A `SignedOut` from any of the three is the session expiring and the nav graph already handles that event from the create path; here it just leaves the form's …
                    kanbanColumns = (columns as? RecentsResult.Loaded)?.value.orEmpty(),
                    kanbanProfiles = (profiles as? RecentsResult.Loaded)?.value.orEmpty(),
                    kanbanServerHome = (home as? RecentsResult.Loaded)?.value.orEmpty(),
                    isLoadingKanbanFormData = false,
                )
            }
            if (columns is RecentsResult.SignedOut) expireSession()
        }
    }

    fun createTask(itemId: String, request: CreateTaskRequest) {
        val state = _uiState.value
        val workspaceId = state.selectedWorkspaceId ?: return
        // One create at a time.
        if (state.creatingTaskInProjectId != null) return

        if (request is CreateTaskRequest.Memory && !isValidMemoryName(request.name)) {
            _uiState.update { it.copy(taskCreateError = INVALID_MEMORY_NAME_MESSAGE) }
            return
        }
        if (request is CreateTaskRequest.Memory && request.content.isBlank()) {
            _uiState.update { it.copy(taskCreateError = EMPTY_MEMORY_CONTENT_MESSAGE) }
            return
        }
        // The board card has no server-side name rule worth duplicating — the only one that matters is "there is one", and the server would answer 400 anyway.
        if (request is CreateTaskRequest.KanbanTask && !canSubmitTask(request.name)) {
            _uiState.update { it.copy(taskCreateError = EMPTY_TASK_TITLE_MESSAGE) }
            return
        }

        _uiState.update { it.copy(creatingTaskInProjectId = itemId, taskCreateError = null) }

        // Capture the generation now.
        val generation = (projectGenerations[itemId] ?: 0) + 1
        projectGenerations[itemId] = generation

        viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                projectsClient.createTask(workspaceId, itemId, request)
            }
            if (projectGenerations[itemId] != generation) return@launch
            if (_uiState.value.selectedWorkspaceId != workspaceId) return@launch

            when (result) {
                is RecentsResult.SignedOut -> {
                    _uiState.update { it.copy(creatingTaskInProjectId = null) }
                    expireSession()
                }

                is RecentsResult.Unavailable -> _uiState.update {
                    // The rows survive: a failed create changed nothing.
                    it.copy(creatingTaskInProjectId = null, taskCreateError = result.message)
                }

                is RecentsResult.Loaded -> {
                    val created = result.value
                    _uiState.update { current ->
                        val existing = current.projectChats[itemId]
                        current.copy(
                            creatingTaskInProjectId = null,
                            taskCreateError = null,
                            // A project with no page yet — a `+` on a project the reader never expanded, or one whose fetch failed — gets a first page holding just the new row rather than …
                            projectChats = current.projectChats + (
                                itemId to ProjectChatsPage(
                                    chats = listOf(created) +
                                        existing?.chats.orEmpty().filterNot { it.id == created.id },
                                    // Unchanged: this says nothing about whether more pages exist, and the create told us nothing about a cursor.
                                    hasMore = existing?.hasMore ?: false,
                                    nextCursor = existing?.nextCursor,
                                )
                                ),
                            expandedProjectIds = current.expandedProjectIds + itemId,
                        )
                    }

                    val id = userId
                    if (id != null) {
                        withContext(ioDispatcher) {
                            projectsCache.writeProjectChats(
                                id,
                                workspaceId,
                                itemId,
                                _uiState.value.projectChats[itemId]?.chats.orEmpty(),
                            )
                        }
                    }

                    // Only a chat is a destination.
                    if (request.opensChat) {
                        _createdChat.tryEmit(created.id)
                    }

                    // A board card lands in the column the reader picked — after the create, because `POST .../kanban/tasks` has no `column_id` and auto-assigns the card to the …
                    if (request is CreateTaskRequest.KanbanTask &&
                        request.columnId.isNotBlank()
                    ) {
                        moveCreatedCardToColumn(
                            workspaceId = workspaceId,
                            itemId = itemId,
                            taskId = created.id,
                            request = request,
                        )
                    }
                }
            }
        }
    }

    /** Put a just-created card in the column the reader chose. */
    private fun moveCreatedCardToColumn(
        workspaceId: String,
        itemId: String,
        taskId: String,
        request: CreateTaskRequest.KanbanTask,
    ) {
        viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                kanbanClient.moveTaskToColumn(
                    workspaceId = workspaceId,
                    itemId = itemId,
                    taskId = taskId,
                    columnId = request.columnId,
                )
            }
            when (result) {
                is RecentsResult.SignedOut -> expireSession()
                // The create already succeeded and its row is already painted, so this is a warning rather than a failure — but it is not swallowed either: the reader chose a …
                is RecentsResult.Unavailable ->
                    _uiState.update { it.copy(taskCreateError = result.message) }
                is RecentsResult.Loaded -> Unit
            }
        }
    }

    /** Clear the last create's complaint, and only that. */
    fun dismissTaskCreateError() {
        _uiState.update { it.copy(taskCreateError = null) }
    }

    /** Drop every project, expanded or paged, on sign-out. */
    private fun clearProjects() {
        projectsJob?.cancel()
        moreProjectChatsJobs.values.forEach { it.cancel() }
        moreProjectChatsJobs.clear()
        projectCursors.clear()
        projectGenerations.clear()
        projectsGeneration++
        projectsCache.clear()
    }

    /** Sign-out. */
    fun onSignedOut() {
        userId = null
        hasStarted = false
        _uiState.value = HomeUiState()
        workspacesJob?.cancel()
        chatsJob?.cancel()
        // A page in flight belongs to the session that just ended; letting it land would repopulate a sidebar for an account that is signed out.
        moreChatsJob?.cancel()
        chatsCursor = null
        chatsGeneration++
        clearProjects()
        // The saved position goes with the rows.
        resumeWorkspaceSeed = null
        cache.clear()
        positionStore.clear()
    }

    /** A 401 means the cookie the auth flow saved is no longer valid. */
    private fun expireSession() {
        _uiState.update { it.copy(isLoading = false) }
        _sessionExpired.tryEmit(Unit)
    }

    companion object {
        /** Shown when the default project could not be resolved, so the drawer's "New Chat" appears to do nothing with no explanation. */
        const val DEFAULT_PROJECT_ERROR_MESSAGE =
            "Could not start a new chat. Try again in a moment."

        /** How long a burst of server events is allowed to coalesce into one reload of the recents list. */
        const val SSE_RELOAD_DEBOUNCE_MILLIS = 400L

        /** The `session_*` action that removes the row. */
        const val ACTION_SESSION_DELETED = "deleted"

        /** [positionStore] is passed in rather than built here so the caller controls its lifetime: `MainActivity` holds one instance for the whole process, and the nav … */
        fun factory(
            application: Application,
            positionStore: LastPositionStore,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                HomeViewModel(
                    client = RecentsClient(
                        sessionStore = SessionCookieStore(application),
                        // Recorded like auth, so the inspector shows the exact bytes the sidebar sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    cache = RoomRecentsCache(application),
                    // Recorded like the recents calls, so the inspector shows the exact bytes the drawer sent for the project endpoints too — for free, by construction.
                    projectsClient = ProjectsClient(
                        sessionStore = SessionCookieStore(application),
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    projectsCache = RoomProjectsCache(application),
                    // Recorded like the project calls, so the inspector shows the exact bytes the "New task" form sent for the board's columns — the one request whose response a …
                    kanbanClient = KanbanClient(
                        sessionStore = SessionCookieStore(application),
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    positionStore = positionStore,
                    // The app's one bus, so a chat started on the webview reaches this drawer.
                    bus = SseBusHolder.get(SessionCookieStore(application)),
                )
            }
        }
    }
}

// Which workspace the drawer should show, in the one precedence that decides.
internal fun defaultProjectId(projects: List<ProjectSummary>): String? =
    projects.firstOrNull { it.isDefault }?.id

internal fun selectWorkspaceId(
    workspaces: List<WorkspaceOption>,
    currentSelection: String?,
    resumeSeed: String?,
): String? = workspaces.firstOrNull { it.id == currentSelection }?.id
    ?: workspaces.firstOrNull { it.id == resumeSeed }?.id
    ?: workspaces.firstOrNull()?.id

/** The two messages a form can earn *before* the request leaves. */
private const val INVALID_MEMORY_NAME_MESSAGE =
    "The file name must end in .md, and cannot contain /, \\ or .."
private const val EMPTY_MEMORY_CONTENT_MESSAGE = "A memory needs some content."

/** Says "task", not "card". */
private const val EMPTY_TASK_TITLE_MESSAGE = "A task needs a title."
