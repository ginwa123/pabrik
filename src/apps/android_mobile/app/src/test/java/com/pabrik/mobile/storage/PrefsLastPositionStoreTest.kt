package com.pabrik.mobile.storage

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** [PrefsLastPositionStore] against a real `SharedPreferences` file. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PrefsLastPositionStoreTest {

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        store().clear()
    }

    @Test
    fun `an unused store reports no position`() {
        assertTrue(store().read("user_a").isEmpty)
    }

    @Test
    fun `a saved position is read back whole`() {
        store().save("user_a", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertEquals(
            LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            store().read("user_a"),
        )
    }

    @Test
    fun `a position written by one account is invisible to another`() {
        store().save("user_a", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertTrue(store().read("user_b").isEmpty)
        assertTrue(store().read(null).isEmpty)
    }

    @Test
    fun `an account writing a position does not disturb another's`() {
        store().save("user_a", LastPosition(workspaceId = "ws_a", sessionId = "sess_a"))
        store().save("user_b", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertEquals("ws_a", store().read("user_a").workspaceId)
        assertEquals("sess_a", store().read("user_a").sessionId)
        assertEquals("ws_b", store().read("user_b").workspaceId)
        assertEquals("sess_c", store().read("user_b").sessionId)
    }

    @Test
    fun `a server without auth still gets a position`() {
        // `AuthResult.AuthDisabled` leaves `AuthUiState.userId` null, and
        // refusing to persist for that case would switch this feature off for
        // every self-hosted install. One well-known namespace, cleared on
        // sign-out like any other.
        store().save(null, LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertEquals("sess_c", store().read(null).sessionId)
        // A blank id is the same case, not a third namespace.
        assertEquals("sess_c", store().read("").sessionId)
    }

    @Test
    fun `switching workspace drops the chat from the old one`() {
        store().save("user_a", LastPosition(workspaceId = "ws_a", sessionId = "sess_a"))
        store().saveWorkspace("user_a", "ws_b")

        val position = store().read("user_a")
        assertEquals("ws_b", position.workspaceId)
        assertNull(
            "the chat belonged to the workspace the user just left, so resuming " +
                "it would open a chat that is not in the resumed workspace",
            position.sessionId,
        )
    }

    @Test
    fun `a blank workspace is not written`() {
        store().save("user_a", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))
        store().saveWorkspace("user_a", "   ")

        assertEquals("ws_b", store().read("user_a").workspaceId)
        assertEquals("sess_c", store().read("user_a").sessionId)
    }

    @Test
    fun `a blank chat is not written`() {
        store().save("user_a", LastPosition(workspaceId = "ws_b"))
        store().save("user_a", LastPosition(sessionId = ""))

        val position = store().read("user_a")
        assertEquals("ws_b", position.workspaceId)
        assertNull(position.sessionId)
    }

    @Test
    fun `a null field in a save leaves the other half alone`() {
        // The shape the resume itself uses: it knows the session, and the
        // workspace is whatever the drawer is already on.
        store().save("user_a", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))
        store().save("user_a", LastPosition(sessionId = "sess_d"))

        val position = store().read("user_a")
        assertEquals("ws_b", position.workspaceId)
        assertEquals("sess_d", position.sessionId)
    }

    @Test
    fun `sign-out takes every account's position with it`() {
        store().save("user_a", LastPosition(workspaceId = "ws_a", sessionId = "sess_a"))
        store().save("user_b", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))
        store().save(null, LastPosition(workspaceId = "ws_z"))

        store().clear()

        assertTrue(store().read("user_a").isEmpty)
        assertTrue(store().read("user_b").isEmpty)
        assertTrue(store().read(null).isEmpty)
    }

    @Test
    fun `a new store instance sees what the previous one wrote`() {
        // What "outlives the process" has to mean in practice: a relaunch builds a fresh store over the same file, and the position is still there.
        store().save("user_a", LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        assertEquals(
            LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            PrefsLastPositionStore(context).read("user_a"),
        )
    }

    private fun store() = PrefsLastPositionStore(context)
}
