package com.pabrik.mobile.cache

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.pabrik.mobile.chat.CachedChatMessage
import com.pabrik.mobile.chat.ChatCacheCodec
import com.pabrik.mobile.chat.ChatOlderPage
import com.pabrik.mobile.chat.RoomChatCache
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The transcript cache against a **real** SQLite database. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomChatCacheTest {

    private lateinit var database: PabrikCacheDatabase
    private lateinit var cache: RoomChatCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            PabrikCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomChatCache(database.chatCacheDao())
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun message(
        id: String,
        nanos: Long,
        raw: JSONObject? = null,
    ): CachedChatMessage {
        val row = raw ?: JSONObject()
            .put("id", id)
            .put("role", "user")
            .put("content", "hi $id")
            .put("created_at", nanos.toString())
        return CachedChatMessage(
            id = id,
            sortKeyNanos = nanos,
            sessionId = SESSION,
            role = row.optString("role"),
            content = row.optString("content"),
            raw = row.toString(),
        )
    }

    private fun ids(messages: List<CachedChatMessage>?) = messages?.map { it.id }

    // --- Per-user and per-session isolation ---------------------------------

    @Test
    fun anUnresolvedIdentityIsAMissRatherThanAnUnscopedRead() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100)))

        // Stricter than the web's `userScopedKey`, which falls back to an UNSCOPED key when identity is unresolved.
        assertNull(cache.readMessages(null, SESSION, 10))
        assertNull(cache.readMessages("   ", SESSION, 10))
        assertNull(cache.readMessages(USER, "   ", 10))
        assertNull(cache.readCursor(null, SESSION))
    }

    @Test
    fun aBlankIdentityCannotWriteEither() {
        cache.writeMessages(null, SESSION, listOf(message("m1", 100)))
        cache.writeMessages("   ", SESSION, listOf(message("m2", 200)))
        cache.writeMessages(USER, "", listOf(message("m3", 300)))

        assertNull(cache.readMessages(USER, SESSION, 10))
    }

    @Test
    fun twoAccountsOnOneDeviceNeverSeeEachOthersTranscript() {
        cache.writeMessages("user_a", SESSION, listOf(message("a1", 100)))
        cache.writeMessages("user_b", SESSION, listOf(message("b1", 100)))

        assertEquals(listOf("a1"), ids(cache.readMessages("user_a", SESSION, 10)))
        assertEquals(listOf("b1"), ids(cache.readMessages("user_b", SESSION, 10)))
    }

    @Test
    fun twoSessionsInOneAccountNeverSeeEachOther() {
        cache.writeMessages(USER, "sess_1", listOf(message("one", 100)))
        cache.writeMessages(USER, "sess_2", listOf(message("two", 100)))

        assertEquals(listOf("one"), ids(cache.readMessages(USER, "sess_1", 10)))
        assertEquals(listOf("two"), ids(cache.readMessages(USER, "sess_2", 10)))
    }

    // --- Ordering and limiting ----------------------------------------------

    @Test
    fun readsComeBackNewestFirstAndCapped() {
        cache.writeMessages(
            USER,
            SESSION,
            (1L..5L).map { message("m$it", it * 100) },
        )

        // Newest first, and the cap takes the newest — the two halves of the IndexedDB `getAll` contract the paint-from-cache path depends on.
        assertEquals(listOf("m5", "m4", "m3"), ids(cache.readMessages(USER, SESSION, 3)))
        assertEquals(listOf("m5", "m4", "m3", "m2", "m1"), ids(cache.readMessages(USER, SESSION, 50)))
    }

    @Test
    fun rowsSharingATimestampBreakTiesByIdSoThePaintIsDeterministic() {
        // The backend stamps by whole seconds often enough that ties are the normal case, not the exotic one.
        cache.writeMessages(USER, SESSION, listOf(message("b", 100), message("a", 100)))

        assertEquals(listOf("b", "a"), ids(cache.readMessages(USER, SESSION, 10)))
    }

    @Test
    fun aLimitOfZeroStillReturnsSomethingUsable() {
        // The old cache did `.take(limit.coerceAtLeast(1))`.
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100), message("m2", 200)))

        assertEquals(listOf("m2"), ids(cache.readMessages(USER, SESSION, 0)))
    }

    // --- Write-through merge ------------------------------------------------

    @Test
    fun aSameIdWriteReplacesTheRowInsteadOfDuplicatingIt() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100), message("m2", 200)))

        val revised = message(
            "m1",
            100,
            raw = JSONObject().put("id", "m1").put("content", "revised").put("created_at", "100"),
        )
        cache.writeMessages(USER, SESSION, listOf(revised))

        val stored = cache.readMessages(USER, SESSION, 10)!!
        assertEquals(2, stored.size)
        assertEquals("revised", JSONObject(stored.single { it.id == "m1" }.raw).getString("content"))
    }

    @Test
    fun writingNothingLeavesTheCacheAlone() {
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100)))

        // "The page came back empty" is a normal tail-fetch answer.
        cache.writeMessages(USER, SESSION, emptyList())

        assertEquals(listOf("m1"), ids(cache.readMessages(USER, SESSION, 10)))
    }

    @Test
    fun aRowKeepsTheWholeServerObjectNotAProjection() {
        // A field this client has never heard of must survive the round trip, or the cached paint and the live paint disagree about a transcript.
        val wire = JSONObject()
            .put("id", "m1")
            .put("content", "hi")
            .put("created_at", "100")
            .put("tool_calls_json", """{"name":"command"}""")
            .put("is_output", true)
        cache.writeMessages(USER, SESSION, listOf(message("m1", 100, raw = wire)))

        val roundTripped = JSONObject(cache.readMessages(USER, SESSION, 10)!!.single().raw)
        assertEquals("""{"name":"command"}""", roundTripped.getString("tool_calls_json"))
        assertTrue(roundTripped.getBoolean("is_output"))
    }

    @Test
    fun aRowBuiltByTheCodecRoundTripsThroughTheDatabase() {
        // The end-to-end shape: wire object → codec → storage → read → codec.
        val row = JSONObject().put("id", "m1").put("created_at", "1789451234567890123")
        val built = ChatCacheCodec.toCachedMessage(SESSION, row)!!

        cache.writeMessages(USER, SESSION, listOf(built))
        val read = cache.readMessages(USER, SESSION, 10)!!.single()

        assertEquals(built, read)
    }

    @Test
    fun aRowIsStoredInThePartitionItWasWrittenIntoNotTheOneItClaims() {
        // `CachedChatMessage` carries its own `sessionId`, and the two agree in every current call site.
        val mislabelled = message("m1", 100).copy(sessionId = "some_other_session")

        cache.writeMessages(USER, SESSION, listOf(mislabelled))

        assertEquals(listOf("m1"), ids(cache.readMessages(USER, SESSION, 10)))
        assertNull(cache.readMessages(USER, "some_other_session", 10))
    }

    // --- Retention ----------------------------------------------------------

    @Test
    fun aSessionStopsGrowingPastTheRetentionCeiling() {
        val small = RoomChatCache(database.chatCacheDao(), retainedRowsPerSession = 3)
        small.writeMessages(
            USER,
            SESSION,
            (1L..5L).map { message("m$it", it * 100) },
        )

        // A row store is append-only by nature, and the file cache it replaced was rewritten whole on every write.
        assertEquals(listOf("m5", "m4", "m3"), ids(small.readMessages(USER, SESSION, 50)))
    }

    @Test
    fun retentionIsPerSessionSoASmallOneIsNotStarvedByABigOne() {
        val small = RoomChatCache(database.chatCacheDao(), retainedRowsPerSession = 1)
        small.writeMessages(USER, "sess_1", (1L..4L).map { message("a$it", it * 100) })
        small.writeMessages(USER, "sess_2", listOf(message("b1", 100)))

        assertEquals(listOf("a4"), ids(small.readMessages(USER, "sess_1", 10)))
        assertEquals(listOf("b1"), ids(small.readMessages(USER, "sess_2", 10)))
    }

    // --- The cursor ---------------------------------------------------------

    @Test
    fun theCursorIsStoredPerUserAndPerSession() {
        cache.writeCursor(USER, SESSION, "500")
        cache.writeCursor(USER, "sess_2", "600")
        cache.writeCursor("user_b", SESSION, "700")

        assertEquals("500", cache.readCursor(USER, SESSION))
        assertEquals("600", cache.readCursor(USER, "sess_2"))
        assertEquals("700", cache.readCursor("user_b", SESSION))
    }

    @Test
    fun aBlankCursorClearsTheStoredOne() {
        cache.writeCursor(USER, SESSION, "500")

        // "There is no cursor any more" is a real state — it is what makes the next open a full descending load instead of a tail fetch — so it has to be expressible as …
        cache.writeCursor(USER, SESSION, null)
        assertNull(cache.readCursor(USER, SESSION))

        cache.writeCursor(USER, SESSION, "900")
        cache.writeCursor(USER, SESSION, "   ")
        assertNull(cache.readCursor(USER, SESSION))
    }

    @Test
    fun aStoredCursorIsReplacedRatherThanDuplicated() {
        repeat(3) { cache.writeCursor(USER, SESSION, "$it") }

        assertEquals("2", cache.readCursor(USER, SESSION))
    }

    // --- The older page -----------------------------------------------------

    @Test
    fun theOlderPageKeepsBothTheCursorAndTheVerdict() {
        // Half of it is not enough.
        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = true))
        assertEquals(
            ChatOlderPage(cursor = "500", hasMore = true),
            cache.readOlderPage(USER, SESSION),
        )

        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = false))
        assertEquals(
            ChatOlderPage(cursor = "500", hasMore = false),
            cache.readOlderPage(USER, SESSION),
        )
    }

    @Test
    fun theOlderPageIsStoredPerUserAndPerSession() {
        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = true))
        cache.writeOlderPage(USER, "sess_2", ChatOlderPage(cursor = "600", hasMore = true))
        cache.writeOlderPage("user_b", SESSION, ChatOlderPage(cursor = "700", hasMore = true))

        assertEquals("500", cache.readOlderPage(USER, SESSION)?.cursor)
        assertEquals("600", cache.readOlderPage(USER, "sess_2")?.cursor)
        assertEquals("700", cache.readOlderPage("user_b", SESSION)?.cursor)
    }

    @Test
    fun aNullOlderPageDropsTheStoredOne() {
        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = true))

        // Reaching the start of a transcript is a fact worth keeping, and the only way to keep it is to overwrite rather than leave stale.
        cache.writeOlderPage(USER, SESSION, null)

        assertNull(cache.readOlderPage(USER, SESSION))
    }

    @Test
    fun aBlankIdentityCannotReachAnOlderPage() {
        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = true))

        assertNull(cache.readOlderPage(null, SESSION))
        assertNull(cache.readOlderPage("  ", SESSION))
        assertNull(cache.readOlderPage(USER, ""))
    }

    @Test
    fun aStoredOlderPageIsReplacedRatherThanDuplicated() {
        repeat(3) { cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "$it", hasMore = true)) }

        assertEquals("2", cache.readOlderPage(USER, SESSION)?.cursor)
    }

    // --- Sign-out -----------------------------------------------------------

    @Test
    fun clearPurgesEveryUserAndEverySession() {
        cache.writeMessages(USER, SESSION, listOf(message("a1", 100)))
        cache.writeMessages("user_b", "sess_2", listOf(message("b1", 100)))
        cache.writeCursor(USER, SESSION, "500")
        cache.writeCursor("user_b", "sess_2", "500")
        cache.writeOlderPage(USER, SESSION, ChatOlderPage(cursor = "500", hasMore = true))
        cache.writeOlderPage("user_b", "sess_2", ChatOlderPage(cursor = "500", hasMore = true))

        cache.clear()

        // Sign-out only clears the cookie, so anything left behind here would be painted for whoever signs in next on a shared device.
        assertNull(cache.readMessages(USER, SESSION, 10))
        assertNull(cache.readMessages("user_b", "sess_2", 10))
        assertNull(cache.readCursor(USER, SESSION))
        assertNull(cache.readCursor("user_b", "sess_2"))
        assertNull(cache.readOlderPage(USER, SESSION))
        assertNull(cache.readOlderPage("user_b", "sess_2"))
    }

    @Test
    fun aFirstReadOnAnEmptyDatabaseIsAMissNotAFailure() {
        assertNull(cache.readMessages(USER, SESSION, 10))
        assertNull(cache.readCursor(USER, SESSION))
        assertNull(cache.readOlderPage(USER, SESSION))
    }

    private companion object {
        const val USER = "user_a"
        const val SESSION = "sess_1"
    }
}
