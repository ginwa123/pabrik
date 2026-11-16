package com.pabrik.mobile.chat

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The event-stream reader. */
class SseFrameParserTest {

    private fun parse(raw: String): List<SseFrame> {
        val parser = SseFrameParser()
        val frames = mutableListOf<SseFrame>()
        raw.lines().forEach { line -> parser.accept(line)?.let { frames.add(it) } }
        parser.flush()?.let { frames.add(it) }
        return frames
    }

    @Test
    fun `the handshake is one frame`() {
        val frames = parse("event: connected\ndata: {\"connected\": true}\n\n")

        assertEquals(1, frames.size)
        assertEquals("connected", frames.single().event)
        assertEquals("""{"connected": true}""", frames.single().data)
    }

    @Test
    fun `a pretty-printed payload is rejoined across its data lines`() {
        val raw = """
            event: llm_full
            data: {
            data:     "content": "hello",
            data:     "session_id": "sess_1"
            data: }

        """.trimIndent()

        val frame = parse(raw).single()

        assertEquals("llm_full", frame.event)
        // Byte-for-byte what the server serialised, which is what makes the result parseable as JSON.
        assertEquals("{\n    \"content\": \"hello\",\n    \"session_id\": \"sess_1\"\n}", frame.data)
    }

    @Test
    fun `a frame dispatches on the blank line, not on a complete object`() {
        val frames = parse("event: a\ndata: {\"x\":1}\n\nevent: b\ndata: {\"x\":2}\n\n")

        assertEquals(2, frames.size)
        assertEquals("a", frames[0].event)
        assertEquals("b", frames[1].event)
    }

    @Test
    fun `comment lines and the heartbeat are ignored`() {
        val frames = parse(": ping\n\nevent: connected\ndata: {}\n\n")

        assertEquals(1, frames.size)
        assertEquals("connected", frames.single().event)
    }

    @Test
    fun `a stream that ends mid-frame still dispatches what it has`() {
        // A connection dropped mid-frame must not swallow a complete-looking payload, or the last turn before a network blip is lost.
        val parser = SseFrameParser()
        parser.accept("event: llm_full")
        parser.accept("""data: {"id":"m1"}""")

        val frame = parser.flush()

        assertNotNull(frame)
        assertEquals("llm_full", frame!!.event)
        assertEquals("""{"id":"m1"}""", frame.data)
    }

    @Test
    fun `a frame with no event line is dispatched under the default name`() {
        val frames = parse("data: {\"x\":1}\n\n")

        assertEquals(SseFrameParser.DEFAULT_EVENT, frames.single().event)
        assertEquals("""{"x":1}""", frames.single().data)
    }

    @Test
    fun `only the first space after the colon is stripped`() {
        val frames = parse("event: connected\ndata:  two spaces\n\n")

        assertEquals(" two spaces", frames.single().data)
    }

    @Test
    fun `an empty stream dispatches nothing`() {
        assertTrue(parse("").isEmpty())
        assertTrue(parse("\n\n\n").isEmpty())
        assertTrue(parse(": only comments\n").isEmpty())
    }
}

/** Decoding a frame into the meaning the chat acts on. */
class ChatStreamEventTest {

    private fun frame(event: String, data: String) = SseFrame(event, data)

