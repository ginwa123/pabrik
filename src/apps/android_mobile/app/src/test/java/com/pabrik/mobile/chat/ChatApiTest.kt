package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The wire contract for the chat endpoint. */
class ChatApiTest {

    // A real payload shape, with the envelope fields the server always emits.
    private val messagesResponse = """
        {
          "messages": [
            {
              "id": "1789451234567890123",
              "session_id": "sess_1",
              "role": "user",
              "content": "Hai!",
              "created_at": "1789451234567890123",
              "is_input": true,
              "is_output": false,
              "tool_name": "",
              "finish_reason": "",
              "reasoning_content": "",
              "diffview_before": "",
              "diffview_after": "",
              "image_url": "",
              "video_url": "",
              "tool_call_id": "",
              "tool_calls_json": ""
            },
            {
              "id": "1789451234567890124",
              "session_id": "sess_1",
              "role": "tool",
              "content": "done",
              "created_at": "1789451234567890124",
              "is_input": false,
              "is_output": false,
              "tool_name": "command",
              "finish_reason": "",
              "reasoning_content": "",
              "diffview_before": "",
              "diffview_after": "",
              "image_url": "data:image/png;base64,AAA|data:image/jpeg;base64,BBB",
              "video_url": "data:video/mp4;base64,CCC",
              "tool_call_id": "call_1",
              "tool_calls_json": "{\"name\":\"command\"}"
            }
          ],
          "has_more": false,
          "next_cursor": null,
          "cwd": "/home/ginwa/ginwaaitoolbox",
          "git_worktree_cwd": "",
          "pr_url": null,
          "pr_provider": null,
          "selected_profile_model": "900ribu",
          "sub_agent_name": null,
          "parent_session_id": null,
          "max_total_tokens": 82679,
          "max_capacity_total_tokens": 900000,
          "total": 2,
          "skills": null
        }
    """.trimIndent()

    @Test
    fun `the message path sorts by id because created_at is inconsistent across pages`() {
        val path = ChatApi.messagesPath("sess_1", limit = 50, direction = "asc")

        // `sort_by=created_at` orders page 1 by the *session's* created_at — identical for every row, so it degenerates to id order — and later pages by the message's.
        assertTrue(path, path.contains("sort_by=id"))
        assertTrue(path, path.contains("direction=asc"))
        assertTrue(path, path.contains("limit=50"))
        assertTrue(path, path.contains("/api/llm/session/sess_1/messages"))
    }

    @Test
    fun `a cursor is only sent when there is one`() {
        assertTrue(ChatApi.messagesPath("s", cursor = "1789451234567890123").contains("cursor=1789451234567890123"))
        assertTrue(ChatApi.messagesPath("s", cursor = null).endsWith("direction=asc"))
        assertTrue(ChatApi.messagesPath("s", cursor = "  ").endsWith("direction=asc"))
    }

    @Test
    fun `an absurd limit is clamped because the server does not clamp it`() {
        val path = ChatApi.messagesPath("s", limit = 100_000)
        assertTrue(path, path.contains("limit=1000"))
    }

    @Test
    fun `a session id is percent encoded so it cannot escape its path segment`() {
        val path = ChatApi.messagesPath("../admin")
        assertTrue(path, path.contains("/api/llm/session/..%2Fadmin/messages"))
    }

    @Test
    fun `parsing reads total and not the key the desktop client invented`() {
        val page = ChatApi.parseMessages(messagesResponse)

        assertEquals(2, page.messages.size)
        assertEquals(2, page.total)
        assertEquals("900ribu", page.selectedProfileModel)
        assertEquals("/home/ginwa/ginwaaitoolbox", page.cwd)
        assertEquals(false, page.hasMore)
        assertNull(page.nextCursor)
    }

    @Test
    fun `a null cursor stays null instead of becoming the text null`() {
        val page = ChatApi.parseMessages(
            """{"messages":[],"next_cursor":null,"has_more":false,"total":0}""",
        )
        assertNull(page.nextCursor)
    }

    @Test
    fun `created_at holding nanoseconds is read as a nanosecond stamp`() {
        val page = ChatApi.parseMessages(messagesResponse)
        val first = page.messages.first()

        assertEquals(1_789_451_234_567_890_123L, first.sortKeyNanos)
        assertEquals(1_789_451_234_567L, first.createdAtEpochMillis)
    }

