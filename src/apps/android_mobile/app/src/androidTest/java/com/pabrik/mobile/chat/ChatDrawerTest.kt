package com.pabrik.mobile.chat

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.shell.RecentsDrawerContent
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The chat's top bar leads with a drawer rather than a back arrow. */
@RunWith(AndroidJUnit4::class)
class ChatDrawerTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(
        WorkspaceOption("workspace-a", "Workspace A"),
        WorkspaceOption("workspace-b", "Workspace B"),
    )
    private val chats = listOf(
        ChatSummary("chat-a1", "workspace-a", "Android drawer", now - 5L * 60_000L),
        ChatSummary("chat-a2", "workspace-a", "Release checklist", now - 2L * 60L * 60_000L),
        ChatSummary("chat-b1", "workspace-b", "Router regression", now - 3L * 24L * 60L * 60_000L),
    )

    private var pickedChatId: String? = null
    private var newChatTaps = 0
    // State, not plain fields: the sidebar re-reads these on every recomposition, and a field write would leave the drawer showing the workspace the reader just …
    private lateinit var selectedWorkspaceId: MutableState<String?>
    private lateinit var selectedChatId: MutableState<String?>
    private lateinit var recentsExpanded: MutableState<Boolean>

    /** The same drawer the shell shows, which is the shape `PabrikNavGraph` hands the screen: no header slot, and a Recents section that folds on a tap. */
    private fun showChat() {
        selectedWorkspaceId = mutableStateOf("workspace-a")
        selectedChatId = mutableStateOf("chat-a1")
        recentsExpanded = mutableStateOf(true)
        composeTestRule.setContent {
            PabrikTheme {
                ChatScreen(
                    state = ChatUiState(sessionId = "chat-a1", isLoading = false),
                    chatTitle = "Android drawer",
                    drawerContent = { dismissDrawer ->
                        RecentsDrawerContent(
                            workspaces = workspaces,
                            chats = chats,
                            selectedWorkspaceId = selectedWorkspaceId.value,
                            selectedChatId = selectedChatId.value,
                            onWorkspaceSelected = { selectedWorkspaceId.value = it },
                            onChatSelected = { pickedChatId = it },
                            onOpenChat = dismissDrawer,
                            recentsExpanded = recentsExpanded.value,
                            onToggleRecentsSection = { recentsExpanded.value = !recentsExpanded.value },
                            // The bar no longer offers its own `+`, so this is the only way to start a chat from inside one.
                            onNewChat = {
                                newChatTaps++
                                dismissDrawer()
                            },
                        )
                    },
                )
            }
        }
    }

    private fun openDrawer() {
        composeTestRule.onNodeWithTag("chat_drawer_menu").performClick()
        composeTestRule.waitForIdle()
    }

    @Test
    fun theHamburgerOpensTheRecentsDrawer() {
        showChat()

        // The back affordance is gone: a reader who came here from the list wants the list, not one more tap that returns them to where they already were.
        composeTestRule.onNodeWithTag("chat_back").assertDoesNotExist()

        openDrawer()

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun theDrawerHasNoAllChatsRow() {
        showChat()
        openDrawer()

        // The hamburger opened the list that row used to lead to, so the row would be a way to where the reader already is.
        composeTestRule.onNodeWithTag("chat_all_chats").assertDoesNotExist()
        composeTestRule.onNodeWithText("All chats").assertDoesNotExist()
    }

    @Test
    fun theRecentsHeaderFoldsTheListAndKeepsItsOwnTitle() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        // Folding hides the rows, never the section's name — otherwise the reader is left with a list of projects and no idea what was folded.
        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
        // The other section is untouched: a fold is local to its own section.
        composeTestRule.onNodeWithTag("projects_section_header").assertExists()
    }

    @Test
    fun theHighlightedRowIsWhicheverChatTheRouteNames() {
        showChat()

        // A deep link, or a session opened from a push, puts a chat on screen that the sidebar never marked as selected.
        composeTestRule.runOnIdle { selectedChatId.value = "chat-a2" }
        openDrawer()

        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsNotSelected()
    }

    @Test
    fun pickingAChatClosesTheDrawerAndReportsTheDestination() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        assertEquals("chat-a2", pickedChatId)
        // A chat is a destination, so the sheet must not stay open on top of the transcript the reader just asked for.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
    }

    @Test
    fun theTopBarOffersNoNewChatButton() {
        showChat()

        // A second entry point to a page the drawer already owns.
        composeTestRule.onNodeWithTag("chat_new_chat").assertDoesNotExist()
    }

    @Test
    fun theDrawersNewChatRowIsHowAReaderStartsAnotherChat() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("sidebar_new_chat").assertIsDisplayed()

        composeTestRule.onNodeWithTag("sidebar_new_chat").performClick()
        composeTestRule.waitForIdle()

        // One tap, one create: the graph opens the project chooser, and a row that fired twice behind it would leave two chats and no way back.
        assertEquals(1, newChatTaps)
        // The chooser is a page, so the drawer must not sit on top of it.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
    }

    @Test
    fun switchingWorkspaceRescopesTheListAndKeepsTheDrawerOpen() {
        showChat()
        openDrawer()

        composeTestRule.onNodeWithTag("workspace_dropdown").performClick()
        composeTestRule.onNodeWithTag("workspace_option_workspace-b").performClick()
        composeTestRule.waitForIdle()

        assertEquals("workspace-b", selectedWorkspaceId.value)
        // A workspace is a filter.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-b1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
    }
}
