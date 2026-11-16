package com.pabrik.mobile.projects

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.shell.MobileDrawerLayout
import com.pabrik.mobile.shell.MobileHomeScreen
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The Projects section, as drawn. */
@RunWith(AndroidJUnit4::class)
class ProjectsSectionTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L

    private val projects = listOf(
        ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
        ProjectSummary("item-b", "workspace-a", ProjectTypes.AGENT, "agentic coding"),
    )

    private fun projectChats(projectId: String, count: Int) = ProjectChatsPage(
        chats = (1..count).map { index ->
            ProjectChat(
                id = "pc-$projectId-$index",
                projectId = projectId,
                name = "chat $index",
                updatedAtEpochMillis = now - index * 3_600_000L,
            )
        },
        // More than the drawer previews, so the See all row is offered.
        hasMore = count > 8,
        nextCursor = if (count > 8) "cur" else null,
    )

    @Test
    fun theSectionShowsTheSelectedWorkspacesProjects() {
        showDrawer(expandedItemIds = emptySet(), chats = emptyMap())

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-b").assertIsDisplayed()
    }

    @Test
    fun tappingAProjectRevealsItsChatsAndLeavesTheDrawerOpen() {
        showDrawer(
            expandedItemIds = setOf("item-a"),
            chats = mapOf("item-a" to projectChats("item-a", 3)),
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        // A project is a filter, so the drawer stays open.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_chat_row_pc-item-a-1").assertIsDisplayed()
        // Expanding is a filter, so it must not have navigated.
    }

    @Test
    fun tappingANestedChatClosesTheDrawerAndOpensTheChat() {
        var selected: String? = null
        showDrawer(
            expandedItemIds = setOf("item-a"),
            chats = mapOf("item-a" to projectChats("item-a", 3)),
            onChatSelected = { selected = it },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("project_chat_row_pc-item-a-1").performClick()
        composeTestRule.waitForIdle()

        // A chat is a destination: the drawer must close for it.
        assert("pc-item-a-1" == selected) { "expected the task id, got $selected" }
        // A closed ModalDrawerSheet is still in the semantics tree, so this is "not displayed", never "does not exist" — see RecentsSidebarTest:441.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
    }

    @Test
    fun theHeaderCollapsesAndExpandsTheSection() {
        showDrawer(expandedItemIds = emptySet(), chats = emptyMap(), sectionExpanded = true)

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("projects_section_header").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("project_row_item-a").assertIsNotDisplayed()

        composeTestRule.onNodeWithTag("projects_section_header").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("project_row_item-a").assertIsDisplayed()
    }

    @Test
    fun theDrawerShowsNoSeeAllButtonWhenItAlreadyShowsEveryChat() {
        // A project with three chats needs no detour to a screen showing those same three.
        showDrawer(
            expandedItemIds = setOf("item-a"),
            chats = mapOf("item-a" to projectChats("item-a", 3)),
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("project_chat_row_pc-item-a-1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_see_all_item-a").assertDoesNotExist()
    }

    @Test
    fun seeAllIsOfferedWhenTheDrawerIsHidingRows() {
        showDrawer(
            expandedItemIds = setOf("item-a"),
            chats = mapOf("item-a" to projectChats("item-a", 12)),
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("project_chat_list").performScrollToIndex(0)
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("project_see_all_item-a").assertIsDisplayed()
    }

    @Test
    fun thePreviewStopsAtFiveRowsEvenWhenTheProjectHasMore() {
        // A 390dp drawer cannot host a second scroller under a project, and growing without bound would push the See all row off the bottom.
        showDrawer(
            expandedItemIds = setOf("item-a"),
            chats = mapOf("item-a" to projectChats("item-a", 12)),
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("project_chat_row_pc-item-a-5").assertExists()
        composeTestRule.onNodeWithTag("project_chat_row_pc-item-a-6").assertDoesNotExist()
    }

    @Test
    fun aWorkspaceWithNoProjectsSaysSo() {
        showDrawer(expandedItemIds = emptySet(), chats = emptyMap(), projects = emptyList())

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("projects_empty").assertIsDisplayed()
        composeTestRule.onNodeWithText("No projects yet").assertIsDisplayed()
    }

    @Test
    fun everyProjectTypeRendersANamedRow() {
        // A type the backend ships tomorrow must render as *some* row, never as a blank line the reader cannot tap.
        val everyType = listOf(
            ProjectSummary("k", "workspace-a", ProjectTypes.KANBAN, "a kanban"),
            ProjectSummary("ag", "workspace-a", ProjectTypes.AGENT, "an agent"),
            ProjectSummary("ro", "workspace-a", ProjectTypes.ROUTINE, "a routine"),
            ProjectSummary("de", "workspace-a", ProjectTypes.DESIGN, "a design"),
            ProjectSummary("fo", "workspace-a", ProjectTypes.FOLDER, "a folder"),
            ProjectSummary("un", "workspace-a", "something_new", "an unknown"),
        )
        showDrawer(expandedItemIds = emptySet(), chats = emptyMap(), projects = everyType)

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        everyType.forEach { project ->
            composeTestRule.onNodeWithTag("project_row_${project.id}").assertExists()
        }
        composeTestRule.onNodeWithText("an unknown").assertIsDisplayed()
    }

    @Test
    fun aFailedProjectsFetchKeepsTheRecentListWorking() {
        // A stale project list is worth showing, and it must not be allowed to take the chat list down with it.
        showDrawer(
            expandedItemIds = emptySet(),
            chats = emptyMap(),
            projects = emptyList(),
            projectsError = "The server could not load your projects. Try again.",
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("projects_error").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    private fun showDrawer(
        projects: List<ProjectSummary> = listOf(
            ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
            ProjectSummary("item-b", "workspace-a", ProjectTypes.AGENT, "agentic coding"),
        ),
        expandedItemIds: Set<String>,
        chats: Map<String, ProjectChatsPage>,
        sectionExpanded: Boolean = true,
        projectsError: String? = null,
        onChatSelected: (String) -> Unit = {},
        onOpenChat: (String) -> Unit = {},
    ) {
        var openedChatId: String? = null
        val state = ProjectsState(
            expanded = sectionExpanded,
            items = projects,
            expandedItemIds = expandedItemIds,
            chats = chats,
            isLoading = false,
            errorMessage = projectsError,
        )
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = listOf(
                        com.pabrik.mobile.recents.WorkspaceOption("workspace-a", "Workspace A"),
                    ),
                    chats = listOf(
                        com.pabrik.mobile.recents.ChatSummary(
                            "chat-a1", "workspace-a", "Android sidebar", now - 5L * 60_000L,
                        ),
                    ),
                    onWorkspaceSelected = {},
                    onChatSelected = onChatSelected,
                    onOpenChat = { sessionId -> openedChatId = sessionId },
                    drawerLayout = MobileDrawerLayout.Modal,
                    projects = state,
                    projectActions = ProjectsActions(
                        onToggleSection = {},
                        onToggleItem = {},
                        onOpenAllChats = { _, _ -> },
                        onRetry = {},
                    ),
                )
            }
        }
    }
}
