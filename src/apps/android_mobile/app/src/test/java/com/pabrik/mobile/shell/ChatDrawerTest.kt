package com.pabrik.mobile.shell

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The chat's drawer, on the two halves CI can run without a device. */
class ChatDrawerTest {

    @Test
    fun theRouteNamesTheHighlightedChat() {
        // A deep link, or a session opened from a push, puts a chat on screen that the sidebar never marked as selected.
        assertEquals("sess_deep", chatDrawerSelectedChatId("sess_deep", "sess_from_list"))
    }

    @Test
    fun aBlankRouteFallsBackToTheListsOwnSelection() {
        // The route knows nothing here, so the list's memory is the best available answer rather than nothing at all.
        assertEquals("sess_from_list", chatDrawerSelectedChatId("", "sess_from_list"))
        assertEquals("sess_from_list", chatDrawerSelectedChatId("   ", "sess_from_list"))
    }

    @Test
    fun anUnknownRouteLeavesNoRowHighlighted() {
        assertEquals(null, chatDrawerSelectedChatId("", null))
    }

    @Test
    fun theChatRouteSuppliesTheSidebarAsItsDrawer() {
        val graph = navGraphSource()
        assertTrue(
            "the chat route has to hand ChatScreen the same drawer the shell " +
                "shows, or the hamburger opens an empty sheet",
            graph.contains("RecentsDrawerContent("),
        )
    }

    @Test
    fun theDrawerHasNoAllChatsRow() {
        // The row used to be the only in-app way off a deep-linked chat.
        val drawer = moduleSource("shell/RecentsDrawer.kt")
        assertTrue(
            "no row in the drawer may lead out of it; that is what removed the " +
                "'All chats' affordance",
            !drawer.contains("BackToChatsRow"),
        )
    }

    @Test
    fun theChatRouteClaimsTheSystemBackButton() {
        // Removing the "All chats" row removed the only in-app way out of a chat that has nothing stacked under it — a `pabrik://chat/…` link.
        val graph = navGraphSource()
        val claimsBack = Regex("BackHandler\\s*\\{\\s*goBack\\(\\)\\s*\\}").containsMatchIn(graph)
        assertTrue(
            "the chat destination must claim Back, or a deep-linked chat is a " +
                "dead end that quits the app",
            claimsBack,
        )
    }

    @Test
    fun aChatPickedFromTheChatRouteReplacesItInsteadOfStacking() {
        val graph = navGraphSource()
        // Pushing would leave a back stack with one chat entry per chat ever opened this session, so Back would walk through all of them.
        assertTrue(
            "switching chats from inside a chat must pop back to the shell " +
                "rather than stack another chat destination on top",
            graph.contains("popUpTo(PabrikRoutes.SHELL) { inclusive = false }"),
        )
    }

    @Test
    fun theChatScreenKeepsNoBackArrow() {
        val screen = chatScreenSource()
        assertTrue(
            "the back affordance was replaced by the hamburger, not merely " +
                "joined by it: an arrow on a bar whose drawer already leads " +
                "everywhere else is the control the reader reaches for first " +
                "and gets the least from",
            !screen.contains("ArrowBack"),
        )
        assertTrue(
            "the top bar must lead with the hamburger",
            screen.contains("Icons.Filled.Menu"),
        )
        assertTrue(
            "the hamburger has to open a drawer, not a local panel",
            screen.contains("ModalNavigationDrawer("),
        )
    }

    /** The module's own sources, or an error when the test runs from somewhere that cannot see them. */
    private fun navGraphSource(): String = moduleSource("network/PabrikNavGraph.kt")

    private fun chatScreenSource(): String = moduleSource("chat/ChatScreen.kt")

    private fun moduleSource(relativePath: String): String =
        sequenceOf(
            "src/main/java/com/pabrik/mobile/$relativePath",
            "app/src/main/java/com/pabrik/mobile/$relativePath",
        )
            .map(::File)
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("$relativePath not reachable from ${File(".").absolutePath}")
}