    @Test
    fun `created_at holding a SQLite datetime is read as UTC, not device-local`() {
        // The same column is written both ways depending on the code path, so this shape genuinely occurs.
        val page = ChatApi.parseMessages(
            """{"messages":[{"id":"a","role":"user","content":"x","created_at":"2026-09-26 05:07:34"}]}""",
        )
        val nanos = page.messages.single().sortKeyNanos

        assertEquals("2026-09-26T05:07:34Z", java.time.Instant.ofEpochMilli(nanos / 1_000_000).toString())
    }

    @Test
    fun `an absent or garbage timestamp sorts to the start rather than to 1970`() {
        assertEquals(0L, ChatApi.parseCreatedAtNanos(null))
        assertEquals(0L, ChatApi.parseCreatedAtNanos(""))
        assertEquals(0L, ChatApi.parseCreatedAtNanos("   "))
        assertEquals(0L, ChatApi.parseCreatedAtNanos("not a timestamp"))
        // Calendar-invalid: matches the shape but is not an instant.
        assertEquals(0L, ChatApi.parseCreatedAtNanos("2026-02-31 00:00:00"))
    }

    @Test
    fun `image and video urls are pipe delimited, not arrays`() {
        val page = ChatApi.parseMessages(messagesResponse)
        val toolRow = page.messages[1]

        assertEquals(
            listOf("data:image/png;base64,AAA", "data:image/jpeg;base64,BBB"),
            toolRow.imageUrls,
        )
        assertEquals(listOf("data:video/mp4;base64,CCC"), toolRow.videoUrls)
    }

    @Test
    fun `a blank entry between pipes is dropped rather than rendered as an attachment`() {
        assertEquals(
            listOf("a", "b"),
            ChatApi.splitPipeDelimited("a||b|"),
        )
        assertEquals(emptyList<String>(), ChatApi.splitPipeDelimited(""))
        assertEquals(emptyList<String>(), ChatApi.splitPipeDelimited(null))
    }

    @Test
    fun `tool_calls_json stays the JSON string the server sent`() {
        val page = ChatApi.parseMessages(messagesResponse)
        // The desktop client types this as `any`, which quietly invites a caller to treat it as an object.
        assertEquals("command", page.messages[1].toolName)
        assertEquals("call_1", page.messages[1].toolCallId)
    }

    @Test
    fun `a row with no id is dropped because it cannot be merged or keyed`() {
        // A duplicate key crashes LazyColumn outright, so an idless row is not something to paper over with a synthetic id.
        val page = ChatApi.parseMessages(
            """{"messages":[{"role":"user","content":"no id"},{"id":"","content":"blank id"},{"id":"ok","content":"fine"}]}""",
        )
        assertEquals(listOf("ok"), page.messages.map { it.id })
    }

    @Test
    fun `a role-less tool row is recognised as a tool row`() {
        val page = ChatApi.parseMessages(
            """{"messages":[{"id":"a","content":"x","tool_call_id":"call_9"}]}""",
        )
        assertEquals(ChatMessage.ROLE_TOOL, page.messages.single().role)
    }

    @Test
    fun `the same mapper renders a cached raw envelope and a network row identically`() {
        // The web's hard-won rule: two mappers for one endpoint is how a cached mount and a live mount drift.
        val network = ChatApi.parseMessages(messagesResponse).messages.first()
        val cached = ChatApi.toChatMessage(network.rawEnvelope())

        assertNotNull(cached)
        assertEquals(network, cached)
    }

    @Test
    fun `a corrupt cached envelope is a miss, not a crash`() {
        assertNull(ChatApi.toChatMessage("{not json"))
        assertNull(ChatApi.toChatMessage(""))
    }

    @Test
    fun `an envelope that omits every optional field still parses`() {
        val page = ChatApi.parseMessages("""{"messages":[]}""")
        assertEquals(0, page.messages.size)
        assertEquals(null, page.total)
        assertEquals("", page.cwd)
    }

    @Test
    fun `merging replaces by id and keeps transcript order`() {
        val a = message("1", "first")
        val b = message("2", "second")
        val updatedB = message("2", "second, revised")

        val merged = ChatApi.mergeById(listOf(a, b), listOf(updatedB))

        assertEquals(listOf("1", "2"), merged.map { it.id })
        assertEquals("second, revised", merged.last().content)
    }

    @Test
    fun `merging nothing leaves the list untouched`() {
        val messages = listOf(message("1", "a"))
        assertEquals(messages, ChatApi.mergeById(messages, emptyList()))
    }