    @Test
    fun `a content chunk is one event`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk","index":0,"session_id":"sess_1","content":"Hel"}""",
            ),
        ) as ChatStreamEvent.Chunk

        assertEquals("sess_1", decoded.sessionId)
        assertEquals("Hel", decoded.content)
        assertEquals("", decoded.reasoningContent)
    }

    @Test
    fun `a reasoning chunk shares the chunk type and is told apart by its field`() {
        // `type: "chunk"` is overloaded across content and reasoning, so branching on the type alone loses every thinking delta.
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk","index":0,"session_id":"sess_1","reasoning_content":"thinking"}""",
            ),
        ) as ChatStreamEvent.Chunk

        assertEquals("thinking", decoded.reasoningContent)
        assertEquals("", decoded.content)
    }

    @Test
    fun `a chunk with neither field is not an event`() {
        assertNull(decodeChatFrame(frame("llm_chunk", """{"type":"chunk","index":0,"session_id":"s"}""")))
    }

    @Test
    fun `a final chunk carries no message`() {
        // `total_tokens` is nested under `usage`, not at the top level — the backend's `FinalChunkJson` is `{index, type, finish_reason, usage, session_id}` and `usage` …
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk_final","index":0,"session_id":"sess_1",
                   "usage":{"prompt_tokens":10,"completion_tokens":32,"total_tokens":42}}""",
            ),
        ) as ChatStreamEvent.ChunkFinished

        assertEquals("sess_1", decoded.sessionId)
        assertEquals(42, decoded.totalTokens)
    }

    @Test
    fun `a final chunk with no usage reports no token count`() {
        // The emitter leaves `usage` null whenever the provider sent no usage block, which is the normal case for a turn that was cut short.
        val decoded = decodeChatFrame(
            frame(
                "llm_chunk",
                """{"type":"chunk_final","index":0,"session_id":"sess_1","usage":null}""",
            ),
        ) as ChatStreamEvent.ChunkFinished

        assertNull(decoded.totalTokens)
    }

    @Test
    fun `a full frame becomes a canonical message`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","role":"assistant",
                   "content":"done","created_at":"1789451234567890123"}""",
            ),
        ) as ChatStreamEvent.Full

        assertEquals("sess_1", decoded.sessionId)
        assertEquals("m1", decoded.message.id)
        assertEquals(ChatMessage.ROLE_ASSISTANT, decoded.message.role)
    }

    @Test
    fun `a contentless tool row is still a real turn`() {
        // Gating on content alone used to silently drop every tool result and every image-only echo, which looked like the agent doing nothing.
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","tool_call_id":"call_1","tool_name":"command"}""",
            ),
        ) as ChatStreamEvent.Full

        assertEquals("command", decoded.message.toolName)
    }

    @Test
    fun `a truly empty row is dropped rather than rendering a blank bubble`() {
        assertNull(
            decodeChatFrame(frame("llm_full", """{"type":"full","id":"m1","session_id":"sess_1"}""")),
        )
    }

    /** Sub-agent pings ride the `llm_full` channel with a synthetic role and an empty body. */
    @Test
    fun `a sub-agent progress ping is routed before the generic row handling`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","role":"subagent_progress","session_id":"sess_1",
                   "tool_call_id":"call_9","agent_name":"explorer","status":"launched",
                   "agent_index":0,"total_agents":3,"elapsed_ms":0,"content":"",
                   "subagent_session_id":"subagent_1756_frontend"}""",
            ),
        ) as ChatStreamEvent.SubAgentProgress

        assertEquals("sess_1", decoded.sessionId)
        assertEquals("call_9", decoded.toolCallId)
        assertEquals("explorer", decoded.agentName)
        assertEquals(ChatStreamEvent.SubAgentProgress.STATUS_LAUNCHED, decoded.status)
        assertEquals(0, decoded.agentIndex)
        assertEquals(3, decoded.totalAgents)
    }

    @Test
    fun aCompletedSubAgentPingCarriesItsStatusAndPosition() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","role":"subagent_progress","session_id":"sess_1",
                   "tool_call_id":"call_9","agent_name":"explorer","status":"failed",
                   "agent_index":1,"total_agents":3,"elapsed_ms":4200,"content":""}""",
            ),
        ) as ChatStreamEvent.SubAgentProgress

        assertEquals(ChatStreamEvent.SubAgentProgress.STATUS_FAILED, decoded.status)
        // The index is what tells two nameless agents in one batch apart, so it is the one field the running count cannot do without.
        assertEquals(1, decoded.agentIndex)
    }

    /** A tool row's `content` is the result envelope, and the two frames for one row — the placeholder and the result — share an `id`. */
    @Test
    fun `the placeholder and the result of one tool share a row id`() {
        val row = { content: String ->
            frame(
                "llm_full",
                // The row fields the backend sends, with the envelope supplied per-frame: the placeholder carries `data: null`, the result carries the payload, and the `id` is …
                """{"type":"full","id":"row_7","session_id":"sess_1","role":"tool",""" +
                    """"finish_reason":"tool","tool_call_id":"call_1",""" +
                    """"tool_name":"read_file","content":""" + JSONObject.quote(content) + "}",
            )
        }
        val placeholder = decodeChatFrame(
            row(
                """{"tool":"read_file","parameters":{"path":"/x"},"success":true,""" +
                    """"data":null,"error":null,"v":1}""",
            ),
        ) as ChatStreamEvent.Full
        val result = decodeChatFrame(
            row(
                """{"tool":"read_file","parameters":{"path":"/x"},"success":true,""" +
                    """"data":{"path":"/x","content":"hi"},"error":null,"v":1}""",
            ),
        ) as ChatStreamEvent.Full

        // One row, two frames: the store upserts by id, and anything else renders the same tool twice.
        assertEquals(placeholder.message.id, result.message.id)
        assertTrue(ToolCard.from(placeholder.message).pending)
        assertFalse(ToolCard.from(result.message).pending)
        assertEquals("hi", (ToolCard.from(result.message).body as ToolBody.ReadFile).content)
    }

    /** An assistant turn that only calls tools has an empty body. */
    @Test
    fun `an assistant tool-call turn survives its empty body`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m2","session_id":"sess_1","role":"assistant",
                   "finish_reason":"tool_calls","content":"","tool_name":"read_file,write_file",
                   "tool_calls_json":"[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"/x\\\"}\"}}]"}""",
            ),
        ) as ChatStreamEvent.Full

        assertTrue(decoded.message.isToolCallTurn)
        assertEquals(1, ToolCalls.parse(decoded.message.toolCallsJson).size)
    }

    /** The regression that a "draws something" gate would introduce. */
    @Test
    fun `a declaration is kept by the stream even though it draws nothing`() {
        val message = ChatMessage(
            id = "m2",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
            toolName = "read_file",
            finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
            toolCallsJson = """[{"id":"call_1","type":"function","function":{"name":"read_file"}}]""",
        )

        assertFalse(message.hasVisibleContent)
        assertTrue(message.isRealTurn)
    }

    @Test
    fun `an is_error frame is a diagnostic, not a chat turn`() {
        val decoded = decodeChatFrame(
            frame(
                "llm_full",
                """{"type":"full","id":"m1","session_id":"sess_1","content":"TooManyRetries","is_error":true}""",
            ),
        )

        assertTrue(decoded is ChatStreamEvent.Failed)
        assertEquals("TooManyRetries", (decoded as ChatStreamEvent.Failed).message)
    }

    @Test
    fun `an auth_error surfaces instead of looking like a flaky network`() {
        // The response is already committed as text/event-stream by the time auth runs, so the server cannot answer 401 — it sends this and closes.
        val decoded = decodeChatFrame(frame("auth_error", """{"error":"Unauthenticated"}"""))

        assertEquals("Unauthenticated", (decoded as ChatStreamEvent.Failed).message)
    }

    @Test
    fun `session events report the action from the event name`() {
        val updated = decodeChatFrame(
            frame(
                "session_updated",
                """{"action":"updated","id":"sess_1","name":"Renamed by the auto-title pass"}""",
            ),
        ) as ChatStreamEvent.SessionChanged

        // `session_updated` is load-bearing: the auto-rename cascade used to arrive as `session_unknown`, which nothing handled, so titles stayed "New Chat" until a …
        assertEquals("updated", updated.action)
        assertEquals("Renamed by the auto-title pass", updated.name)
    }

    @Test
    fun `queue events report the action too`() {
        val queued = decodeChatFrame(
            frame("queue_queued", """{"action":"queued","id":"q1","session_id":"sess_1"}"""),
        ) as ChatStreamEvent.QueueChanged

        assertEquals("queued", queued.action)
        assertEquals("sess_1", queued.sessionId)
    }

    @Test
    fun `a queued turn carries the row the reader has to be shown`() {
        // The whole reason this is not a +1/-1: a composer that can queue a turn must be able to say *which* turn is waiting, and a count cannot.
        val queued = decodeChatFrame(
            frame(
                "queue_queued",
                """{"action":"queued","id":"q1","session_id":"sess_1","message":"then open a PR"}""",
            ),
        ) as ChatStreamEvent.QueueChanged

        assertEquals("q1", queued.id)
        assertEquals("then open a PR", queued.message)
    }

    @Test
    fun `a drained turn is identified by its id and carries no text`() {
        // `queue_deleted` is `{action, id, session_id}` — no `message` key at all.
        val deleted = decodeChatFrame(
            frame("queue_deleted", """{"action":"deleted","id":"q1","session_id":"sess_1"}"""),
        ) as ChatStreamEvent.QueueChanged

        assertEquals("deleted", deleted.action)
        assertEquals("q1", deleted.id)
        assertEquals("", deleted.message)
    }

    @Test
    fun `a queue frame with no id is dropped rather than published unmatchable`() {
        // Every later delete is matched on the id, so a row without one could only ever be appended and never removed — it would sit in the panel for the rest of the …
        assertNull(
            decodeChatFrame(frame("queue_queued", """{"action":"queued","session_id":"sess_1"}""")),
        )
    }

    @Test
    fun `an event this screen does not act on is dropped, not an error`() {
        assertNull(decodeChatFrame(frame("kanban_task", """{"id":"t1"}""")))
        assertNull(decodeChatFrame(frame("background_process_created", """{"id":"b1"}""")))
    }

    @Test
    fun `a worker_created frame names the session it started`() {
        val created = decodeChatFrame(
            frame(
                "worker_created",
                """{"action":"created","id":"sess_1","session_id":"sess_1",
                   "last_activity_description":"running tool: exec_read"}""",
            ),
        ) as ChatStreamEvent.WorkerChanged

        assertEquals("sess_1", created.sessionId)
        assertEquals(ChatStreamEvent.WorkerChanged.ACTION_CREATED, created.action)
    }

    @Test
    fun `a worker_deleted frame falls back to id because session_id is empty`() {
        // All three delete emitters send `"session_id": ""` and put the session in `id`.
        val deleted = decodeChatFrame(
            frame("worker_deleted", """{"action":"deleted","id":"sess_7","session_id":""}"""),
        ) as ChatStreamEvent.WorkerChanged

        assertEquals("sess_7", deleted.sessionId)
        assertEquals(ChatStreamEvent.WorkerChanged.ACTION_DELETED, deleted.action)
    }

    @Test
    fun `a worker_updated frame resolves from session_id when the upsert sent it`() {
        // The two `updated` emitters differ: `updateWorker` sends both fields, `updateWorkerActivityWithDescription` sends only `id`.
        val populated = decodeChatFrame(
            frame("worker_updated", """{"action":"updated","id":"sess_7","session_id":"sess_7"}"""),
        ) as ChatStreamEvent.WorkerChanged
        val bare = decodeChatFrame(
            frame("worker_updated", """{"action":"updated","id":"sess_7","session_id":""}"""),
        ) as ChatStreamEvent.WorkerChanged

        assertEquals("sess_7", populated.sessionId)
        assertEquals("sess_7", bare.sessionId)
        assertEquals(ChatStreamEvent.WorkerChanged.ACTION_UPDATED, populated.action)
    }

    @Test
    fun `a worker frame with no id at all is dropped`() {
        assertNull(
            decodeChatFrame(frame("worker_created", """{"action":"created","session_id":""}""")),
        )
    }

    @Test
    fun `a worker frame survives the backend's pretty-printed payload`() {
        // The server serialises with indent_4, so the frame parser joins the
        // data lines back with newlines before this sees them.
        val payload = listOf(
            "event: worker_created",
            "data: {",
            "data:     " + Q + "action" + Q + ": " + Q + "created" + Q + ",",
            "data:     " + Q + "id" + Q + ": " + Q + "sess_3" + Q + ",",
            "data:     " + Q + "session_id" + Q + ": " + Q + "sess_3" + Q + ",",
            "data:     " + Q + "last_activity_description" + Q + ": " + Q + "running tool" + Q,
            "data: }",
            "",
        ).joinToString("\n")

        val parser = SseFrameParser()
        val frame = parser.let { p ->
            var result: SseFrame? = null
            payload.split("\n").forEach { line -> result = result ?: p.accept(line) }
            result
        }

        val created = decodeChatFrame(frame!!) as ChatStreamEvent.WorkerChanged
        assertEquals("sess_3", created.sessionId)
    }

    /** A double quote, spelled so the raw string above need not escape it. */
    private val Q = "\""

    @Test
    fun `an unparseable payload is dropped without killing the stream`() {
        assertNull(decodeChatFrame(frame("llm_full", "{not json")))
        assertNull(decodeChatFrame(frame("llm_chunk", "")))
    }
}
