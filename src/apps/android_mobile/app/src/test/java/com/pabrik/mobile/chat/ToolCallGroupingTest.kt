package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A tool call and the output that answers it are one thing to look at. */
class ToolCallGroupingTest {

    private fun declaration(id: String, vararg calls: Pair<String, String>) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        // The backend leaves content empty on a call-only turn.
        content = "",
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        toolName = calls.joinToString(",") { it.second },
        finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
        toolCallsJson = calls.joinToString(prefix = "[", postfix = "]") { (callId, name) ->
            """{"id":"$callId","type":"function","function":{"name":"$name","arguments":"{}"}}"""
        },
    )

    private fun result(id: String, callId: String, name: String) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_TOOL,
        content = "<tool>ok</tool>",
        createdAtEpochMillis = 1L,
        sortKeyNanos = 1L,
        toolName = name,
        toolCallId = callId,
    )

    private fun prose(id: String, text: String) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = text,
        createdAtEpochMillis = 2L,
        sortKeyNanos = 2L,
    )

    @Test
    fun `a call and its output become one list item`() {
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file"),
                result("t1", "c1", "read_file"),
            ),
        )

        assertEquals(1, groups.size)
        assertEquals(ChatMessage.ROLE_TOOL, groups[0].role)
        assertEquals(listOf("t1"), groups[0].messages.map { it.id })
    }

    @Test
    fun `an answered call gets no summary line`() {
        // The card already shows the tool's name and arguments.
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file"),
                result("t1", "c1", "read_file"),
            ),
        )

        assertTrue(groups[0].unpairedToolCalls.isEmpty())
    }

    @Test
    fun `a whole run of calls and outputs draws no summary line at all`() {
        // The exact shape in the report: a dozen alternating pairs.
        val messages = buildList {
            repeat(12) { index ->
                add(declaration("a$index", "c$index" to "command"))
                add(result("t$index", "c$index", "command"))
            }
        }

        val groups = groupMessages(messages)

        // One item per tool result, and not one per declaration as well: the answered declarations have nothing left to draw and are dropped by the empty-group filter …
        assertEquals(12, groups.size)
        assertTrue(groups.all { it.role == ChatMessage.ROLE_TOOL })
        assertTrue(groups.all { it.unpairedToolCalls.isEmpty() })
        assertEquals(
            (0 until 12).map { "t$it" },
            groups.flatMap { it.messages.map { message -> message.id } },
        )
    }

    @Test
    fun `consecutive outputs of one call collapse into a single item`() {
        // One declaration, several results: the fan-out shape.
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "search"),
                result("t1", "c1", "search"),
                result("t2", "c1", "search"),
                result("t3", "c1", "search"),
            ),
        )

        assertEquals(1, groups.size)
        assertEquals(listOf("t1", "t2", "t3"), groups[0].messages.map { it.id })
        assertTrue(groups[0].unpairedToolCalls.isEmpty())
    }

    @Test
    fun `a call with no result yet keeps its summary`() {
        // The live window between the declaration landing and the result arriving.
        val groups = groupMessages(listOf(declaration("a1", "c1" to "read_file")))

        assertEquals(1, groups.size)
        assertEquals(listOf("read_file"), groups[0].unpairedToolCalls.map { it.name })
    }

    @Test
    fun `only the unanswered calls of a batch keep a summary`() {
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file", "c2" to "write_file", "c3" to "search"),
                result("t1", "c1", "read_file"),
                result("t2", "c2", "write_file"),
            ),
        )

        // c3 never came back, so it is the one thing still worth naming.
        assertEquals(listOf("c3"), groups[0].unpairedToolCalls.map { it.id })
        assertEquals(listOf("search"), groups[0].unpairedToolCalls.map { it.name })
    }

    @Test
    fun `a run of outputs stays one item even with no declaration`() {
        val groups = groupMessages(
            listOf(result("t1", "c1", "read_file"), result("t2", "c2", "write_file")),
        )

        assertEquals(1, groups.size)
        assertEquals(2, groups[0].messages.size)
    }

    @Test
    fun `folding never re-keys the run it folded into`() {
        // The run was on screen with its cards open before the declaration's results landed.
        val before = groupMessages(listOf(result("t1", "c1", "read_file")))
        val after = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file"),
                result("t1", "c1", "read_file"),
            ),
        )

        assertEquals("t1", before[0].key)
        assertEquals(before[0].key, after[0].key)
    }

    @Test
    fun `a declaration in a turn that also talks keeps its summary`() {
        // Both rows are `assistant`, so they share one group.
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file"),
                prose("a2", "Here is the answer."),
            ),
        )

        assertEquals(1, groups.size)
        assertEquals(listOf("a1", "a2"), groups[0].messages.map { it.id })
        assertEquals(listOf("read_file"), groups[0].unpairedToolCalls.map { it.name })
    }

    @Test
    fun `a declaration that also carries prose stays its own turn`() {
        // "Let me check that" is the model talking.
        val talking = declaration("a1", "c1" to "read_file").copy(
            content = "Let me check that file.",
        )

        val groups = groupMessages(listOf(talking, result("t1", "c1", "read_file")))

        assertEquals(2, groups.size)
        assertEquals(ChatMessage.ROLE_ASSISTANT, groups[0].role)
        assertEquals(listOf("a1"), groups[0].messages.map { it.id })
    }

    @Test
    fun `a declaration with unparseable tool_calls_json is dropped, not drawn blank`() {
        // The empty-group filter is what keeps a row that renders nothing from reserving a band of viewport and landing the auto-scroll short.
        val broken = declaration("a1").copy(toolCallsJson = "not json at all")

        assertTrue(groupMessages(listOf(broken)).isEmpty())
    }

    @Test
    fun `a turn whose whole content is an empty wrapper is not drawn`() {
        // Non-blank as a string, nothing on screen.
        val empty = prose("a1", "<markdown>\n\n</markdown>")

        assertTrue(groupMessages(listOf(empty)).isEmpty())
    }

    @Test
    fun `two declarations fold into their own runs, not into each other`() {
        val groups = groupMessages(
            listOf(
                declaration("a1", "c1" to "read_file"),
                result("t1", "c1", "read_file"),
                declaration("a2", "c2" to "write_file"),
                result("t2", "c2", "write_file"),
            ),
        )

        assertEquals(2, groups.size)
        assertEquals(listOf("t1"), groups[0].messages.map { it.id })
        assertEquals(listOf("t2"), groups[1].messages.map { it.id })
    }
}
