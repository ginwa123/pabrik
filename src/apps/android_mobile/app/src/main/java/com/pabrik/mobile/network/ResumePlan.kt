package com.pabrik.mobile.network

import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.storage.LastPosition

/** What a relaunch should open, decided once, from the position the last run saved and the data that has loaded since. */
internal class ResumePlan(private val saved: LastPosition) {

    private var sessionResolved = false

    /** Whether the question has been answered — a chat to open, or a decision that there is none. */
    val isDecided: Boolean
        get() = sessionResolved

    /** The chat to open, or null while the question is still open. */
    fun resolveSession(
        chats: List<ChatSummary>,
        selectedWorkspaceId: String?,
        settled: Boolean,
    ): String? {
        if (sessionResolved || !settled) return null
        val sessionId = saved.sessionId
        // Latched even when the answer is null: "no chat was saved" cannot stop being true, so leaving it open would make every later recomposition re-decide it.
        if (sessionId.isNullOrBlank() || selectedWorkspaceId == null) {
            sessionResolved = true
            return null
        }
        // An empty list is NOT an answer, and this is the line that decides whether the feature works on a cold launch at all.
        if (chats.isEmpty()) return null
        sessionResolved = true
        return sessionId.takeIf { id -> chats.any { chat -> chat.id == id } }
    }
}

/** The chat a relaunch should open right now, or null for "not yet, or not at all". */
internal fun sessionToResume(
    authPhase: SessionPhase,
    currentRoute: String?,
    plan: ResumePlan?,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    isLoading: Boolean,
): String? {
    if (authPhase != SessionPhase.Authenticated) return null
    if (currentRoute != PabrikRoutes.SHELL) return null
    return plan?.resolveSession(
        chats = chats,
        selectedWorkspaceId = selectedWorkspaceId,
        settled = !isLoading,
    )
}
