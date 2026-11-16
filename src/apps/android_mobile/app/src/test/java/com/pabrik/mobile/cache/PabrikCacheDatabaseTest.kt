package com.pabrik.mobile.cache

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.pabrik.mobile.recents.RoomRecentsCache
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.testing.Base64CacheCipher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The database *builder*, as opposed to the caches on top of it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PabrikCacheDatabaseTest {

    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun allThreeCachesShareOneConnection() {
        val database = PabrikCacheDatabase.get(context)

        assertNotNull(database.chatCacheDao())
        assertNotNull(database.recentsCacheDao())
        assertNotNull(database.authMeCacheDao())
        // The point of a single database: the two ViewModels that write caches and the auth flow that writes the third are not racing two file handles at the same WAL.
        assertSame(database, PabrikCacheDatabase.get(context))
    }

    /** The singleton is process-wide, so one test's rows would otherwise be visible to the next. */
    @After
    fun tearDown() {
        PabrikCacheDatabase.get(context).openHelper.writableDatabase.apply {
            execSQL("DELETE FROM cached_workspaces")
            execSQL("DELETE FROM cached_chat_summaries")
            execSQL("DELETE FROM cached_messages")
            execSQL("DELETE FROM chat_cursors")
            execSQL("DELETE FROM chat_older_pages")
            execSQL("DELETE FROM cached_auth_me")
        }
    }

    @Test
    fun theFileDatabaseReallyIsAFileAndNotAnInMemoryStandIn() {
        // The production builder is what the caches in the other three test classes deliberately do not exercise, so at least one of them has to open the real thing — …
        val tables = mutableListOf<String>()
        PabrikCacheDatabase.get(context)
            .openHelper.readableDatabase
            .query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cached_%'")
            .use { cursor ->
                while (cursor.moveToNext()) tables += cursor.getString(0)
            }

        assertEquals(
            // `chat_cursors` is absent by design: it does not match the `cached_%` filter, and this test is about the *cached* tables specifically.
            listOf(
                "cached_auth_me",
                "cached_chat_summaries",
                "cached_messages",
                "cached_project_chats",
                "cached_projects",
                "cached_workspaces",
            ),
            tables.sorted(),
        )
    }

    @Test
    fun aWriteThroughOneCacheIsReadableThroughTheSharedFile() {
        // A round trip that only makes sense when it is one file: the sidebar and the transcript are written by different ViewModels, and a sign-out has to be able to …
        val database = PabrikCacheDatabase.get(context)
        RoomRecentsCache(database.recentsCacheDao(), Base64CacheCipher)
            .writeWorkspaces("user_a", listOf(WorkspaceOption("ws_1", "One")))

        val rows = database.openHelper.readableDatabase
            .query("SELECT workspace_id FROM cached_workspaces")
            .use { cursor ->
                buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
            }

        assertEquals(listOf("ws_1"), rows)
    }
}
