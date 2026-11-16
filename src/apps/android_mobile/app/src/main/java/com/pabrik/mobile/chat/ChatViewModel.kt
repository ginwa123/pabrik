package com.pabrik.mobile.chat

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Owns one chat's real data. */
class ChatViewModel(
    private val client: ChatClient,
    private val cache: ChatCache,
    /** The app's ONE event connection, shared with the sidebar. */
    private val bus: SseBus,
    // Reads a picked `content://` image into an encoded attachment.
    private val imageReader: PickedImageReader = PickedImageReader { null },
    // Injected so tests can drive the fetch on the same scheduler as the paint; `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ChatUiState())
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    private val _sessionExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionExpired: SharedFlow<Unit> = _sessionExpired.asSharedFlow()

    /** Detaches from the root bus. */
    private var unsubscribeFromBus: (() -> Unit)? = null

    init {
        unsubscribeFromBus = bus.subscribe(
            onEvent = { event -> handleBusEvent(event) },
            onState = { state -> handleBusState(state) },
        )
    }

    private var userId: String? = null
    private var loadJob: Job? = null
    private var cachePrimeJob: Job? = null
    private var olderPagePrimeJob: Job? = null
    private var olderJob: Job? = null
    private var sendJob: Job? = null
    /** The `GET .../queue_messages` behind the composer's queue panel. */
    private var queueJob: Job? = null
    private var attachJob: Job? = null
    private var stopJob: Job? = null
    private var answerJob: Job? = null
    /** The `GET /api/config/pabrik` behind the composer's model picker. */
    private var profilesJob: Job? = null
    /** The `PUT /api/llm/session/{id}` that saves a picked profile. */
    private var profileJob: Job? = null

    /** Ids delivered live over SSE in this session view. */
    private val liveMessageIds = mutableSetOf<String>()

    /** Sub-agent pings seen so far, keyed by the spawning `tool_call_id`. */
    private val subAgentBatches = mutableMapOf<String, MutableSet<SubAgentPing>>()

    /** One sub-agent's latest known lifecycle state, keyed within its batch. */
    private data class SubAgentPing(
        val key: String,
        val status: String,
    )

    /** Cursor for the next *older* page, from the server's `has_more`. */
    private var olderCursor: String? = null

    /** Whether a full descending page has already answered the older-page question for the chat now open. */
    private var olderPageIsSettled: Boolean = false

    /** Bumped on every session change so a fetch that finishes late can tell it belongs to a chat the user already left. */
    private var generation: Int = 0

    /** Whether anything *newer than the cache* has painted for this generation. */
    @Volatile
    private var hasFreshContent: Boolean = false

    /** Has the bus dropped and come back since the open chat was opened? */
    private var hasConnectedStreamOnce = false

    /** Monotonic suffix for streaming placeholder ids. */
    private var streamingCounter: Long = 0

    /** The signed-in account namespaces the transcript cache. */
    fun onUserChanged(newUserId: String?) {
        val accountChanged = newUserId != userId
        userId = newUserId
        if (accountChanged) {
            // Blank rather than keep: the old transcript belongs to someone else.
            _uiState.value = ChatUiState()
            liveMessageIds.clear()
            subAgentBatches.clear()
            olderCursor = null
            olderPageIsSettled = false
            hasFreshContent = false
        }
    }

    /** Opens a chat: paint from cache, then attach the stream, then revalidate. */
    fun openSession(sessionId: String) {
        if (sessionId.isBlank()) return
        if (_uiState.value.sessionId == sessionId && !_uiState.value.isLoading) return

        generation++
        val requestGeneration = generation
        loadJob?.cancel()
        olderJob?.cancel()
        olderPagePrimeJob?.cancel()
        sendJob?.cancel()
        queueJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        // Nothing to detach: the bus is already carrying this chat's events and the handlers below filter by the session the state says is open.
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        olderPageIsSettled = false
        hasConnectedStreamOnce = false
        hasFreshContent = false

        // The empty paint is the *only* part of the prime that stays on the caller's thread, and it is a field assignment.
        _uiState.value = ChatUiState(sessionId = sessionId, isLoading = true)

        // The read and the parse are the expensive half, and they are not cheap because of the SQL: the cache keeps the *verbatim* server row, so a 400-row window is …
        cachePrimeJob?.cancel()
        cachePrimeJob = viewModelScope.launch {
            val painted = withContext(ioDispatcher) { readCachedTranscript(sessionId) }
            if (requestGeneration != generation) return@launch
            if (painted == null || hasFreshContent) return@launch
            // The cache reads newest-first; a transcript reads oldest-first.
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(messages = painted.sortedBy { it.sortKeyNanos })
                }
            }
        }

        restoreOlderPage(sessionId, requestGeneration)

        revalidate(sessionId, requestGeneration)
        reattachInFlightTurn(sessionId, requestGeneration)
        loadProfiles(requestGeneration)
        revalidateQueue(sessionId, requestGeneration)
    }

    /** Fetches the profile list the composer's picker offers. */
    private fun loadProfiles(requestGeneration: Int) {
        profilesJob?.cancel()
        profilesJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadProfiles() }
            if (requestGeneration != generation) return@launch
            val page = (result as? ChatResult.Loaded)?.value ?: return@launch
            _uiState.update { state ->
                state.copy(
                    availableProfiles = page.profiles,
                    activeProfile = page.activeProfile,
                    isLoadingProfiles = false,
                )
            }
        }
    }

    /** Reads the server's queue for this chat and *replaces* what is on screen. */
    private fun revalidateQueue(sessionId: String, requestGeneration: Int) {
        queueJob?.cancel()
        queueJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadQueuedMessages(sessionId) }
            if (requestGeneration != generation) return@launch
            val queued = (result as? ChatResult.Loaded)?.value ?: return@launch
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(queuedMessages = queued)
                }
            }
        }
    }

    /** Puts a waiting turn back in the box, which is the reader's way of editing it before the worker gets to it. */
    fun useQueuedMessage(message: QueuedChatMessage) {
        _uiState.update { state ->
            state.copy(draft = message.message.trim())
        }
    }

    /** Re-reads the queue behind an open panel. */
    fun refreshQueuedMessages() {
        val sessionId = _uiState.value.sessionId ?: return
        revalidateQueue(sessionId, generation)
    }

    /** Put this chat on [profileName], and remember that it is there. */
    fun selectProfile(profileName: String) {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        if (state.isUpdatingProfile) return

        profileJob?.cancel()
        _uiState.update { it.copy(isUpdatingProfile = true, errorMessage = null) }
        profileJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.updateSelectedProfile(sessionId, profileName)
            }
            when (result) {
                is ChatResult.Loaded -> _uiState.update {
                    // The server echoes the column it stored, which is the authority on what this chat will now use.
                    it.copy(
                        selectedProfileModel = result.value,
                        isUpdatingProfile = false,
                    )
                }

                is ChatResult.Rejected -> _uiState.update {
                    it.copy(isUpdatingProfile = false, errorMessage = result.message)
                }

                is ChatResult.Unavailable -> _uiState.update {
                    it.copy(isUpdatingProfile = false, errorMessage = result.message)
                }

                ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isUpdatingProfile = false) }
                    _sessionExpired.tryEmit(Unit)
                }
            }
        }
    }

    /** Puts the *older* paging boundary back, the way the transcript cache puts the messages back. */
    private fun restoreOlderPage(sessionId: String, requestGeneration: Int) {
        olderPagePrimeJob?.cancel()
        olderPagePrimeJob = viewModelScope.launch {
            val restored = withContext(ioDispatcher) { cache.readOlderPage(userId, sessionId) }
            if (requestGeneration != generation) return@launch
            if (olderPageIsSettled) return@launch
            olderCursor = restored?.cursor
            _uiState.update { state ->
                if (state.sessionId != sessionId) {
                    state
                } else {
                    state.copy(hasMoreOlder = restored?.hasMore == true)
                }
            }
        }
    }

    /** Re-attaches the partial text of a run that is already going. */
    private fun reattachInFlightTurn(sessionId: String, requestGeneration: Int) {
        viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.loadStreamSnapshot(sessionId) }
            if (requestGeneration != generation) return@launch
            // A failed snapshot must not disturb a transcript that loaded fine.
            val content = (result as? ChatResult.Loaded)?.value.orEmpty()
            if (content.isBlank()) return@launch
            hasFreshContent = true

            _uiState.update { state ->
                if (state.messages.any { message -> message.isStreaming }) {
                    state
                } else {
                    state.copy(
                        messages = state.messages + ChatMessage(
                            id = "${ChatMessage.STREAMING_ID_PREFIX}reattached",
                            role = ChatMessage.ROLE_ASSISTANT,
                            content = content,
                            createdAtEpochMillis = nowMillis(),
                            // Sorts last: the turn has not been written yet, so there is no server timestamp to order it by.
                            sortKeyNanos = Long.MAX_VALUE,
                            isStreaming = true,
                        ),
                        isStreaming = true,
                    )
                }
            }
        }
    }

    /** The last-known transcript, oldest-first, or null when there is none. */
    private fun readCachedTranscript(sessionId: String): List<ChatMessage>? {
        val cached = cache.readMessages(userId, sessionId, CACHED_MESSAGE_LIMIT)
        if (cached.isNullOrEmpty()) return null
        return cached.mapNotNull { ChatApi.toChatMessage(it.raw) }
    }

    /** [isFullReload] is true only for a cold load, i.e. one with no stored cursor. */
    private fun revalidate(sessionId: String, requestGeneration: Int) {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val storedCursor = withContext(ioDispatcher) { cache.readCursor(userId, sessionId) }
            val isFullReload = storedCursor == null
            val (result, runIsActive) = withContext(ioDispatcher) {
                // Two reads, one instant, because neither alone can tell a finished run from a live one.
                val page = client.loadMessages(
                    sessionId = sessionId,
                    cursor = storedCursor,
                    // Cold (no cursor): a full descending load.
                    direction = if (storedCursor == null) "desc" else "asc",
                )
                // A read that failed answers nothing, and the only safe answer to "nothing" here is "still running" — same rule `WorkerActivityViewModel` applies to its own set.
                val active = (client.isSessionRunning(sessionId) as? ChatResult.Loaded)?.value
                page to (active ?: true)
            }

            if (requestGeneration != generation) return@launch

            when (result) {
                is ChatResult.SignedOut -> expireSession()

                is ChatResult.Rejected -> _uiState.update {
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is ChatResult.Unavailable -> _uiState.update {
                    // Keep whatever is on screen — cached or not.
                    it.copy(isLoading = false, errorMessage = result.message)
                }

                is ChatResult.Loaded -> applyPage(
                    page = result.value,
                    sessionId = sessionId,
                    isFullReload = isFullReload,
                    runIsActive = runIsActive,
                )
            }
        }
    }

    /** What one refetch has to say about the turn that was in flight. */
    private class StreamingSettle(
        val rows: List<ChatMessage>,
        val stillStreaming: Boolean,
    )

    /** Reconciles the streaming placeholder against what the server just said. */
    private fun settleStreaming(
        rows: List<ChatMessage>,
        incoming: List<ChatMessage>,
        runIsActive: Boolean,
    ): StreamingSettle {
        if (rows.none { it.isStreamingPlaceholder }) {
            // Nothing to settle, and nothing this refetch is entitled to conclude about a run: no row is frozen, so the flag belongs to whatever wrote it.
            return StreamingSettle(rows, stillStreaming = true)
        }

        // The placeholder is always the newest turn, so the row that can retire it is the newest assistant turn that is not itself a placeholder.
        val newestAssistant = (incoming + rows.filterNot { it.isStreamingPlaceholder })
            .filter { it.role == ChatMessage.ROLE_ASSISTANT }
            .maxByOrNull { it.sortKeyNanos }

        val settled = rows.mapNotNull { row ->
            if (!row.isStreamingPlaceholder) return@mapNotNull row
            if (newestAssistant?.supersedesStreaming(row) == true) {
                // The turn landed.
                null
            } else if (runIsActive) {
                row
            } else {
                // No worker, no row: the turn ended without being written, so the text on screen is the answer and must stop claiming otherwise.
                row.copy(isStreaming = false)
            }
        }
        return StreamingSettle(rows = settled, stillStreaming = runIsActive && settled.any { it.isStreaming })
    }

    private suspend fun applyPage(
        page: ChatPage,
        sessionId: String,
        isFullReload: Boolean,
        runIsActive: Boolean,
    ) {
        val incoming = page.messages.filterNot { message -> message.id in liveMessageIds }
        // Whatever the network just returned is newer than the cache, so the prime must not be allowed to land on top of it.
        hasFreshContent = true

        _uiState.update { state ->
            val settle = settleStreaming(state.messages, incoming, runIsActive)
            state.copy(
                isLoading = false,
                messages = ChatApi.mergeById(settle.rows, incoming)
                    .sortedBy { message -> message.sortKeyNanos },
                isStreaming = state.isStreaming && settle.stillStreaming,
                selectedProfileModel = page.selectedProfileModel
                    .ifEmpty { state.selectedProfileModel },
                cwd = page.cwd.ifEmpty { state.cwd },
                errorMessage = null,
            )
        }
        if (isFullReload) {
            olderCursor = page.nextCursor
            olderPageIsSettled = true
            _uiState.update { it.copy(hasMoreOlder = page.hasMore) }
        }

        withContext(ioDispatcher) {
            // The cursor advance is skipped when any row was filtered out as live: advancing past a row that was deliberately not written leaves a hole the next tail fetch …
            if (incoming.size == page.messages.size) {
                val rows = incoming.mapNotNull { message ->
                    ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message))
                }
                if (rows.isNotEmpty()) {
                    cache.writeMessages(userId, sessionId, rows)
                    val previous = cache.readCursor(userId, sessionId)
                    cache.writeCursor(
                        userId,
                        sessionId,
                        ChatCacheCodec.newestCursor(rows, page.nextCursor, previous),
                    )
                }
                // Only a *full descending* page carries a boundary.
                if (isFullReload) {
                    cache.writeOlderPage(
                        userId,
                        sessionId,
                        page.nextCursor?.let { ChatOlderPage(cursor = it, hasMore = page.hasMore) },
                    )
                }
            }
        }
    }

    /** A scroll to the top pages backwards. */
    fun loadOlderMessages() {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        if (state.isLoadingOlder || !state.hasMoreOlder) return
        val cursor = olderCursor ?: return
        if (state.messages.isEmpty()) return

        val requestGeneration = generation
        olderJob?.cancel()
        olderJob = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingOlder = true) }
            val result = withContext(ioDispatcher) {
                client.loadMessages(
                    sessionId = sessionId,
                    limit = OLDER_PAGE_LIMIT,
                    cursor = cursor,
                    direction = "desc",
                )
            }
            if (requestGeneration != generation) return@launch

            when (result) {
                is ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isLoadingOlder = false) }
                    expireSession()
                }

                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(isLoadingOlder = false) }

                is ChatResult.Loaded -> {
                    hasFreshContent = true
                    val older = result.value.messages
                        .filterNot { message -> message.id in liveMessageIds }
                        .asReversed()
                    _uiState.update { current ->
                        // A tail fetch may have appended while this page was in flight, so merge by id rather than prepending blindly.
                        val known = current.messages.map { message -> message.id }.toSet()
                        current.copy(
                            messages = ChatApi.mergeById(
                                older.filterNot { message -> message.id in known },
                                current.messages,
                            ),
                            isLoadingOlder = false,
                            hasMoreOlder = result.value.hasMore,
                        )
                    }
                    // An empty page means we reached the start of the transcript; holding the old cursor would re-request it forever.
                    olderCursor = result.value.nextCursor?.takeIf { older.isNotEmpty() }
                    olderPageIsSettled = true

                    // The boundary moved, so the one on disk is stale.
                    val moved = olderCursor?.let { ChatOlderPage(it, result.value.hasMore) }
                    withContext(ioDispatcher) {
                        if (older.isNotEmpty()) {
                            cache.writeMessages(
                                userId,
                                sessionId,
                                older.mapNotNull { message ->
                                    ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(message))
                                },
                            )
                        }
                        cache.writeOlderPage(userId, sessionId, moved)
                    }
                }
            }
        }
    }

    fun onDraftChanged(value: String) {
        _uiState.update { it.copy(draft = value) }
    }

    /** Decode a picked image and add it to the turn being composed. */
    fun attachImage(source: String) {
        if (_uiState.value.isAttaching) return
        attachJob?.cancel()
        _uiState.update { it.copy(isAttaching = true, errorMessage = null) }
        attachJob = viewModelScope.launch {
            val attachment = imageReader.read(source)
            val state = _uiState.value
            when {
                attachment == null -> _uiState.update {
                    it.copy(isAttaching = false, errorMessage = "That image could not be read.")
                }

                ChatAttachments.rejection(state.pendingAttachments, attachment.byteCount) != null ->
                    _uiState.update {
                        it.copy(
                            isAttaching = false,
                            errorMessage = ChatAttachments.rejection(
                                state.pendingAttachments,
                                attachment.byteCount,
                            ),
                        )
                    }

                // Re-picked the same photo.
                state.pendingAttachments.any { it.id == attachment.id } ->
                    _uiState.update { it.copy(isAttaching = false) }

                else -> _uiState.update {
                    it.copy(
                        isAttaching = false,
                        pendingAttachments = it.pendingAttachments + attachment,
                    )
                }
            }
        }
    }

    /** Drop one attached image. */
    fun removeAttachment(id: String) {
        _uiState.update { state ->
            state.copy(pendingAttachments = state.pendingAttachments.filterNot { it.id == id })
        }
    }

    /** Queues a turn. */
    fun sendMessage() {
        val state = _uiState.value
        val sessionId = state.sessionId ?: return
        val text = state.draft.trim()
        // An image on its own is a turn.
        val attachments = state.pendingAttachments
        if ((text.isEmpty() && attachments.isEmpty()) || state.isSending) return

        sendJob?.cancel()
        _uiState.update { it.copy(isSending = true, errorMessage = null) }
        sendJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.sendMessage(
                    sessionId = sessionId,
                    message = text,
                    cwd = state.cwd,
                    // Already-encoded data URLs.
                    imageUrls = ChatAttachments.dataUrls(attachments),
                    selectedProfileModel = state.selectedProfileModel,
                )
            }
            when (result) {
                is ChatResult.Loaded -> _uiState.update {
                    it.copy(isSending = false, draft = "", pendingAttachments = emptyList())
                }

                is ChatResult.SignedOut -> {
                    _uiState.update { it.copy(isSending = false) }
                    expireSession()
                }

                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update {
                    // The draft survives, so a failed send is one tap to retry rather than a retyped message.
                    it.copy(isSending = false, errorMessage = messageFor(result))
                }
            }
        }
    }

    fun stopRun() {
        val sessionId = _uiState.value.sessionId ?: return
        val requestGeneration = generation
        stopJob?.cancel()
        stopJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) { client.stopRun(sessionId) }
            // A stop for a chat the user already left must not surface its error, or sign out on, the chat now on screen.
            if (requestGeneration != generation) return@launch
            when (result) {
                is ChatResult.SignedOut -> expireSession()
                // Cleared on the way out, not left to the frames that will follow.
                is ChatResult.Loaded -> stopStreaming()

                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(errorMessage = messageFor(result)) }
            }
        }
    }

    /** Settles a pending `ask_user` question. */
    fun answerQuestion(
        questionId: String?,
        toolCallId: String,
        answer: String? = null,
        skip: Boolean = false,
    ) {
        val sessionId = _uiState.value.sessionId ?: return
        if (answer.isNullOrBlank() && !skip) return
        val requestGeneration = generation
        answerJob?.cancel()
        answerJob = viewModelScope.launch {
            val result = withContext(ioDispatcher) {
                client.answerQuestion(
                    sessionId = sessionId,
                    questionId = questionId,
                    toolCallId = toolCallId,
                    answer = answer,
                    skip = skip,
                )
            }
            if (requestGeneration != generation) return@launch
            when (result) {
                is ChatResult.Loaded -> {
                    // The rewritten tool row arrives over SSE; refetching too covers the case where the stream is down, which is exactly when the reader most needs the answer to …
                    revalidate(sessionId, requestGeneration)
                }

                is ChatResult.SignedOut -> expireSession()
                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> _uiState.update { it.copy(errorMessage = messageFor(result)) }
            }
        }
    }

    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    /** Sign-out. */
    fun onSignedOut() {
        generation++
        // The socket is not this ViewModel's to close any more -- `MainActivity` closes the bus, which is what holds the cookie.
        userId = null
        liveMessageIds.clear()
        subAgentBatches.clear()
        olderCursor = null
        olderPageIsSettled = false
        _uiState.value = ChatUiState()
        hasFreshContent = false
        cachePrimeJob?.cancel()
        olderPagePrimeJob?.cancel()
        loadJob?.cancel()
        olderJob?.cancel()
        sendJob?.cancel()
        queueJob?.cancel()
        stopJob?.cancel()
        answerJob?.cancel()
        cache.clear()
    }

    override fun onCleared() {
        cachePrimeJob?.cancel()
        olderPagePrimeJob?.cancel()
        unsubscribeFromBus?.invoke()
        unsubscribeFromBus = null
        super.onCleared()
    }

    /** Drops the claim that a turn is still arriving — in **both** the places it is held, because the header and the transcript read different ones. */
    private fun stopStreaming(
        errorMessage: String? = null,
        isLive: Boolean? = null,
    ) {
        _uiState.update { state ->
            state.copy(
                isStreaming = false,
                messages = state.messages.map { message ->
                    if (message.isStreaming) message.copy(isStreaming = false) else message
                },
                errorMessage = errorMessage ?: state.errorMessage,
                isLive = isLive ?: state.isLive,
            )
        }
    }

    /** The bus's connection state, narrowed to the chat that is open. */
    private fun handleBusState(state: ChatStreamState) {
        val sessionId = _uiState.value.sessionId ?: return
        when (state) {
            is ChatStreamState.Live -> {
                _uiState.update { it.copy(isLive = true) }
                // A *re*connect means events were missed with no way to ask for them, so the only repair is a refetch.
                if (hasConnectedStreamOnce) {
                    revalidate(sessionId, generation)
                    // Same reasoning, applied to the queue: frames lost while the socket was down are gone, and the list the reader is about to tap is built out of exactly those …
                    revalidateQueue(sessionId, generation)
                }
                hasConnectedStreamOnce = true
            }

            is ChatStreamState.Connecting,
            is ChatStreamState.Reconnecting,
            -> _uiState.update { it.copy(isLive = false) }

            // Terminal, so this is the last word on the turn.
            is ChatStreamState.Failed -> stopStreaming(
                errorMessage = state.message,
                isLive = false,
            )
        }
    }

    /** One handler for every event on the shared bus, scoped to the open chat. */
    private fun handleBusEvent(event: ChatStreamEvent) {
        val sessionId = _uiState.value.sessionId ?: return
        when (event) {
            is ChatStreamEvent.Connected -> Unit

            is ChatStreamEvent.Chunk ->
                if (event.sessionId == sessionId) appendStreamingChunk(event)

            is ChatStreamEvent.ChunkFinished ->
                if (event.sessionId == sessionId) finishStreaming()

            is ChatStreamEvent.Full ->
                if (event.sessionId == sessionId) upsertFullMessage(sessionId, event)

            // A fan-out that reports nothing for two minutes looks like a hang.
            is ChatStreamEvent.SubAgentProgress ->
                if (event.sessionId == sessionId) recordSubAgentProgress(event)

            is ChatStreamEvent.SessionChanged ->
                if (event.sessionId == sessionId) revalidate(sessionId, generation)

            // Mirrored, not counted.
            is ChatStreamEvent.QueueChanged ->
                if (event.sessionId == sessionId) applyQueueChange(event)

            // A diagnostic frame (`is_error`) is not a run in progress, so it must clear the flag too — otherwise the header claims the agent is still working after it has …
            is ChatStreamEvent.Failed -> stopStreaming(errorMessage = event.message)

            // Worker liveness is not this screen's state.
            is ChatStreamEvent.WorkerChanged -> Unit
        }
    }

    /** Folds one `queue_queued` / `queue_deleted` frame into the mirror. */
    private fun applyQueueChange(event: ChatStreamEvent.QueueChanged) {
        _uiState.update { state ->
            when (event.action) {
                ChatStreamEvent.QueueChanged.ACTION_QUEUED -> {
                    if (state.queuedMessages.any { it.id == event.id }) {
                        state
                    } else {
                        state.copy(
                            queuedMessages = state.queuedMessages + QueuedChatMessage(
                                id = event.id,
                                message = event.message,
                            ),
                        )
                    }
                }

                else -> state.copy(
                    queuedMessages = state.queuedMessages.filterNot { it.id == event.id },
                )
            }
        }
    }

    /** The backend sends *raw provider deltas*, so this appends. */
    private fun appendStreamingChunk(event: ChatStreamEvent.Chunk) {
        hasFreshContent = true
        _uiState.update { state ->
            val existing = state.messages.lastOrNull { message -> message.isStreaming }
            val placeholder = ChatMessage(
                id = existing?.id ?: nextStreamingId(),
                role = ChatMessage.ROLE_ASSISTANT,
                content = (existing?.content.orEmpty()) + event.content,
                createdAtEpochMillis = nowMillis(),
                // Sorts last, so the placeholder is never spliced into the middle of a transcript whose later turns already arrived.
                sortKeyNanos = existing?.sortKeyNanos ?: Long.MAX_VALUE,
                reasoningContent = (existing?.reasoningContent.orEmpty()) +
                    event.reasoningContent,
                isStreaming = true,
            )
            state.copy(
                messages = state.messages.filterNot { message -> message.isStreaming } + placeholder,
                isStreaming = true,
            )
        }
    }

    private fun nextStreamingId(): String =
        "${ChatMessage.STREAMING_ID_PREFIX}${++streamingCounter}"

    private fun finishStreaming() {
        // The placeholder deliberately stays: the canonical row has not arrived yet, and dropping it here flashes an empty bubble between the last delta and the …
        _uiState.update { state ->
            val placeholder = state.messages.lastOrNull { message -> message.isStreaming }
                ?: return@update state.copy(isStreaming = false)
            state.copy(
                messages = state.messages.map { message ->
                    if (message.id == placeholder.id) message.copy(isStreaming = false) else message
                },
                isStreaming = false,
            )
        }
    }

    /** The canonical row for a turn. */
    private fun upsertFullMessage(sessionId: String, event: ChatStreamEvent.Full) {
        val message = event.message
        liveMessageIds += message.id
        hasFreshContent = true

        _uiState.update { state ->
            // Match the placeholder by its RESERVED ID, not just by `isStreaming`: `finishStreaming` has already cleared that flag by the time the canonical row lands, so …
            val dropped = state.messages.filterNot { candidate ->
                candidate.isStreamingPlaceholder ||
                    candidate.id == message.id
            }
            state.copy(
                messages = dropped + message.stampedForArrival(dropped),
                isStreaming = false,
                errorMessage = null,
            )
        }

        // The STAMPED row is what goes to disk, not the frame as it arrived.
        val placed = _uiState.value.messages.lastOrNull { it.id == message.id }
            ?: message

        viewModelScope.launch {
            withContext(ioDispatcher) {
                cache.writeMessages(
                    userId,
                    sessionId,
                    listOfNotNull(
                        ChatCacheCodec.toCachedMessage(sessionId, rawObjectFor(placed)),
                    ),
                )
            }
        }
    }

    /** Gives a frame-delivered row a sort key it can actually be ordered by. */
    private fun ChatMessage.stampedForArrival(siblings: List<ChatMessage>): ChatMessage {
        if (sortKeyNanos > 0L) return this
        val millis = nowMillis()
        val newestSibling = siblings
            .map { it.sortKeyNanos }
            .filter { it in 1 until Long.MAX_VALUE }
            .maxOrNull() ?: 0L
        return copy(
            createdAtEpochMillis = millis,
            sortKeyNanos = maxOf(millis * ChatApi.NANOS_PER_MILLI, newestSibling + 1L),
        )
    }

    /** Folds one sub-agent lifecycle ping into the header counters. */
    private fun recordSubAgentProgress(event: ChatStreamEvent.SubAgentProgress) {
        // A ping with no `agent_name` still happened, and still has to count.
        val key = event.agentName.ifBlank { "#${event.agentIndex}" }
        val batch = subAgentBatches.getOrPut(event.toolCallId) { mutableSetOf() }
        batch.removeIf { it.key == key }
        batch.add(SubAgentPing(key = key, status = event.status))

        val launched = batch.size
        val finished = batch.count { it.status != ChatStreamEvent.SubAgentProgress.STATUS_LAUNCHED }
        val failed = batch.count { it.status == ChatStreamEvent.SubAgentProgress.STATUS_FAILED }

        // A batch the backend never told us the size of is pruned once every member it *did* report has finished, so a session that runs a hundred fan-outs does not …
        val complete = finished > 0 && (
            finished == launched &&
                (event.totalAgents <= 0 || finished >= event.totalAgents)
            )

        _uiState.update { state ->
            state.copy(
                subAgentsTotal = maxOf(event.totalAgents, launched),
                subAgentsRunning = (launched - finished).coerceAtLeast(0),
                subAgentsFailed = failed,
            )
        }
        if (complete) {
            subAgentBatches.remove(event.toolCallId)
            _uiState.update { it.copy(subAgentsRunning = 0) }
        }
    }

    private fun messageFor(result: ChatResult<*>): String = when (result) {
        is ChatResult.Rejected -> result.message
        is ChatResult.Unavailable -> result.message
        is ChatResult.SignedOut -> "Your session expired. Sign in again."
        is ChatResult.Loaded -> ""
    }

    /** Rebuilds the wire object for a message. */
    private fun rawObjectFor(message: ChatMessage): JSONObject = JSONObject()
        .put("id", message.id)
        .put("session_id", _uiState.value.sessionId.orEmpty())
        .put("role", message.role)
        .put("content", message.content)
        .put("created_at", message.sortKeyNanos.toString())
        .put("is_input", message.role == ChatMessage.ROLE_USER)
        .put("is_output", message.role == ChatMessage.ROLE_ASSISTANT)
        .put("tool_name", message.toolName)
        .put("finish_reason", message.finishReason)
        .put("reasoning_content", message.reasoningContent)
        .put("tool_call_id", message.toolCallId)
        .put("image_url", message.imageUrls.joinToString("|"))
        .put("video_url", message.videoUrls.joinToString("|"))
        .put("diffview_before", message.diffviewBefore)
        .put("diffview_after", message.diffviewAfter)
        .put("tool_calls_json", message.toolCallsJson)

    private fun expireSession() {
        _uiState.update {
            it.copy(isLoading = false, isSending = false, isLoadingOlder = false)
        }
        _sessionExpired.tryEmit(Unit)
    }

    companion object {
        /** Bounded so the cache read in [readCachedTranscript] is a bounded amount of JSON on a background dispatcher rather than an unbounded one. */
        const val CACHED_MESSAGE_LIMIT = 400

        const val OLDER_PAGE_LIMIT = 200

        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val sessionStore = SessionCookieStore(application)
                ChatViewModel(
                    client = ChatClient(
                        sessionStore = sessionStore,
                        // Recorded like auth, so the inspector shows the exact bytes the chat sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    cache = RoomChatCache(application),
                    bus = SseBusHolder.get(sessionStore),
                    imageReader = BitmapPickedImageReader(application.contentResolver),
                )
            }
        }
    }
}
