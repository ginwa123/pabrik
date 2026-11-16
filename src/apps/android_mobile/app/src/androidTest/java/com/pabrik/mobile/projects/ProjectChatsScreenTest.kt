package com.pabrik.mobile.projects

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The screen behind `See all chats`. */
@RunWith(AndroidJUnit4::class)
class ProjectChatsScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L

    private fun chats(count: Int, from: Int = 1) = (from until from + count).map { index ->
        ProjectChat(
            id = "task-$index",
            projectId = "item-a",
            name = "chat $index",
            updatedAtEpochMillis = now - index * 3_600_000L,
        )
    }

    @Test
    fun theScreenListsTheProjectsChats() {
        show(page = ProjectChatsPage(chats(6), hasMore = false, nextCursor = null))

        composeTestRule.onNodeWithTag("project_chats_screen").assertIsDisplayed()
        composeTestRule.onNodeWithText("sprint board").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_chat_row_task-1").assertIsDisplayed()
    }

    @Test
    fun theFooterSaysThereIsMoreWhileTheServerSaysThereIsMore() {
        // Claiming the end while more exists is a lie the reader sees first and then watches get retracted.
        show(page = ProjectChatsPage(chats(3), hasMore = true, nextCursor = "cur"))

        composeTestRule.onNodeWithText("Scroll for older chats").assertIsDisplayed()
    }

    @Test
    fun theFooterSaysNoOlderChatsWhenTheServerHasNoMore() {
        show(page = ProjectChatsPage(chats(3), hasMore = false, nextCursor = null))

        composeTestRule.onNodeWithText("No older chats").assertIsDisplayed()
    }

    @Test
    fun scrollingToTheBottomAsksForAnotherPage() {
        var loads = 0
        show(
            page = ProjectChatsPage(chats(3), hasMore = true, nextCursor = "cur"),
            onLoadMore = { loads++ },
        )

        composeTestRule.onNodeWithTag("project_chats_list").performScrollToIndex(2)
        composeTestRule.waitForIdle()

        assert(loads > 0) { "reaching the end of a list with more must ask for it" }
    }

    @Test
    fun aProjectWithNoChatsSaysSoRatherThanShowingAnError() {
        // A fresh kanban or agent legitimately has none.
        show(page = ProjectChatsPage(emptyList(), hasMore = false, nextCursor = null))

        composeTestRule.onNodeWithTag("project_chats_empty").assertIsDisplayed()
        composeTestRule.onNodeWithText("No chats in this project yet").assertIsDisplayed()
    }

    @Test
    fun theFirstLoadSaysLoadingRatherThanNoChats() {
        // The difference between "none yet" and "not loaded yet" is the whole reason both strings exist.
        show(page = null, isLoading = true)

        composeTestRule.onNodeWithTag("project_chats_loading").assertIsDisplayed()
    }

    @Test
    fun tappingAChatOpensTheSessionTheTaskIdNames() {
        // The backend joins tasks to sessions on this id.
        var selected: String? = null
        var opened: String? = null
        show(
            page = ProjectChatsPage(chats(3), hasMore = false, nextCursor = null),
            onChatSelected = { selected = it },
            onOpenChat = { opened = it },
        )

        composeTestRule.onNodeWithTag("project_chat_row_task-2").performClick()
        composeTestRule.waitForIdle()

        assertEquals("task-2", selected)
        assertEquals("task-2", opened)
    }

    @Test
    fun theBackArrowIsReachable() {
        var backs = 0
        show(page = ProjectChatsPage(chats(2), hasMore = false, nextCursor = null), onBack = { backs++ })

        composeTestRule.onNodeWithTag("project_chats_back").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, backs)
    }

    private fun show(
        page: ProjectChatsPage?,
        isLoading: Boolean = false,
        onChatSelected: (String) -> Unit = {},
        onOpenChat: (String) -> Unit = {},
        onLoadMore: () -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                ProjectChatsScreen(
                    projectName = "sprint board",
                    page = page,
                    selectedChatId = null,
                    runningSessionIds = emptySet(),
                    isLoading = isLoading,
                    onChatSelected = onChatSelected,
                    onOpenChat = onOpenChat,
                    onLoadMore = onLoadMore,
                    nowEpochMillis = now,
                    onBack = onBack,
                )
            }
        }
    }
}
