package com.pabrik.mobile.recents

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import com.pabrik.mobile.projects.ProjectSummary
import com.pabrik.mobile.projects.ProjectTypes
import com.pabrik.mobile.projects.ProjectsActions
import com.pabrik.mobile.projects.ProjectsState
import com.pabrik.mobile.shell.MobileDrawerLayout
import com.pabrik.mobile.shell.MobileHomeScreen
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The sidebar's two sections, on the JVM. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class RecentsSidebarSectionsTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(WorkspaceOption("workspace-a", "Workspace A"))
    private val chats = (1..3).map { index ->
        ChatSummary("chat-a$index", "workspace-a", "Chat $index", now - index * 60_000L)
    }

    private fun oneProject() = ProjectsState(
        expanded = true,
        items = listOf(
            ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
        ),
        expandedItemIds = emptySet(),
        chats = emptyMap(),
        isLoading = false,
        errorMessage = null,
    )

    /** The recents fold is passed as *state*, for the reason it always was: a test that folds the section has to fold it without composing the drawer twice, and … */
    private fun showDrawer(
        chats: List<ChatSummary> = this.chats,
        projects: ProjectsState = oneProject(),
        recentsOpen: MutableState<Boolean> = mutableStateOf(true),
        onToggleRecents: () -> Unit = {},
        hasMoreChats: Boolean = false,
        chatsTotal: Int = 0,
        onOpenAllChats: () -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    projects = projects,
                    projectActions = ProjectsActions(
                        onToggleSection = {},
                        onToggleItem = {},
                        onOpenAllChats = { _, _ -> },
                        onRetry = {},
                    ),
                    recentsExpanded = recentsOpen.value,
                    onToggleRecentsSection = onToggleRecents,
                    hasMoreChats = hasMoreChats,
                    chatsTotal = chatsTotal,
                    onOpenAllChats = onOpenAllChats,
                )
            }
        }
    }

    @Test
    fun bothSectionsAreNamedAndStartUnfolded() {
        showDrawer()

        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Projects").assertIsDisplayed()

        // Unfolded by default: a section the reader has to open before it shows anything is a section most people never open.
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertIsDisplayed()
    }

    @Test
    fun theDrawerHasNoAllChatsRow() {
        showDrawer()

        // The hamburger opens the list that row used to lead to, so the row was a second route to where the reader already stands.
        composeTestRule.onNodeWithText("All chats").assertDoesNotExist()
    }

    @Test
    fun theRecentsHeaderFoldsTheChatsAndFoldsThemBackOut() {
        var toggles = 0
        val recentsOpen = mutableStateOf(true)
        showDrawer(
            recentsOpen = recentsOpen,
            onToggleRecents = {
                toggles++
                recentsOpen.value = !recentsOpen.value
            },
        )

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, toggles)
        // Folded: the rows go, the section's own title stays, and the *other* section is untouched — a fold belongs to its own section only.
        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertExists()

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        assertEquals(2, toggles)
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    // The *recents* pin has no test here, and that is a fact about the design rather than an omission.

    @Test
    fun theProjectsTitlePinsWhileItsOwnRowsScrollUnderIt() {
        // One chat, so the list is short enough that scrolling lands inside the projects section — which is the only place the second pin shows.
        showDrawer(chats = manyChats(1))

        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(2)
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertExists()
    }

    // ── The preview, and the button behind it ─────────────────────────

    @Test
    fun theDrawerShowsThePreviewRows() {
        showDrawer(chats = manyChats(30), hasMoreChats = true)

        composeTestRule.onNodeWithTag("chat_row_chat-5").assertIsDisplayed()
        // Absent, not merely off-screen: a lazy list composes only what it has been scrolled to, so "exists" after a scroll is the claim — and finding it needs the same …
        composeTestRule.onNodeWithTag("sidebar_chat_list").performScrollToIndex(7)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("chat_row_chat-6").assertDoesNotExist()
    }

    @Test
    fun theDestinationRowSaysSeeAllChatsAndCarriesNoCount() {
        showDrawer(chats = manyChats(30), hasMoreChats = true)

        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertIsDisplayed()
        composeTestRule.onNodeWithText("See all chats").assertIsDisplayed()
        // Same rule as the project's row, for the same reason: the page behind it is what has the honest number, and a count here is a second place for it to go stale.
        composeTestRule.onNodeWithText("See 25 more chats").assertDoesNotExist()
    }

    @Test
    fun theDestinationRowLeavesTheDrawer() {
        var opens = 0
        showDrawer(
            chats = manyChats(30),
            hasMoreChats = true,
            onOpenAllChats = { opens++ },
        )

        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).performClick()
        composeTestRule.waitForIdle()

        // A destination, not a toggle: the tap has to reach the navigation and nothing else.
        assertEquals(1, opens)
        composeTestRule.onNodeWithText("Show fewer").assertDoesNotExist()
    }

    @Test
    fun aWorkspaceWithNothingBehindThePreviewOffersNoRow() {
        // Three chats, the server said there is no more: a button here opens a page holding the same three rows, which is a detour dressed as a destination.
        showDrawer(chats = manyChats(3), hasMoreChats = false)

        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_row_chat-3").assertIsDisplayed()
    }

    @Test
    fun aStaleRefreshThatNeverGotPastThePreviewOffersNoRow() {
        // Cached rows plus a refresh the server never answered.
        showDrawer(chats = manyChats(5), hasMoreChats = false)

        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertDoesNotExist()
    }

    @Test
    fun theHeaderCountsEveryChatRatherThanTheOnesOnScreen() {
        showDrawer(chats = manyChats(30), hasMoreChats = true, chatsTotal = 30)

        // The count is the only summary the section has, so it has to be the number of chats in the workspace — not the five the drawer holds.
        composeTestRule.onNodeWithTag("recents_section_header")
            .assertContentDescriptionEquals("Recent. 30 chats in this workspace")
    }

    @Test
    fun theHeaderFallsBackToTheRowsWhenTheServerSentNoCount() {
        showDrawer(chats = manyChats(3), hasMoreChats = false)

        // An older server reports no `total`.
        composeTestRule.onNodeWithTag("recents_section_header")
            .assertContentDescriptionEquals("Recent. 3 chats in this workspace")
    }

    @Test
    fun thereIsNoPagingFooterAndNothingToScrollFor() {
        showDrawer(chats = manyChats(30), hasMoreChats = true)

        // "Scroll for older chats" promised a request this drawer does not make: the pages live on the destination page, behind the row above.
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
        composeTestRule.onNodeWithText("Scroll for older chats").assertDoesNotExist()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
    }

    @Test
    fun aFoldedSectionOffersNoDestination() {
        // A fold is a fold: the section's rows go, and so does the row that leaves the drawer.
        showDrawer(
            chats = manyChats(30),
            recentsOpen = mutableStateOf(false),
            hasMoreChats = true,
        )

        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertDoesNotExist()
    }

    private fun manyChats(count: Int) = (1..count).map { index ->
        ChatSummary(
            id = "chat-$index",
            workspaceId = "workspace-a",
            title = "Chat $index",
            updatedAtEpochMillis = now - index * 60_000L,
        )
    }
}
