package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Grouping is what makes the transcript genuinely virtualized: a long tool run is dozens of rows that would otherwise be dozens of `LazyColumn` items, each … */
class GroupMessagesTest {

    private fun message(
        id: String,
        role: String = ChatMessage.ROLE_USER,
        content: String = "x",
        streaming: Boolean = false,
    ) = ChatMessage(
        id = id,
        role = role,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        isStreaming = streaming,
    )

    @Test
    fun `consecutive same-role turns collapse into one item`() {
        val groups = groupMessages(
            listOf(
                message("u1", ChatMessage.ROLE_USER),
                message("u2", ChatMessage.ROLE_USER),
                message("a1", ChatMessage.ROLE_ASSISTANT),
            ),
        )

        assertEquals(2, groups.size)
        assertEquals(listOf("u1", "u2"), groups[0].messages.map { it.id })
        assertEquals(listOf("a1"), groups[1].messages.map { it.id })
    }

    @Test
    fun `a role change starts a new group`() {
        val groups = groupMessages(
            listOf(
                message("a1", ChatMessage.ROLE_ASSISTANT),
                message("t1", ChatMessage.ROLE_TOOL),
                message("t2", ChatMessage.ROLE_TOOL),
                message("a2", ChatMessage.ROLE_ASSISTANT),
            ),
        )

        assertEquals(3, groups.size)
        assertEquals(2, groups[1].messages.size)
    }

    @Test
    fun `the group key is the first message id, never the index`() {
        // An index key re-keys every row above an append, which throws away per-item state — expanded tool cards, for one — and re-composes the whole list on every …
        val before = groupMessages(
            listOf(
                message("a", ChatMessage.ROLE_USER),
                message("b", ChatMessage.ROLE_ASSISTANT),
            ),
        )
        val after = groupMessages(
            listOf(
                message("a", ChatMessage.ROLE_USER),
                message("b", ChatMessage.ROLE_ASSISTANT),
                message("c", ChatMessage.ROLE_USER),
            ),
        )

        assertEquals(listOf("a", "b"), before.map { it.key })
        // The append adds a group; it does not renumber the ones above it, which is exactly what an index key would do.
        assertEquals(listOf("a", "b"), after.take(before.size).map { it.key })
        assertEquals(3, after.size)
    }

    @Test
    fun `keys are unique across a group list`() {
        val groups = groupMessages(
            listOf(
                message("a1", ChatMessage.ROLE_USER),
                message("u1", ChatMessage.ROLE_USER),
                message("a1b", ChatMessage.ROLE_USER),
            ),
        )
        assertEquals(groups.size, groups.map { it.key }.toSet().size)
    }

    @Test
    fun `a group with nothing to draw is dropped before the list sees it`() {
        // An item with no content still occupies the virtualizer's height estimate, so leaving one in leaves a blank band in the viewport and the auto-scroll lands short …
        val groups = groupMessages(
            listOf(
                message("visible", content = "here"),
                message("blank", content = "   "),
            ),
        )

        assertEquals(listOf("visible"), groups.map { it.key })
    }

    @Test
    fun `a group is kept when only an attachment or a tool name is renderable`() {
        val withToolName = message("t", ChatMessage.ROLE_TOOL, content = "")
            .copy(toolName = "command")
        val withImage = message("i", ChatMessage.ROLE_ASSISTANT, content = "")
            .copy(imageUrls = listOf("data:image/png;base64,AAA"))

        assertEquals(1, groupMessages(listOf(withToolName)).size)
        assertEquals(1, groupMessages(listOf(withImage)).size)
    }

    @Test
    fun `a streaming placeholder is never glued to the turn above it`() {
        val groups = groupMessages(
            listOf(
                message("u1", ChatMessage.ROLE_USER),
                message("streaming-1", ChatMessage.ROLE_ASSISTANT, content = "parti", streaming = true),
                message("s2", ChatMessage.ROLE_ASSISTANT, content = "more", streaming = true),
            ),
        )

        // Its own key, its own item, so the growing text does not re-key the user's message above it.
        val streamingGroups = groups.filter { group -> group.messages.any { it.isStreaming } }
        assertEquals(2, streamingGroups.size)
        assertNotEquals(groups.first().key, streamingGroups.first().key)
    }

    @Test
    fun `an empty transcript produces no groups rather than one empty item`() {
        assertTrue(groupMessages(emptyList()).isEmpty())
    }
}
