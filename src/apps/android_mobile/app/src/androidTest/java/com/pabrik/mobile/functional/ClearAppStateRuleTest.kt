package com.pabrik.mobile.functional

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pabrik.mobile.auth.RoomAuthMeCache
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.CachedChatMessage
import com.pabrik.mobile.chat.RoomChatCache
import com.pabrik.mobile.projects.ProjectSummary
import com.pabrik.mobile.projects.RoomProjectsCache
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.RoomRecentsCache
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.PrefsLastPositionStore
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith

/** What [ClearAppStateRule] removes, and that it removes it *before* the test. */
@RunWith(AndroidJUnit4::class)
class ClearAppStateRuleTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private val clear = ClearAppStateRule(context)

    /** Dirty the app, then clear it — the order every real test runs in. */
    @get:Rule
    val chain: TestRule = RuleChain.outerRule(DirtyTheApp()).around(clear)

    // ─── the ordering contract ─────────────────────────────────────────────

    @Test
    fun aRuleInstalledOnATestClearsWhatRanBeforeIt() {
        // `DirtyTheApp` wrote both of these in its own `before()`, which the RuleChain runs before the clear.
        assertNull(SessionCookieStore(context).read())
        assertTrue(PrefsLastPositionStore(context).read(USER).isEmpty)
    }

    // ─── each kind of state, one at a time ─────────────────────────────────

    @Test
    fun itDropsALeftoverSessionCookie() {
        SessionCookieStore(context).save(COOKIE)

        clear.clearNow()

        assertNull(SessionCookieStore(context).read())
    }

    @Test
    fun itDropsThePositionTheAppWouldResumeTo() {
        PrefsLastPositionStore(context).save(USER, LastPosition(sessionId = "sess_left_over"))

        clear.clearNow()

        assertTrue(PrefsLastPositionStore(context).read(USER).isEmpty)
    }

    @Test
    fun itDropsCachedTranscriptRows() {
        val chat = RoomChatCache(context)
        chat.writeMessages(USER, SESSION, listOf(cachedMessage()))

        clear.clearNow()

        assertNull(chat.readMessages(USER, SESSION, limit = 100))
    }

    @Test
    fun itDropsTheCachedSidebarPartition() {
        val recents = RoomRecentsCache(context)
        recents.writeChats(USER, WORKSPACE, listOf(chatSummary()))

        clear.clearNow()

        assertNull(recents.readChats(USER, WORKSPACE))
    }

    @Test
    fun itDropsTheCachedAccountLookup() {
        val me = RoomAuthMeCache(context)
        me.write(FINGERPRINT, """{"authenticated":false,"auth_enabled":false}""", 1_000L)

        clear.clearNow()

        assertNull(me.read(FINGERPRINT))
    }

    @Test
    fun itDropsTheCachedProjectsPartition() {
        val projects = RoomProjectsCache(context)
        projects.writeProjects(USER, WORKSPACE, listOf(projectSummary()))

        clear.clearNow()

        assertNull(projects.readProjects(USER, WORKSPACE))
    }

    // ─── fixtures ──────────────────────────────────────────────────────────

    private fun cachedMessage() = CachedChatMessage(
        id = "msg_left_over",
        sortKeyNanos = 1L,
        sessionId = SESSION,
        role = "user",
        content = "left over from another test",
        raw = """{"id":"msg_left_over","role":"user","content":"left over from another test"}""",
    )

    private fun chatSummary() = ChatSummary(
        id = SESSION,
        workspaceId = WORKSPACE,
        title = "Left over",
        updatedAtEpochMillis = 1L,
    )

    private fun projectSummary() = ProjectSummary(
        id = "proj_left_over",
        workspaceId = WORKSPACE,
        itemType = "project",
        name = "Left over",
    )

    /** Writes state a previous test would have left behind, before the clear runs. */
    private inner class DirtyTheApp : ExternalResource() {
        override fun before() {
            SessionCookieStore(context).save(COOKIE)
            PrefsLastPositionStore(context).save(
                USER,
                LastPosition(sessionId = "sess_left_over"),
            )
        }
    }

    private companion object {
        const val USER = "user_clear_app_state"
        const val SESSION = "sess_clear_app_state"
        const val WORKSPACE = "ws_clear_app_state"
        const val COOKIE = "cookie-left-over-from-an-earlier-test"
        const val FINGERPRINT = "fingerprint-left-over"
    }
}
