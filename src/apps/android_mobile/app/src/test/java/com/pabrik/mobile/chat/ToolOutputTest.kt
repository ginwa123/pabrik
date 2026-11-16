package com.pabrik.mobile.chat

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The envelope is the contract every tool card is built on, and every mistake in it shows up as a blank card rather than an exception — so it is asserted here … */
class ToolOutputTest {

    // ─── tryUnwrap ──────────────────────────────────────────────────────────

    @Test
    fun `parses a success envelope`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"read_file","parameters":{"path":"/x.txt"},"success":true,
               "data":{"path":"/x.txt","content":"hi","total_lines":2,
               "start_line":0,"end_line":1},"error":null,"v":1}""".trimIndent(),
        )

        assertNotNull(envelope)
        assertEquals("read_file", envelope!!.name)
        assertTrue(envelope.success)
        assertNull(envelope.error)
        assertNotNull(envelope.data)
        assertEquals("/x.txt", envelope.data!!.optString("path"))
    }

    @Test
    fun `parses a failure envelope and keeps its message`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"read_file","parameters":{},"success":false,
               "data":null,"error":"no such file","v":1}""",
        )

        assertNotNull(envelope)
        assertFalse(envelope!!.success)
        assertEquals("no such file", envelope.error)
        // `success:false` never carries a payload, and a client that trusted one would render a stale body under an error.
        assertNull(envelope.data)
    }

    @Test
    fun `a failure with no message still says something`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"x","parameters":{},"success":false,"data":null,"error":null,"v":1}""",
        )

        assertEquals("tool failed", envelope?.error)
    }

    @Test
    fun `a success never reports an error`() {
        // `success` and `error` are mutually exclusive on the wire; a writer that breaks that must not produce a card claiming both.
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"x","parameters":{},"success":true,"data":{},"error":"boom","v":1}""",
        )

        assertNull(envelope?.error)
    }

    /** The placeholder row the backend inserts the instant the model asks for a tool. */
    @Test
    fun `a success with no data is still in flight`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"bash","parameters":{"command":"ls"},"success":true,
               "data":null,"error":null,"v":1}""",
        )

        assertNotNull(envelope)
        assertTrue(envelope!!.isPending)
    }

    @Test
    fun `a completed success is not pending`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"bash","parameters":{},"success":true,
               "data":{"command":"ls","stdout":"a\n","exit_code":0},"error":null,"v":1}""",
        )

        assertFalse(envelope!!.isPending)
    }

    /** `mcp_*` on success stores the server's raw text, with no envelope at all. */
    @Test
    fun `raw mcp text is not an envelope`() {
        assertNull(ToolOutput.tryUnwrap("Nodes: 14885 Edges: 21958"))
    }

    /** A tool interrupted by a server restart is rewritten to a legacy string. */
    @Test
    fun `an interrupted legacy body is not an envelope`() {
        assertNull(
            ToolOutput.tryUnwrap(
                "<interrupted>Tool execution was interrupted by server restart.</interrupted>",
            ),
        )
    }

    @Test
    fun `blank content is not an envelope`() {
        assertNull(ToolOutput.tryUnwrap(""))
        assertNull(ToolOutput.tryUnwrap("   \n "))
        assertNull(ToolOutput.tryUnwrap(null))
    }

    @Test
    fun `an object without a tool name is not an envelope`() {
        assertNull(ToolOutput.tryUnwrap("""{"path":"/x","content":"hi","v":1}"""))
    }

    @Test
    fun `an envelope without a success flag is not one`() {
        assertNull(ToolOutput.tryUnwrap("""{"tool":"x","parameters":{},"data":{}}"""))
    }

    @Test
    fun `an envelope without parameters is not one`() {
        assertNull(ToolOutput.tryUnwrap("""{"tool":"x","success":true,"data":{}}"""))
    }

    /** `normalizeDataFragment` rewrites any payload whose top level is not an object as `{"_raw": <original>}`, and `remove_file` still emits XML, so a client that … */
    @Test
    fun `a raw payload is surfaced as text`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"remove_file","parameters":{"path":"/x"},"success":true,
               "data":{"_raw":"<path>/x</path>\n<deleted>true</deleted>"},"error":null,"v":1}""",
        )

        assertEquals("<path>/x</path>\n<deleted>true</deleted>", envelope?.rawPayload)
    }

    @Test
    fun `parameters are re-stringified for the arguments block`() {
        val envelope = ToolOutput.tryUnwrap(
            """{"tool":"search","parameters":{"pattern":"foo","path":"src"},
               "success":true,"data":{},"error":null,"v":1}""",
        )

        val parameters = JSONObject(envelope!!.parametersJson)
        assertEquals("foo", parameters.getString("pattern"))
    }

    // ─── JsonPretty ─────────────────────────────────────────────────────────

    /** The Arguments block hides itself on the literal string `"{}"`, so an empty object must render as `{}` and not as the built-in `{ }` — which would put an … */
    @Test
    fun `an empty object pretty-prints as the exact guard string`() {
        assertEquals("{}", JsonPretty.pretty("{}"))
        assertEquals("[]", JsonPretty.pretty("[]"))
    }

    @Test
    fun `nesting is indented two spaces per level`() {
        assertEquals(
            """
            {
              "a": {
                "b": [
                  1,
                  2
                ]
              }
            }
            """.trimIndent(),
            JsonPretty.pretty("""{"a":{"b":[1,2]}}"""),
        )
    }

    @Test
    fun `control characters and quotes survive a round trip`() {
        val pretty = JsonPretty.pretty("""{"a":"x\ny\t\"z\""}""")
        assertEquals("x\ny\t\"z\"", org.json.JSONObject(pretty).getString("a"))
    }

    @Test
    fun `a non-json string is returned untouched`() {
        assertEquals("not json", JsonPretty.pretty("not json"))
    }

    // ─── ToolCalls ──────────────────────────────────────────────────────────

    /** `tool_calls_json` is a JSON *string* holding an array whose `arguments` are themselves a JSON string, so it is parsed twice. */
    @Test
    fun `tool calls are parsed out of a double-encoded string`() {
        val calls = ToolCalls.parse(
            """[{"id":"call_1","type":"function","function":{"name":"bash",
               "arguments":"{\"command\":\"ls -la\"}"}}]""".trimIndent().replace("\n", ""),
        )

        assertEquals(1, calls.size)
        assertEquals("call_1", calls[0].id)
        assertEquals("bash", calls[0].name)
        assertTrue(calls[0].argumentsJson.contains("ls -la"))
    }

    @Test
    fun `an absent or malformed tool call list is empty, not a crash`() {
        assertTrue(ToolCalls.parse(null).isEmpty())
        assertTrue(ToolCalls.parse("").isEmpty())
        assertTrue(ToolCalls.parse("not json").isEmpty())
        assertTrue(ToolCalls.parse("[]").isEmpty())
    }

    @Test
    fun `a tool call summary is one line`() {
        val call = ToolCallEntry("id", "read_file", """{"path":"/a
b"}""")

        assertFalse(call.summary.contains("\n"))
    }

    @Test
    fun `a tool call with no arguments has no summary`() {
        assertEquals("", ToolCallEntry("id", "stop_run", "{}").summary)
    }
}
