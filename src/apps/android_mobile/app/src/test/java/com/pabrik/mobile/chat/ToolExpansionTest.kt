package com.pabrik.mobile.chat

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which cards are open. */
class ToolExpansionTest {

    @Test
    fun `an untouched card is collapsed by default`() {
        val expansion = ToolExpansion()

        assertFalse(expansion.isExpanded("row_1"))
    }

    @Test
    fun `a defaulting card is open until the reader closes it`() {
        val expansion = ToolExpansion()

        assertTrue(expansion.isExpanded("q1", defaultsToOpen = true))

        // The case a set of open ids cannot express: absent would have to mean both "inherit the default" and "explicitly closed", so an `ask_user` card would be …
        expansion.toggle("q1", defaultsToOpen = true)
        assertFalse(expansion.isExpanded("q1", defaultsToOpen = true))
    }

    @Test
    fun `a defaulting card can be reopened`() {
        val expansion = ToolExpansion()

        expansion.toggle("q1", defaultsToOpen = true)
        expansion.toggle("q1", defaultsToOpen = true)

        assertTrue(expansion.isExpanded("q1", defaultsToOpen = true))
    }

    @Test
    fun `a collapsed card toggles open`() {
        val expansion = ToolExpansion()

        expansion.toggle("row_1")

        assertTrue(expansion.isExpanded("row_1"))
    }

    @Test
    fun `one card's state is independent of another's`() {
        val expansion = ToolExpansion()

        expansion.toggle("row_1")

        assertTrue(expansion.isExpanded("row_1"))
        assertFalse(expansion.isExpanded("row_2"))
    }

    /** The saver keeps the *keys*, so after a rotation a closed defaulting card may reopen. */
    @Test
    fun `restoring keeps the cards that were open`() {
        val expansion = ToolExpansion()
        expansion.toggle("row_1")
        expansion.toggle("row_2")

        val restored = ToolExpansion.Saver.restore(
            listOf("row_1", "row_2"),
        ) ?: ToolExpansion()

        assertTrue(restored.isExpanded("row_1"))
        assertTrue(restored.isExpanded("row_2"))
        assertFalse(restored.isExpanded("row_3"))
    }
}