    @Test
    fun `the send body carries the web's tool grant and pipe-joins attachments`() {
        val body = org.json.JSONObject(
            ChatApi.sendMessageBody(
                sessionId = "sess_1",
                message = "hello",
                cwd = "/tmp",
                imageUrls = listOf("img1", "img2"),
                videoUrls = listOf("vid1"),
                selectedProfileModel = "900ribu",
            ),
        )

        assertEquals("sess_1", body.getString("session_id"))
        assertEquals("hello", body.getString("queue_message"))
        assertEquals("/tmp", body.getString("cwd_session"))
        assertEquals("img1|img2", body.getString("image_urls"))
        assertEquals("vid1", body.getString("video_urls"))
        assertEquals("900ribu", body.getString("selected_profile_model"))
        assertTrue(body.getString("allowed_tools").contains("ask_user"))
    }

    // --- The queue ---------------------------------------------------------

    @Test
    fun theQueueIsReadFromTheSessionTree() {
        // `queue_messages` is registered *after* `/messages` and before
        // `/stream` (`main.zig:549`), because the router matches in
        // registration order — a path built for any other tree 404s.
        assertEquals(
            "/api/llm/session/sess_1/queue_messages",
            ChatApi.queueMessagesPath("sess_1"),
        )
    }

    @Test
    fun aSessionIdIsEncodedRatherThanConcatenated() {
        // A `/` in the id would otherwise create a path the router splits in
        // the wrong place — the same class of bug as the route-order shadowing
        // the sibling routes are ordered around.
        assertEquals(
            "/api/llm/session/sess%2F1/queue_messages",
            ChatApi.queueMessagesPath("sess/1"),
        )
    }

    @Test
    fun theQueuedTurnsComeBackInOrderWithBothFields() {
        val body = """
            {
              "messages": [
                {"id": "1789451234567890123", "message": "then run the tests"},
                {"id": "1789451234567890124", "message": "and open a PR"}
              ],
              "count": 2
            }
        """.trimIndent()

        val queued = ChatApi.parseQueuedMessages(body)

        assertEquals(2, queued.size)
        assertEquals("1789451234567890123", queued[0].id)
        assertEquals("then run the tests", queued[0].message)
        assertEquals("and open a PR", queued[1].message)
    }

    @Test
    fun anEmptyQueueIsAnEmptyListAndNotAFailure() {
        assertEquals(emptyList<QueuedChatMessage>(), ChatApi.parseQueuedMessages("""{"messages":[],"count":0}"""))
    }

    @Test
    fun aQueuedTurnWithNoTextDoesNotArriveAsTheWordNull() {
        // Migration 054 made `session_queue_messages.message` nullable so an
        // image-only background-process row can live in the same table, and
        // `optString` on an explicit JSON null renders four characters. The
        // panel then shows "null" where the reader queued a screenshot.
        val body = """
            {
              "messages": [
                {"id": "q1", "message": null},
                {"id": "q2", "message": "real text"}
              ],
              "count": 2
            }
        """.trimIndent()

        val queued = ChatApi.parseQueuedMessages(body)

        assertEquals("", queued[0].message)
        assertEquals("real text", queued[1].message)
    }

    @Test
    fun aQueuedRowWithNoIdIsDropped() {
        // Every delete is matched on the id, so a row without one can be
        // appended and never removed — it would sit in the panel forever.
        val body = """{"messages":[{"id":"","message":"orphan"},{"id":"q1","message":"kept"}],"count":2}"""

        val queued = ChatApi.parseQueuedMessages(body)

        assertEquals(1, queued.size)
        assertEquals("kept", queued[0].message)
    }

    @Test
    fun theCountIsNotTrustedOverTheRows() {
        // The server computes the two together, so reading `count` would only
        // add a second way for the header's number and the panel's list to
        // disagree. Two rows and a count of 9 is not a state to honour.
        val body = """{"messages":[{"id":"q1","message":"a"},{"id":"q2","message":"b"}],"count":9}"""

        assertEquals(2, ChatApi.parseQueuedMessages(body).size)
    }

    private fun message(id: String, content: String) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_USER,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
    )

    /** Rebuilds the wire object a row came from, the way the cache stores it. */
    private fun ChatMessage.rawEnvelope(): String = org.json.JSONObject()
        .put("id", id)
        .put("role", role)
        .put("content", content)
        .put("created_at", sortKeyNanos.toString())
        .toString()
}
