package com.pabrik.mobile.worker

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.ChatClient
import com.pabrik.mobile.chat.ChatResult
import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState
import com.pabrik.mobile.chat.SseBus
import com.pabrik.mobile.chat.SseBusHolder
import com.pabrik.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Keeps [RunningSessionsStore] in step with the backend's `worker` table for the whole app, not for one screen. */
class WorkerActivityViewModel(
    private val client: ChatClient,
    private val store: RunningSessionsStore,
    /** The app's ONE event connection, shared with the chat. */
    private val bus: SseBus,
    // Injected so tests can drive the resync on the same scheduler as the stream callbacks; `advanceUntilIdle` cannot wait on the real IO pool.
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    /** The periodic reconciliation beat, as a stream of ticks. */
    private val resyncTicks: Flow<Unit> = flow {
        while (currentCoroutineContext().isActive) {
            delay(RESYNC_INTERVAL_MILLIS)
            emit(Unit)
        }
    },
) : ViewModel() {
    val runningSessionIds: StateFlow<Set<String>> = store.runningSessionIds

    private var resyncJob: Job? = null
    private var tickJob: Job? = null
    private var tracked = false
    private var lastResyncAtMillis = 0L
    private var currentUserId: String? = null
    private var unsubscribeFromBus: (() -> Unit)? = null

    init {
        unsubscribeFromBus = bus.subscribe(
            onEvent = { event -> handleEvent(event) },
            onState = { state -> handleState(state) },
        )
    }

    /** Starts the subscription, or tears it down when nobody is signed in. */
    fun onUserChanged(newUserId: String?) {
        if (newUserId.isNullOrBlank()) {
            stopTracking()
            // Not reset by `stopTracking()` itself, because it short-circuits when nothing is being tracked.
            currentUserId = null
            return
        }
        if (newUserId == currentUserId) {
            if (!tracked) startTracking()
            return
        }
        // A *different* account is as much a teardown as a sign-out.
        stopTracking()
        currentUserId = newUserId
        startTracking()
    }

    /** Sign-out. The ids are not account-scoped, so they cannot outlive the cookie. */
    fun onSignedOut() {
        stopTracking()
        currentUserId = null
    }

    /** Re-reads the list on the way back into the app, ignoring the throttle. */
    fun onForeground() {
        if (!tracked) return
        resync(force = true)
    }

    /** Starts the reconciliation beat for a signed-in account. */
    private fun startTracking() {
        tracked = true
        tickJob?.cancel()
        tickJob = viewModelScope.launch {
            resyncTicks.collect { resync() }
        }
    }

    private fun stopTracking() {
        if (!tracked) return
        tracked = false
        resyncJob?.cancel()
        resyncJob = null
        tickJob?.cancel()
        tickJob = null
        lastResyncAtMillis = 0L
        store.clear()
    }

    override fun onCleared() {
        // `stopTracking()` alone is not enough: it returns early when nothing is being tracked, and the store is a process-wide singleton, so an Activity destroyed while …
        stopTracking()
        store.clear()
        unsubscribeFromBus?.invoke()
        unsubscribeFromBus = null
        super.onCleared()
    }

    /** The set is only *ours* to maintain while an account is signed in. */
    private fun handleEvent(event: ChatStreamEvent) {
        if (!tracked) return
        if (event is ChatStreamEvent.WorkerChanged) {
            store.apply(event.action, event.sessionId)
        }
    }

    private fun handleState(state: ChatStreamState) {
        if (!tracked) return
        // Every transition back to Live — including the first connect — is a moment where the set is possibly wrong: runs that started or stopped while the socket was …
        if (state is ChatStreamState.Live) resync()
    }

    /** Replaces the set with what the server reports *now*. */
    private fun resync(force: Boolean = false) {
        val now = nowMillis()
        if (!force && now - lastResyncAtMillis < RESYNC_THROTTLE_MILLIS) return
        lastResyncAtMillis = now

        resyncJob?.cancel()
        resyncJob = viewModelScope.launch {
            when (val result = withContext(ioDispatcher) { client.loadRunningSessions() }) {
                is ChatResult.Loaded -> store.replace(result.value)

                // A failed resync leaves the set exactly as it was.
                is ChatResult.SignedOut,
                is ChatResult.Rejected,
                is ChatResult.Unavailable,
                -> Unit
            }
        }
    }

    companion object {
        /** Matches the desktop's `lastWorkersFetchAt` guard. */
        const val RESYNC_THROTTLE_MILLIS = 10_000L

        /** How often the set is re-read while nothing else has prompted it. */
        const val RESYNC_INTERVAL_MILLIS = 30_000L

        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val sessionStore = SessionCookieStore(application)
                WorkerActivityViewModel(
                    client = ChatClient(
                        sessionStore = sessionStore,
                        // Recorded like auth, so the inspector shows the exact bytes this sent.
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                    store = RunningSessionsStore.default,
                    bus = SseBusHolder.get(sessionStore),
                )
            }
        }
    }
}
