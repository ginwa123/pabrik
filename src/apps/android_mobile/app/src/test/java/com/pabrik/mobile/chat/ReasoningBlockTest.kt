package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which turns get a reasoning fold, and under what key. */
class ReasoningBlockTest {

    private fun assistant(
        id: String = "m1",
        content: String = "Here is the answer.",
        reasoning: String = "Let me work through it.",
    ) = ChatMessage(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        reasoningContent = reasoning,
    )

    @Test
    fun `an assistant turn with reasoning draws the fold`() {
        assertTrue(showsReasoning(assistant()))
    }

    @Test
    fun `a turn with no reasoning draws nothing`() {
        assertFalse(showsReasoning(assistant(reasoning = "")))
    }

    /** `isNotBlank`, not `isNotEmpty`, because the stream delivers a reasoning chunk as a delta: between the turn being created and its first real delta the field is … */
    @Test
    fun `a whitespace-only reasoning draws nothing`() {
        assertFalse(showsReasoning(assistant(reasoning = "   \n\t ")))
    }

    @Test
    fun `the reader's own turn never gets a fold`() {
        val reader = assistant().copy(role = ChatMessage.ROLE_USER)

        assertFalse(showsReasoning(reader))
    }

    /**
     * The regression this namespacing exists to prevent. A tool card is filed
     * under its `ToolCardModel.id`, which is the message id verbatim, so an
     * unprefixed reasoning key would share a slot with that turn's card and the
     * two toggles would be one.
     */
    @Test
    fun `the key is namespaced away from the tool card key`() {
        assertNotEquals("m1", reasoningKey("m1"))
        assertEquals("reasoning-m1", reasoningKey("m1"))
    }

    @Test
    fun `two turns do not share a reasoning key`() {
        assertNotEquals(reasoningKey("m1"), reasoningKey("m2"))
    }

    /** The default the whole feature is specified around: folded. */
    @Test
    fun `a reasoning fold is collapsed until the reader opens it`() {
        val expansion = ToolExpansion()

        assertFalse(expansion.isExpanded(reasoningKey("m1")))

        expansion.toggle(reasoningKey("m1"))

        assertTrue(expansion.isExpanded(reasoningKey("m1")))
    }

    /** The header says what the web's `<summary>` says. */
    @Test
    fun `the folded header reads Thought`() {
        assertEquals("Thought", REASONING_LABEL)
    }
}
