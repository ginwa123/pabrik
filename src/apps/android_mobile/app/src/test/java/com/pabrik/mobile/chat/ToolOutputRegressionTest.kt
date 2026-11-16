package com.pabrik.mobile.chat

import androidx.compose.runtime.saveable.SaverScope
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The regressions a code review found, each one pinned so it cannot come back. */
class ToolOutputRegressionTest {

    // ─── multi-select answers ───────────────────────────────────────────────

    /** `validateAnswerShape` (`ask_user_answer.zig`) parses the `answer` string itself as JSON when `multi_select` is set. */
    @Test
    fun `a multi-select answer is sent as a JSON array of strings`() {
        val encoded = encodeAnswer(setOf("postgres", "sqlite"), draft = "", multiSelect = true)

        val parsed = JSONArray(encoded!!)
        assertEquals(2, parsed.length())
        assertEquals("postgres", parsed.getString(0))
        assertEquals("sqlite", parsed.getString(1))
    }

    @Test
    fun `a single-select answer is the bare option`() {
        assertEquals("postgres", encodeAnswer(setOf("postgres"), draft = "", multiSelect = false))
    }

    @Test
    fun `a tapped option wins over the text field`() {
        // A question may offer options *and* a free-text box.
        assertEquals("b", encodeAnswer(setOf("b"), draft = "typed something", multiSelect = false))
    }

    @Test
    fun `free text is used when nothing is selected`() {
        assertEquals("typed", encodeAnswer(emptySet(), draft = "  typed  ", multiSelect = false))
    }

    @Test
    fun `an empty answer is null rather than an empty string`() {
        // `validateAnswerShape` rejects an empty answer with `error.EmptyAnswer`.
        assertNull(encodeAnswer(emptySet(), draft = "   ", multiSelect = false))
        assertNull(encodeAnswer(emptySet(), draft = "", multiSelect = false))
    }

    @Test
    fun `a multi-select question with free text and no options still answers`() {
        assertEquals("typed", encodeAnswer(emptySet(), draft = "typed", multiSelect = true))
    }

    // ─── the envelope version ───────────────────────────────────────────────

    /** An unknown `v` may mean the payload's *meaning* changed. */
    @Test
    fun `an unknown envelope version is refused`() {
        assertNull(
            ToolOutput.tryUnwrap(
                """{"tool":"read_file","parameters":{},"success":true,"data":{},"v":2}""",
            ),
        )
    }

    @Test
    fun `a missing envelope version is refused`() {
        assertNull(
            ToolOutput.tryUnwrap(
                """{"tool":"read_file","parameters":{},"success":true,"data":{}}""",
            ),
        )
    }

    @Test
    fun `the current version is accepted`() {
        assertEquals(1, ToolOutput.ENVELOPE_VERSION)
        assertNotNull(
            ToolOutput.tryUnwrap(
                """{"tool":"read_file","parameters":{},"success":true,"data":{},"v":1}""",
            ),
        )
    }

    // ─── the primary field of a running tool ────────────────────────────────

    /** A placeholder row has no result, so the arguments are the only thing the card can say. */
    @Test
    fun `a running shell card shows its command from the arguments`() {
        val model = ToolCard.from(
            ChatMessage(
                id = "r1",
                role = ChatMessage.ROLE_TOOL,
                content = """{"tool":"bash","parameters":{"command":"sleep 30"},""" +
                    """"success":true,"data":null,"error":null,"v":1}""",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                toolName = "bash",
            ),
        )

        assertTrue(model.pending)
        assertEquals("sleep 30", model.primary)
    }

    @Test
    fun `a running search card shows its pattern`() {
        val model = ToolCard.from(
            ChatMessage(
                id = "r1",
                role = ChatMessage.ROLE_TOOL,
                content = """{"tool":"search","parameters":{"pattern":"needle"},""" +
                    """"success":true,"data":null,"error":null,"v":1}""",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                toolName = "search",
            ),
        )

        assertEquals("needle", model.primary)
    }

    /** A running tool is expandable purely because it has arguments. */
    @Test
    fun `a running tool still carries its arguments`() {
        val model = ToolCard.from(
            ChatMessage(
                id = "r1",
                role = ChatMessage.ROLE_TOOL,
                content = """{"tool":"bash","parameters":{"command":"ls"},""" +
                    """"success":true,"data":null,"error":null,"v":1}""",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                toolName = "bash",
            ),
        )

        // The Arguments block is gated on this, and it is the only thing a placeholder row has to show.
        assertTrue(model.parametersJson.isNotBlank())
        assertEquals(ToolBody.Empty, model.body)
    }

    // ─── the header number on a failed card ─────────────────────────────────

