package com.pabrik.mobile.network

import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.storage.LastPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The session half of "reopen where the user left off", with no Android, no Compose and no ViewModel. */
class ResumePlanTest {

    @Test
    fun `the saved chat is opened once the list settles`() {
        assertEquals(
            "sess_c",
            plan(session = "sess_c").resolveSession(chats(CHATS), "ws_b", settled = true),
        )
    }

    @Test
    fun `nothing is decided before the list has settled`() {
        // `settled = false` and "there is no such chat" both answer null, and conflating them is the bug: the first is a question still open, the second is a question …
        assertNull(plan(session = "sess_c").resolveSession(chats(CHATS), "ws_b", settled = false))
    }

    @Test
    fun `the question stays open until the list settles`() {
        val plan = plan(session = "sess_c")
        assertNull(plan.resolveSession(chats(CHATS), "ws_b", settled = false))
        assertNull(plan.resolveSession(emptyList(), "ws_b", settled = false))
        assertEquals(
            "sess_c",
            plan.resolveSession(chats(CHATS), "ws_b", settled = true),
        )
    }

    @Test
    fun `a chat the server no longer lists is not resumed`() {
        // Opening it would land on a route whose session is gone, and the transcript would come back empty with nothing to explain why.
        assertNull(plan(session = "sess_deleted").resolveSession(chats(CHATS), "ws_b", settled = true))
    }

    @Test
    fun `no saved chat leaves the app on the shell`() {
        assertNull(ResumePlan(LastPosition()).resolveSession(chats(CHATS), "ws_b", settled = true))
        assertNull(plan(session = "").resolveSession(chats(CHATS), "ws_b", settled = true))
        assertNull(plan(session = "   ").resolveSession(chats(CHATS), "ws_b", settled = true))
    }

    @Test
    fun `a workspace with no chats yet leaves the question open`() {
        // The cold launch.
        val plan = plan(session = "sess_c")
        assertNull(plan.resolveSession(emptyList(), "ws_b", settled = true))
        assertEquals(
            "sess_c",
            plan.resolveSession(chats(CHATS), "ws_b", settled = true),
        )
    }

    @Test
    fun `a list that has settled without the chat ends the question`() {
        val plan = plan(session = "sess_c")
        assertNull(plan.resolveSession(chats(listOf("sess_a", "sess_b")), "ws_b", settled = true))
        // The workspace is not empty, so this was a decision, and a later page containing the saved chat must not produce a navigation the user never asked for.
        assertNull(plan.resolveSession(chats(CHATS), "ws_b", settled = true))
    }

    @Test
    fun `no workspace selected yet resolves to the shell`() {
        // Reachable: the saved workspace is gone, so the drawer fell back to a different one, and this plan was asked before that selection landed.
        val plan = plan(session = "sess_c")
        assertNull(plan.resolveSession(chats(CHATS), null, settled = true))
        assertNull(plan.resolveSession(chats(CHATS), "ws_b", settled = true))
    }

    @Test
    fun `an answered question is never answered differently`() {
        val missing = plan(session = "sess_deleted")
        assertNull(missing.resolveSession(chats(CHATS), "ws_b", settled = true))
        // The list grows and, for this test, contains the saved id.
        assertNull(missing.resolveSession(chats(CHATS + "sess_deleted"), "ws_b", settled = true))

        val present = plan(session = "sess_c")
        assertEquals("sess_c", present.resolveSession(chats(CHATS), "ws_b", settled = true))
        assertNull(present.resolveSession(chats(CHATS), "ws_b", settled = true))
    }

    @Test
    fun `the saved workspace alone is not a chat to open`() {
        // The half that has no route of its own: resuming workspace B means the drawer shows B, which `HomeViewModel` has already done by the time this is asked.
        assertNull(
            plan(session = null).resolveSession(chats(CHATS), "ws_b", settled = true),
        )
    }

    @Test
    fun `the question is open until it has been answered`() {
        // The launch gate waits on this.
        val plan = plan(session = "sess_c")
        assertFalse(plan.isDecided)
        assertNull(plan.resolveSession(chats(CHATS), "ws_b", settled = false))
        assertFalse("a list still in flight is not an answer", plan.isDecided)
        assertNull(plan.resolveSession(emptyList(), "ws_b", settled = true))
        assertFalse("a workspace with no chats yet is not an answer", plan.isDecided)
        assertEquals("sess_c", plan.resolveSession(chats(CHATS), "ws_b", settled = true))
        assertTrue(plan.isDecided)
    }

    @Test
    fun `an answer of nothing is still an answer`() {
        // The case the gate exists for on a first launch: there is no chat to open, so the shell is the launch.
        val noSavedChat = plan(session = null)
        assertNull(noSavedChat.resolveSession(chats(CHATS), "ws_b", settled = true))
        assertTrue(noSavedChat.isDecided)

        val deleted = plan(session = "sess_deleted")
        assertNull(deleted.resolveSession(chats(CHATS), "ws_b", settled = true))
        assertTrue(deleted.isDecided)
    }

    @Test
    fun `an answer stays an answer`() {
        val plan = plan(session = "sess_c")
        plan.resolveSession(chats(CHATS), "ws_b", settled = true)
        assertTrue(plan.isDecided)

        // Every later reading is noise: a refresh, a trip through the inspector, a recomposition.
        plan.resolveSession(chats(CHATS), "ws_b", settled = false)
        plan.resolveSession(emptyList(), "ws_b", settled = true)
        assertTrue(plan.isDecided)
    }

    private fun plan(session: String?) = ResumePlan(
        LastPosition(workspaceId = "ws_b", sessionId = session),
    )

    private fun chats(ids: List<String>) = ids.mapIndexed { index, id ->
        ChatSummary(
            id = id,
            workspaceId = "ws_b",
            title = "Chat $id",
            updatedAtEpochMillis = 1_000L + index,
        )
    }

    private companion object {
        val CHATS = listOf("sess_a", "sess_c", "sess_b")
    }
}
