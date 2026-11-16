package com.pabrik.mobile.functional

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.pabrik.mobile.auth.RoomAuthMeCache
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.chat.RoomChatCache
import com.pabrik.mobile.projects.RoomProjectsCache
import com.pabrik.mobile.recents.RoomRecentsCache
import com.pabrik.mobile.storage.PrefsLastPositionStore
import org.junit.rules.ExternalResource

/** Puts the app back to "installed and never used" around each test. */
class ClearAppStateRule(
    private val context: Context =
        InstrumentationRegistry.getInstrumentation().targetContext,
) : ExternalResource() {

    override fun before() = clearNow()

    override fun after() = clearNow()

    /** Clears every kind of state that outlives a test in this process. */
    fun clearNow() {
        // Nothing is signed in here — the harness runs pabrik with auth off — but a cookie left by an earlier test would be sent to the harness on every request, and the …
        SessionCookieStore(context).clear()

        // The resumer.
        PrefsLastPositionStore(context).clear()

        // The four caches that can paint before the network answers.
        RoomChatCache(context).clear()
        RoomRecentsCache(context).clear()
        RoomAuthMeCache(context).clear()
        RoomProjectsCache(context).clear()
    }
}