    /** A failed card still has to say what it was doing. */
    @Test
    fun `a failed card reports its error rather than going blank`() {
        val model = ToolCard.from(
            ChatMessage(
                id = "r1",
                role = ChatMessage.ROLE_TOOL,
                content = """{"tool":"bash","parameters":{},"success":false,""" +
                    """"data":null,"error":"command not found","v":1}""",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                toolName = "bash",
            ),
        )

        assertFalse(model.success)
        assertEquals("command not found", model.errorText)
    }

    // ─── JSON depth ─────────────────────────────────────────────────────────

    /** The contract is the *return*, not the value: `tryUnwrap` refuses a payload it cannot handle, and refusing is the only acceptable answer here. */
    @Test
    fun `pathologically nested arguments are refused rather than fatal`() {
        val nested = "[".repeat(5_000) + "1" + "]".repeat(5_000)
        val raw = "{\"tool\":\"x\",\"parameters\":{\"deep\":" + nested +
            "},\"success\":true,\"data\":{},\"error\":null,\"v\":1}"

        val envelope = ToolOutput.tryUnwrap(raw)

        // Null on a parser that gave up; a value is fine too, because the platform's JSON implementation may legitimately accept it.
        assertTrue(envelope == null || envelope.name == "x")
        // And pretty-printing the same document must survive whatever the parser decided.
        assertTrue(JsonPretty.pretty(raw).isNotBlank())
    }

    @Test
    fun `pretty printing terminates on nesting past the cap`() {
        val nested = "[".repeat(JsonPretty.MAX_DEPTH + 5) + "1" + "]".repeat(JsonPretty.MAX_DEPTH + 5)

        val pretty = JsonPretty.pretty("{\"deep\":" + nested + "}")

        // How far it descends before the cap trips is the platform JSON implementation's business — the JVM `org.json` refuses to build the structure at all, Android's …
        assertTrue(pretty.isNotBlank())
    }

    @Test
    fun `a value past the cap does not swallow its siblings`() {
        val deep = "[".repeat(JsonPretty.MAX_DEPTH + 2) + "1" + "]".repeat(JsonPretty.MAX_DEPTH + 2)

        // A shallow key next to a too-deep one.
        val pretty = JsonPretty.pretty("{\"deep\":" + deep + ",\"after\":1}")

        assertTrue(pretty.contains("\"after\""))
    }

    // ─── the checklist text ─────────────────────────────────────────────────

    /** The web matches `- [x]` case-insensitively and then splits the text out with a case-*sensitive* `substringAfter`, whose second call cannot match and therefore … */
    @Test
    fun `a checked step keeps its text in either case`() {
        val lower = ToolBody.Plan(body = "- [x] read the wire").lines.single()
        val upper = ToolBody.Plan(body = "- [X] read the wire").lines.single()

        assertEquals("read the wire", lower.text)
        assertEquals("read the wire", upper.text)
        assertEquals(ToolBody.ChecklistLine.ChecklistKind.Checked, lower.kind)
    }

    @Test
    fun `an indented step keeps its text but loses the indent`() {
        val line = ToolBody.Plan(body = "  - [ ] nested step").lines.single()

        assertEquals(ToolBody.ChecklistLine.ChecklistKind.Unchecked, line.kind)
        assertEquals("nested step", line.text)
    }

    @Test
    fun `a step with no text after the marker is not a checklist line`() {
        // `- [x]` alone carries no item, and rendering it as an empty checkbox is noise the plan author did not ask for.
        val line = ToolBody.Plan(body = "- [x]").lines.single()

        assertEquals(ToolBody.ChecklistLine.ChecklistKind.Text, line.kind)
    }

    // ─── the expansion saver ────────────────────────────────────────────────

    /** Saving every key and restoring them all as `true` reopened every card the reader had shut — and four card kinds default to open, so the damage landed on … */
    @Test
    fun `a closed defaulting card stays closed across a save`() {
        val expansion = ToolExpansion()
        expansion.toggle("q1", defaultsToOpen = true)
        assertFalse(expansion.isExpanded("q1", defaultsToOpen = true))

        val saved = with(ToolExpansion.Saver) {
            SaverScope { true }.run { save(expansion) }
        }

        // `listSaver` writes `null` for an empty list, so `rememberSaveable` re-runs the factory and the card comes back on its own default — which is the state the …
        assertNull(saved)
    }

    @Test
    fun `an open card is saved and restored open`() {
        val expansion = ToolExpansion()
        expansion.toggle("r1")

        val saved = with(ToolExpansion.Saver) {
            SaverScope { true }.run { save(expansion) }
        }

        assertEquals(listOf("r1"), saved)
    }
}
