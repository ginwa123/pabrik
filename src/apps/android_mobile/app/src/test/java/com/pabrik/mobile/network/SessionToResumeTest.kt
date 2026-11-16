package com.pabrik.mobile.network

import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.storage.LastPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The four conditions that have to hold before a relaunch is allowed to open a chat, and nothing else. */
class SessionToResumeTest {

    @Test
    fun `a plain relaunch on the shell opens the saved chat`() {
        assertEquals("sess_c", resume())
    }

    @Test
    fun `nothing opens before the session is authenticated`() {
        // The sidebar's data lands while the auth phase is still settling, and the launch screen is what is on screen then.
        SessionPhase.entries
            .filter { it != SessionPhase.Authenticated }
            .forEach { phase ->
                assertNull("resumed during $phase", resume(authPhase = phase))
            }
    }

    @Test
    fun `a deep link wins over the saved chat`() {
        // `pabrik://chat/sess_x` put that route on the stack and the user is looking at it.
        assertNull(resume(currentRoute = PabrikRoutes.chat("sess_x")))
        assertNull(resume(currentRoute = PabrikRoutes.NETWORK))
        assertNull(resume(currentRoute = PabrikRoutes.recordDetail(7L)))
    }

    @Test
    fun `an empty back stack is not treated as somewhere else`() {
        // `NavHost` with no destination renders nothing, and the graph answers that with its own recovery screen.
        assertEquals("sess_c", resume(currentRoute = PabrikRoutes.SHELL))
    }

    @Test
    fun `nothing opens while the chat list is still loading`() {
        // The cached paint is a picture of a list that may since have lost the chat.
        assertNull(resume(isLoading = true))
    }

    @Test
    fun `a chat the server no longer lists is not opened`() {
        val plan = plan(session = "sess_deleted")
        assertNull(
            sessionToResume(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                plan = plan,
                chats = CHATS,
                selectedWorkspaceId = "ws_b",
                isLoading = false,
            ),
        )
    }

    @Test
    fun `nothing opens before the store has been read`() {
        // The read is on IO, so for the first frames of a launch there is no plan to act on.
        assertNull(
            sessionToResume(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                plan = null,
                chats = CHATS,
                selectedWorkspaceId = "ws_b",
                isLoading = false,
            ),
        )
    }

    private fun resume(
        authPhase: SessionPhase = SessionPhase.Authenticated,
        currentRoute: String? = PabrikRoutes.SHELL,
        isLoading: Boolean = false,
    ) = sessionToResume(
        authPhase = authPhase,
        currentRoute = currentRoute,
        plan = plan(session = "sess_c"),
        chats = CHATS,
        selectedWorkspaceId = "ws_b",
        isLoading = isLoading,
    )

    private fun plan(session: String?) = ResumePlan(
        LastPosition(workspaceId = "ws_b", sessionId = session),
    )

    private companion object {
        val CHATS = listOf("sess_a", "sess_c", "sess_b").mapIndexed { index, id ->
            ChatSummary(
                id = id,
                workspaceId = "ws_b",
                title = "Chat $id",
                updatedAtEpochMillis = 1_000L + index,
            )
        }
    }
}
