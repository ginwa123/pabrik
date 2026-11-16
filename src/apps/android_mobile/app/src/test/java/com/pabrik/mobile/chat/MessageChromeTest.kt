package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bubble rule: a bubble is the reader's own turn and nothing else. */
class MessageChromeTest {

    private fun message(
        role: String,
        id: String = "m1",
        isError: Boolean = false,
        toolName: String = "",
    ) = ChatMessage(
        id = id,
        role = role,
        content = "text",
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        isError = isError,
        toolName = toolName,
    )

    private fun group(role: String, vararg messages: ChatMessage) = ChatMessageGroup(
        key = messages.firstOrNull()?.id ?: "g1",
        role = role,
        messages = messages.toList(),
        timestampEpochMillis = 0L,
    )

    @Test
    fun `a reader turn is the one row that keeps the bubble`() {
        assertEquals(MessageChrome.BUBBLE, messageChrome(message(ChatMessage.ROLE_USER)))
    }

    @Test
    fun `an assistant turn is flat prose, not a bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_ASSISTANT)),
        )
    }

    @Test
    fun `a tool result is a card and never a bubble`() {
        assertEquals(
            MessageChrome.TOOL_CARD,
            messageChrome(message(ChatMessage.ROLE_TOOL, toolName = "read_file")),
        )
    }

    /** `system` is a role the wire can deliver and nothing in this app renders it as a conversation turn, so it belongs on the prose side. */
    @Test
    fun `a system turn is prose, not a bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_SYSTEM)),
        )
    }

    /** The regression this whole file exists for: `isError` frames are the agentic-loop's own diagnostics, and the instinct when styling one is to wrap it in a raised … */
    @Test
    fun `a diagnostic frame is prose too, not a raised bubble`() {
        assertEquals(
            MessageChrome.PARAGRAPH,
            messageChrome(message(ChatMessage.ROLE_ASSISTANT, isError = true)),
        )
    }

    /** Role wins over `isError`, in the other direction. */
    @Test
    fun `a flagged user turn still bubbles`() {
        assertEquals(
            MessageChrome.BUBBLE,
            messageChrome(message(ChatMessage.ROLE_USER, isError = true)),
        )
    }

    /** Exhaustiveness, stated as a test. */
    @Test
    fun `the role to frame table is pinned`() {
        assertEquals(
            mapOf(
                ChatMessage.ROLE_USER to MessageChrome.BUBBLE,
                ChatMessage.ROLE_ASSISTANT to MessageChrome.PARAGRAPH,
                ChatMessage.ROLE_SYSTEM to MessageChrome.PARAGRAPH,
                ChatMessage.ROLE_TOOL to MessageChrome.TOOL_CARD,
            ),
            ChatMessage.knownRoles().associateWith { messageChrome(message(it)) },
        )
    }

    /** A flat paragraph has to be spaced by something other than its box. */
    @Test
    fun `flat paragraphs get more room than bubbles`() {
        val assistant = groupGapDp(group(ChatMessage.ROLE_ASSISTANT, message(ChatMessage.ROLE_ASSISTANT)))
        val user = groupGapDp(group(ChatMessage.ROLE_USER, message(ChatMessage.ROLE_USER)))
        assertTrue(
            "assistant gap $assistant should exceed bubble gap $user",
            assistant > user,
        )
        assertEquals(10, assistant)
        assertEquals(6, user)
    }
}
