package com.pabrik.mobile.chat

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two rules the cache still owns in Kotlin: the `raw` envelope, and the cursor rule. */
class ChatCacheCodecTest {

    private fun row(
        id: String,
        nanos: Long = 1_000L,
        role: String = ChatMessage.ROLE_USER,
        content: String = "hello",
    ): JSONObject = JSONObject()
        .put("id", id)
        .put("session_id", "sess_1")
        .put("role", role)
        .put("content", content)
        .put("created_at", nanos.toString())

    private fun rowWithExtras(id: String, nanos: Long = 1_000L): JSONObject =
        row(id, nanos)
            .put("tool_calls_json", """{"name":"command"}""")
            .put("diffview_before", "a")
            .put("is_output", true)

    private fun cached(id: String, nanos: Long = 1_000L) = CachedChatMessage(
        id = id,
        sortKeyNanos = nanos,
        sessionId = "sess_1",
        role = ChatMessage.ROLE_USER,
        content = "hello",
        raw = row(id, nanos).toString(),
    )

    // --- The raw envelope --------------------------------------------------

    @Test
    fun `a cached row keeps the whole server object, not a projection`() {
        val original = rowWithExtras("m1")

        val cachedRow = ChatCacheCodec.toCachedMessage("sess_1", original)!!
        val roundTripped = JSONObject(cachedRow.raw)

        assertEquals("""{"name":"command"}""", roundTripped.getString("tool_calls_json"))
        assertEquals("a", roundTripped.getString("diffview_before"))
        assertTrue(roundTripped.getBoolean("is_output"))
    }

    @Test
    fun `a row without an id cannot be cached`() {
        // The id is the primary key.
        assertNull(ChatCacheCodec.toCachedMessage("sess_1", JSONObject().put("content", "x")))
    }

    @Test
    fun `the hoisted sort key comes from created_at, in both of its wire shapes`() {
        assertEquals(
            1_789_451_234_567_890_123L,
            ChatCacheCodec.toCachedMessage("s", row("m", 1_789_451_234_567_890_123L))!!.sortKeyNanos,
        )
        assertEquals(
            ChatApi.parseCreatedAtNanos("2026-09-26 05:07:34"),
            ChatCacheCodec.toCachedMessage(
                "s",
                JSONObject().put("id", "m").put("created_at", "2026-09-26 05:07:34"),
            )!!.sortKeyNanos,
        )
    }

    // --- The cursor rule ---------------------------------------------------

    @Test
    fun `the cursor advances to the newest row seen`() {
        assertEquals(
            "300",
            ChatCacheCodec.newestCursor(
                listOf(cached("a", 100), cached("b", 300), cached("c", 200)),
                nextCursor = null,
                previousCursor = null,
            ),
        )
    }

    @Test
    fun `an empty delta keeps the previous cursor instead of wiping it to null`() {
        // The server only sends `next_cursor` when `has_more` is true, so persisting it would null out a good cursor after every small delta and force a full descending …
        assertEquals(
            "500",
            ChatCacheCodec.newestCursor(emptyList(), nextCursor = null, previousCursor = "500"),
        )
    }

    @Test
    fun `the cursor never regresses when an older page arrives`() {
        assertEquals(
            "900",
            ChatCacheCodec.newestCursor(
                listOf(cached("old", 100)),
                nextCursor = "100",
                previousCursor = "900",
            ),
        )
    }

    @Test
    fun `with nothing cached and nothing to advance to, the server cursor is used`() {
        assertEquals(
            "123",
            ChatCacheCodec.newestCursor(emptyList(), nextCursor = "123", previousCursor = null),
        )
    }

    @Test
    fun `a row with no usable timestamp cannot drag the cursor backwards`() {
        assertEquals(
            "400",
            ChatCacheCodec.newestCursor(
                listOf(cached("a", 0)),
                nextCursor = null,
                previousCursor = "400",
            ),
        )
    }
}
