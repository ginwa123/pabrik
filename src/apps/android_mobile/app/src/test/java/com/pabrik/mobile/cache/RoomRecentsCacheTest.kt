package com.pabrik.mobile.cache

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.RoomRecentsCache
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.SealingCipher
import com.pabrik.mobile.testing.Base64CacheCipher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The sidebar cache against a **real** SQLite database. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomRecentsCacheTest {

    private lateinit var database: PabrikCacheDatabase
    private lateinit var cache: RoomRecentsCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            PabrikCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomRecentsCache(database.recentsCacheDao(), Base64CacheCipher)
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun workspace(id: String, name: String) = WorkspaceOption(id = id, name = name)

    private fun chat(id: String, workspaceId: String, title: String, updatedAt: Long = 1_000L) =
        ChatSummary(id = id, workspaceId = workspaceId, title = title, updatedAtEpochMillis = updatedAt)

    // --- Order --------------------------------------------------------------

    @Test
    fun theServerOrderIsKeptNotAnAlphabeticalOne() {
        // The endpoint returns recents in the order it wants them drawn.
        cache.writeWorkspaces(
            USER,
            listOf(workspace("ws_c", "Charlie"), workspace("ws_a", "Alpha"), workspace("ws_b", "Bravo")),
        )

        assertEquals(
            listOf("ws_c", "ws_a", "ws_b"),
            cache.readWorkspaces(USER)?.map { it.id },
        )
    }

    @Test
    fun chatsComeBackInTheOrderTheyWereWritten() {
        cache.writeChats(
            USER,
            WORKSPACE,
            listOf(
                chat("task_c", WORKSPACE, "Charlie"),
                chat("task_a", WORKSPACE, "Alpha"),
                chat("task_b", WORKSPACE, "Bravo", updatedAt = 9_000L),
            ),
        )

        // The newest row is first, and it is *not* the alphabetically first one.
        assertEquals(
            listOf("task_c", "task_a", "task_b"),
            cache.readChats(USER, WORKSPACE)?.map { it.id },
        )
    }

    @Test
    fun bothTimestampsSurviveTheRoundTrip() {
        // A recents row carries two clocks — the order key (`updated_at`) and the label key (`last_human_touched_at`) — and for a session the agent is working on they …
        cache.writeChats(
            USER,
            WORKSPACE,
            listOf(
                ChatSummary(
                    id = "task_running",
                    workspaceId = WORKSPACE,
                    title = "Agent is working",
                    updatedAtEpochMillis = 9_000L,
                    lastHumanTouchedAtEpochMillis = 100L,
                ),
            ),
        )

        val row = cache.readChats(USER, WORKSPACE)?.single()

        assertEquals(9_000L, row?.updatedAtEpochMillis)
        assertEquals(100L, row?.lastHumanTouchedAtEpochMillis)
    }

    @Test
    fun aRewriteReplacesTheOrderRatherThanAppendingToIt() {
        cache.writeChats(
            USER,
            WORKSPACE,
            listOf(chat("task_a", WORKSPACE, "A"), chat("task_b", WORKSPACE, "B")),
        )
        cache.writeChats(USER, WORKSPACE, listOf(chat("task_z", WORKSPACE, "Z")))

        assertEquals(listOf("task_z"), cache.readChats(USER, WORKSPACE)?.map { it.id })
    }

    // --- Replace-not-merge --------------------------------------------------

    @Test
    fun aRefreshReplacesThePartitionSoADeletedChatStaysDeleted() {
        cache.writeChats(
            USER,
            WORKSPACE,
            listOf(chat("stale", WORKSPACE, "Stale"), chat("kept", WORKSPACE, "Kept")),
        )

        // The user deleted `stale` elsewhere.
        cache.writeChats(USER, WORKSPACE, listOf(chat("kept", WORKSPACE, "Kept")))

        assertEquals(listOf("kept"), cache.readChats(USER, WORKSPACE)?.map { it.id })
    }

    @Test
    fun aWorkspaceListIsReplacedTooNotMerged() {
        cache.writeWorkspaces(USER, listOf(workspace("ws_1", "One"), workspace("ws_2", "Two")))
        cache.writeWorkspaces(USER, listOf(workspace("ws_2", "Two")))

        assertEquals(listOf("ws_2"), cache.readWorkspaces(USER)?.map { it.id })
    }

    @Test
    fun anEmptyListIsARealAnswerNotAMiss() {
        // A genuinely empty account has to be distinguishable from one that has never been fetched, because the sidebar paints one and the spinner the other.
        cache.writeWorkspaces(USER, emptyList())
        cache.writeChats(USER, WORKSPACE, emptyList())

        // Both read as a miss here, and both are answered identically by `HomeViewModel` — which goes and fetches.
        assertNull(cache.readWorkspaces(USER))
        assertNull(cache.readChats(USER, WORKSPACE))
    }

    // --- Isolation ----------------------------------------------------------

    @Test
    fun anUnresolvedIdentityIsAMissRatherThanAnUnscopedRead() {
        cache.writeWorkspaces(USER, listOf(workspace("ws_1", "A's workspace")))

        assertNull(cache.readWorkspaces(null))
        assertNull(cache.readWorkspaces("   "))
        assertNull(cache.readChats(null, WORKSPACE))
        assertNull(cache.readChats(USER, "   "))
    }

    @Test
    fun anUnresolvedIdentityCannotWriteEither() {
        cache.writeWorkspaces(null, listOf(workspace("ws_1", "Nobody's")))
        cache.writeChats("   ", WORKSPACE, listOf(chat("task_1", WORKSPACE, "Nobody's")))

        assertNull(cache.readWorkspaces(USER))
        assertNull(cache.readChats(USER, WORKSPACE))
    }

    @Test
    fun twoAccountsOnOneDeviceNeverSeeEachOthersSidebar() {
        cache.writeWorkspaces("user_a", listOf(workspace("ws_a", "A's workspace")))
        cache.writeWorkspaces("user_b", listOf(workspace("ws_b", "B's workspace")))

        assertEquals("A's workspace", cache.readWorkspaces("user_a")?.single()?.name)
        assertEquals("B's workspace", cache.readWorkspaces("user_b")?.single()?.name)
    }

    @Test
    fun aUserIdThatLooksLikeSomebodyElsesKeyCannotEscapeItsPartition() {
        // The old store built `chats::u:<userId>::w:<workspaceId>` by hand, so a user id containing the separator could address another partition.
        val hostile = "user_a::u:user_b"
        cache.writeChats(hostile, WORKSPACE, listOf(chat("task_evil", WORKSPACE, "Evil")))
        cache.writeChats("user_a", WORKSPACE, listOf(chat("task_real", WORKSPACE, "Real")))

        assertEquals(listOf("task_real"), cache.readChats("user_a", WORKSPACE)?.map { it.id })
        assertEquals(listOf("task_evil"), cache.readChats(hostile, WORKSPACE)?.map { it.id })
    }

    @Test
    fun chatsArePartitionedPerWorkspaceSoOneWorkspaceCannotPaintUnderAnother() {
        cache.writeChats(USER, "ws_1", listOf(chat("task_1", "ws_1", "One's chat")))
        cache.writeChats(USER, "ws_2", listOf(chat("task_2", "ws_2", "Two's chat")))

        assertEquals("One's chat", cache.readChats(USER, "ws_1")?.single()?.title)
        assertEquals("Two's chat", cache.readChats(USER, "ws_2")?.single()?.title)
    }

    // --- Sealing ------------------------------------------------------------

    @Test
    fun aTitleIsNotSittingInTheDatabaseInTheClear() {
        cache.writeChats(USER, WORKSPACE, listOf(chat("task_1", WORKSPACE, "Q3 board restructuring")))

        val column = database.openHelper.readableDatabase.query(
            "SELECT title_sealed FROM cached_chat_summaries WHERE chat_id = ?",
            arrayOf("task_1"),
        ).use { cursor ->
            cursor.moveToFirst()
            cursor.getString(0)
        }

        // The Keystore cipher in production produces something no reader can guess; this asserts the weaker but load-bearing property — the value went through the cipher …
        assertFalse(column, column.contains("Q3 board restructuring"))
        assertEquals("Q3 board restructuring", Base64CacheCipher.open(column))
    }

    @Test
    fun aWorkspaceNameIsNotSittingInTheDatabaseInTheClear() {
        cache.writeWorkspaces(USER, listOf(workspace("ws_1", "Ginwa Consulting")))

        val column = database.openHelper.readableDatabase.query(
            "SELECT name_sealed FROM cached_workspaces WHERE workspace_id = ?",
            arrayOf("ws_1"),
        ).use { cursor ->
            cursor.moveToFirst()
            cursor.getString(0)
        }

        assertFalse(column, column.contains("Ginwa Consulting"))
    }

    @Test
    fun aWholeListThatCannotBeSealedIsNotWrittenAtAll() {
        cache.writeChats(USER, WORKSPACE, listOf(chat("task_1", WORKSPACE, "Readable")))

        val failing = RoomRecentsCache(
            database.recentsCacheDao(),
            object : SealingCipher {
                override fun seal(plainText: String): String? =
                    if (plainText == "Unsealable") null else "sealed:$plainText"

                override fun open(sealed: String): String? = sealed.removePrefix("sealed:")
            },
        )
        failing.writeChats(
            USER,
            WORKSPACE,
            listOf(chat("task_2", WORKSPACE, "Unsealable"), chat("task_3", WORKSPACE, "Fine")),
        )

        // Half a list is worse than none: a drawer showing two of the three chats would be painting a partial truth that nothing corrects until the user notices.
        assertEquals(listOf("task_1"), cache.readChats(USER, WORKSPACE)?.map { it.id })
    }

    @Test
    fun anUnopenableRowMakesTheWholeReadAMissAndDropsThePartition() {
        cache.writeChats(USER, WORKSPACE, listOf(chat("task_1", WORKSPACE, "Readable")))

        // Simulates a row written under a retired Keystore alias: the row is there, and it cannot be read.
        database.openHelper.writableDatabase.execSQL(
            "UPDATE cached_chat_summaries SET title_sealed = ? WHERE chat_id = ?",
            arrayOf<Any>("corrupt:not-a-sealed-value", "task_1"),
        )

        assertNull(cache.readChats(USER, WORKSPACE))
        assertNull(cache.readChats(USER, WORKSPACE))
    }

    // --- Sign-out -----------------------------------------------------------

    @Test
    fun clearPurgesEveryUserAndEveryWorkspace() {
        cache.writeWorkspaces(USER, listOf(workspace("ws_1", "A")))
        cache.writeWorkspaces("user_b", listOf(workspace("ws_2", "B")))
        cache.writeChats(USER, "ws_1", listOf(chat("task_1", "ws_1", "A's chat")))
        cache.writeChats("user_b", "ws_2", listOf(chat("task_2", "ws_2", "B's chat")))

        cache.clear()

        // Sign-out only clears the cookie, so a row left behind here would be painted for whoever signs in next on a shared device.
        assertNull(cache.readWorkspaces(USER))
        assertNull(cache.readWorkspaces("user_b"))
        assertNull(cache.readChats(USER, "ws_1"))
        assertNull(cache.readChats("user_b", "ws_2"))
    }

    @Test
    fun clearLeavesTheDatabaseUsableForTheNextAccount() {
        cache.writeWorkspaces(USER, listOf(workspace("ws_1", "A")))
        cache.clear()
        cache.writeWorkspaces("user_b", listOf(workspace("ws_2", "B's workspace")))

        assertTrue(cache.readWorkspaces("user_b")?.single()?.name == "B's workspace")
    }

    private companion object {
        const val USER = "user_a"
        const val WORKSPACE = "ws_1"
    }
}
