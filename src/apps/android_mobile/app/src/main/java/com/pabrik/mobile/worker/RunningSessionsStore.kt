package com.pabrik.mobile.worker

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The app-wide set of sessions with a live worker — the one place that knows which chats are busy, for the whole process rather than for one screen. */
class RunningSessionsStore {
    private val _runningSessionIds = MutableStateFlow<Set<String>>(emptySet())

    /** Session ids of every run currently in flight. */
    val runningSessionIds: StateFlow<Set<String>> = _runningSessionIds.asStateFlow()

    /** Folds one worker lifecycle event into the set. */
    fun apply(action: String, sessionId: String) {
        if (sessionId.isEmpty()) return
        val current = _runningSessionIds.value
        if (action == ACTION_DELETED) {
            if (sessionId !in current) return
            _runningSessionIds.value = current - sessionId
        } else {
            if (sessionId in current) return
            _runningSessionIds.value = current + sessionId
        }
    }

    /** Replaces the set wholesale from a [WorkerApi] bootstrap. */
    fun replace(sessionIds: Set<String>) {
        if (_runningSessionIds.value == sessionIds) return
        _runningSessionIds.value = sessionIds
    }

    /** Drops every session. */
    fun clear() {
        if (_runningSessionIds.value.isEmpty()) return
        _runningSessionIds.value = emptySet()
    }

    fun isRunning(sessionId: String?): Boolean =
        sessionId != null && sessionId in _runningSessionIds.value

    companion object {
        const val ACTION_CREATED = "created"
        const val ACTION_UPDATED = "updated"
        const val ACTION_DELETED = "deleted"

        val default = RunningSessionsStore()
    }
}
