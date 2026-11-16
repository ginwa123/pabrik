package com.pabrik.mobile.recents

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertContentDescriptionContains
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.projects.ProjectChat
import com.pabrik.mobile.projects.ProjectChatsPage
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

@RunWith(AndroidJUnit4::class)
class RecentsSidebarTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L
    private val workspaces = listOf(
        WorkspaceOption("workspace-a", "Workspace A"),
        WorkspaceOption("workspace-b", "Workspace B"),
    )
    private val chats = listOf(
        ChatSummary("chat-a1", "workspace-a", "Android sidebar", now - 5L * 60_000L),
        ChatSummary("chat-a2", "workspace-a", "Release checklist", now - 2L * 60L * 60_000L),
        ChatSummary("chat-b1", "workspace-b", "Router regression", now - 3L * 24L * 60L * 60_000L),
    )

    @Test
    fun opensDrawerWithWorkspaceDropdownAndRecentChats() {
        showModalScreen()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun workspaceSelectionScopesRecentsAndKeepsTheDrawerOpen() {
        var selectedWorkspaceId: String? = null
        showModalScreen(
            onWorkspaceSelected = { selectedWorkspaceId = it },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("workspace_dropdown").performClick()
        composeTestRule.onNodeWithTag("workspace_option_workspace-b").performClick()
        composeTestRule.waitForIdle()

        assertEquals("workspace-b", selectedWorkspaceId)

        // Picking a workspace is a filter, not a destination.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("workspace_menu").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_row_chat-b1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertDoesNotExist()

        // Still in the drawer, so the chat is one tap away — no second trip through the menu button.
        composeTestRule.onNodeWithTag("chat_row_chat-b1").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
        // The closed drawer is still composed, so the title also appears in its chat row.
        composeTestRule.onNodeWithTag("home_chat_title")
            .assertIsDisplayed()
            .assertTextEquals("Router regression")
    }

    @Test
    fun selectingChatUpdatesActiveRowAndClosesDrawer() {
        var selectedChatId: String? = null
        showModalScreen(
            onChatSelected = { selectedChatId = it },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsNotSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        assertEquals("chat-a2", selectedChatId)
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()
        // The closed drawer is still composed, so the title also appears in its chat row.
        composeTestRule.onNodeWithTag("home_chat_title")
            .assertIsDisplayed()
            .assertTextEquals("Release checklist")

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsNotSelected()
    }

    @Test
    fun chatListRefreshKeepsTheCurrentSelection() {
        val currentChats = androidx.compose.runtime.mutableStateOf(chats)
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = currentChats.value,
                    drawerLayout = MobileDrawerLayout.Modal,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.runOnIdle {
            currentChats.value = listOf(
                ChatSummary("chat-new", "workspace-a", "New arrival", now + 1_000L),
            ) + chats
        }

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.onNodeWithTag("chat_row_chat-new").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a2").assertIsSelected()
    }

    @Test
    fun wideLayoutShowsPermanentSidebarWithoutMenuButton() {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsDisplayed()
        composeTestRule.onNodeWithTag("sidebar_open_menu").assertDoesNotExist()
        composeTestRule.onNodeWithTag("workspace_dropdown").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
    }

    @Test
    fun onlyTheRunningChatSpins() {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("chat-a2"),
                )
            }
        }

        // chat-a1 is the selected row and idle; chat-a2 is the one with a live worker.
        composeTestRule.onNodeWithTag("chat_row_running_chat-a2").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_running_chat-a1").assertDoesNotExist()
    }

    @Test
    fun aSelectedRowKeepsItsDotWhileItIsAlsoRunning() {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    initialChatId = "chat-a1",
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("chat-a1", "chat-a2"),
                )
            }
        }

        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsSelected()
        composeTestRule.onNodeWithTag("chat_row_running_chat-a1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chat_row_running_chat-a2").assertIsDisplayed()
    }

    @Test
    fun theSpinnerFollowsTheSetRatherThanBeingSticky() {
        val running = androidx.compose.runtime.mutableStateOf(setOf("chat-a2"))
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = running.value,
                )
            }
        }
        composeTestRule.onNodeWithTag("chat_row_running_chat-a2").assertIsDisplayed()

        // The stop arrives as a worker_deleted frame and a resync, both of which land here.
        composeTestRule.runOnIdle { running.value = emptySet() }
        composeTestRule.onNodeWithTag("chat_row_running_chat-a2").assertDoesNotExist()
    }

    @Test
    fun aRunningRowSaysSoInItsOwnDescription() {
        // The spinner is decorative and carries no semantics, so the row's merged description is the only place the fact reaches a screen reader.
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("chat-a2"),
                )
            }
        }

        composeTestRule.onNodeWithTag("chat_row_chat-a2")
            .assertContentDescriptionContains("agent is working")
        // Exactly one row, so the idle rows did not inherit the phrase.
        composeTestRule.onAllNodes(describesARunningAgent).assertCountEquals(1)
    }

    private val describesARunningAgent = SemanticsMatcher("describes a running agent") { node ->
        node.config
            .getOrNull(SemanticsProperties.ContentDescription)
            ?.any { it.contains("agent is working") } == true
    }

    @Test
    fun theSidebarNamesTheAccountAndOffersToEndTheSession() {
        var logoutCalls = 0
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        // The account line is what turns "Log out" from a label into a decision: the user can see whose session they are about to end.
        composeTestRule.onNodeWithTag("sidebar_account_email")
            .assertIsDisplayed()
        composeTestRule.onNodeWithText("ada@example.com").assertIsDisplayed()

        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
    }

    @Test
    fun anOpenServerShowsNoSignOutRow() {
        // `auth_enabled=false`: the server is running without --auth, so there is no session.
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = false,
                    signedInEmail = null,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_logout").assertDoesNotExist()
        composeTestRule.onNodeWithTag("sidebar_account_divider").assertDoesNotExist()
    }

    @Test
    fun aSignOutInFlightDisablesTheRowAndSaysSo() {
        // Two presses would be two POSTs and two cache purges; the label has to admit the wait or the button looks broken on a slow connection.
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    isLoggingOut = true,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_logout").assertIsNotEnabled()
        composeTestRule.onNodeWithText("Logging out…").assertIsDisplayed()
    }

    @Test
    fun theSignOutRowSurvivesTheNoWorkspacesState() {
        // The branch that matters most: with no workspaces there is nothing to navigate to, so hiding the only route back to signing in would strand the user on a screen …
        var logoutCalls = 0
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = emptyList(),
                    chats = emptyList(),
                    drawerLayout = MobileDrawerLayout.Permanent,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_no_workspaces").assertIsDisplayed()
        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
    }

    @Test
    fun theSignOutRowIsReachableFromTheModalDrawerToo() {
        // The phone layout is the one people actually use, and it renders the sidebar through a different call site than the wide layout.
        var logoutCalls = 0
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Modal,
                    isAuthEnabled = true,
                    signedInEmail = "ada@example.com",
                    onLogout = { logoutCalls++ },
                )
            }
        }

        // Not reachable while the drawer is closed.
        composeTestRule.onNodeWithTag("sidebar_logout").assertIsNotDisplayed()

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("sidebar_logout").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, logoutCalls)
    }

    @Test
    fun bothSectionsAreNamedAndStartUnfolded() {
        showModalScreen(projects = oneProject())

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Recent").assertIsDisplayed()
        composeTestRule.onNodeWithTag("projects_section_header").assertIsDisplayed()
        composeTestRule.onNodeWithText("Projects").assertIsDisplayed()
        // Unfolded by default: a section the reader has to open before it shows anything is a section most people never open.
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_row_item-a").assertIsDisplayed()
    }

    @Test
    fun theRecentsHeaderFoldsTheChatsAndUnfoldsThemAgain() {
        // State, not a counter, because the sidebar only re-renders when the fold actually changes — which is the contract worth pinning: the composable asks, it does …
        var toggles = 0
        val recentsOpen = mutableStateOf(true)
        showModalScreen(
            projects = oneProject(),
            recentsOpen = recentsOpen,
            recentsExpanded = {
                toggles++
                recentsOpen.value = !recentsOpen.value
            },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("recents_section_header").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, toggles)
        // Folded: the rows go, the section's own title stays, and the *other* section is untouched — a fold is local to the section it belongs to.
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

    @Test
    fun theRecentsTitleStaysPutWhileTheChatsScrollUnderIt() {
        // The whole reason the header is a `stickyHeader` and not an `item`.
        val manyChats = (1..60).map { index ->
            ChatSummary(
                id = "chat-$index",
                workspaceId = "workspace-a",
                title = "Chat $index",
                updatedAtEpochMillis = now - index * 60_000L,
            )
        }
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = manyChats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                )
            }
        }

        composeTestRule.onNodeWithTag("sidebar_chat_list").performTouchInput { swipeUp() }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("recents_section_header").assertIsDisplayed()
        // Scrolled well past the first rows, so this can only be the pin.
        composeTestRule.onNodeWithTag("chat_row_chat-1").assertIsNotDisplayed()
    }

    @Test
    fun theDrawerShowsThePreviewAndOffersTheDestination() {
        showModalScreen(
            hasMoreChats = true,
            chatsTotal = 30,
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        // Both rows at once on a real device: five chats and the way past them.
        composeTestRule.onNodeWithTag("chat_row_chat-a1").assertIsDisplayed()
        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertIsDisplayed()
        composeTestRule.onNodeWithText("See all chats").assertIsDisplayed()
    }

    @Test
    fun theDestinationLeavesTheModalDrawerAndReachesNavigation() {
        // The modal drawer is the one that covers content, so a destination that did not dismiss would land the reader on the new page *underneath* the sheet they just …
        var opens = 0
        showModalScreen(
            hasMoreChats = true,
            chatsTotal = 30,
            onOpenAllChats = { opens++ },
        )

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, opens)
        // Dismissed: the sheet is gone, which is what lets the page show.
        composeTestRule.onNodeWithTag("sidebar_sheet").assertDoesNotExist()
    }

    @Test
    fun aWorkspaceWithNothingBehindThePreviewOffersNoDestination() {
        showModalScreen(hasMoreChats = false)

        composeTestRule.onNodeWithTag("sidebar_open_menu").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag(SEE_ALL_ROW_TAG).assertDoesNotExist()
    }

    /** Two projects, each with a loaded page, so the section has enough loaded to attribute a running session to a project at all — see … */
    private fun twoProjectsWithChats() = ProjectsState(
        expanded = true,
        items = listOf(
            ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
            ProjectSummary("item-b", "workspace-a", ProjectTypes.AGENT, "release bot"),
        ),
        // Folded, which is the state the report was taken in: the web lights a spinner on a *collapsed* row and this has to as well.
        expandedItemIds = emptySet(),
        chats = mapOf(
            "item-a" to ProjectChatsPage(
                chats = listOf(
                    ProjectChat("task-a1", "item-a", "first task", now),
                ),
                hasMore = false,
                nextCursor = null,
            ),
            "item-b" to ProjectChatsPage(
                chats = listOf(
                    ProjectChat("task-b1", "item-b", "second task", now),
                ),
                hasMore = false,
                nextCursor = null,
            ),
        ),
        isLoading = false,
        errorMessage = null,
    )

    @Test
    fun aProjectWithARunningChatSpinsAndTheHeaderFollows() {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("task-b1"),
                    projects = twoProjectsWithChats(),
                )
            }
        }

        // The reported gap, restated at the level the Projects section can see
        composeTestRule.onNodeWithTag("project_running_item-b").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_running_item-a").assertDoesNotExist()
        // And the header, which is the only row left on screen once every project is folded away.
        composeTestRule.onNodeWithTag("projects_section_header_running").assertIsDisplayed()
    }

    @Test
    fun aFoldedProjectLightsFromTheRecentsAlone() {
        // The gap this closes, and the state the report's screenshot was in
        val recentsWithProjects = listOf(
            chats[0].copy(projectId = "item-a"),
            chats[1].copy(projectId = "item-b"),
        )
        val foldedProjects = ProjectsState(
            expanded = true,
            items = listOf(
                ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board"),
                ProjectSummary("item-b", "workspace-a", ProjectTypes.AGENT, "release bot"),
            ),
            expandedItemIds = emptySet(),
            // Nothing loaded — both projects are folded.
            chats = emptyMap(),
            isLoading = false,
            errorMessage = null,
        )

        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = recentsWithProjects,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    // One live worker, in the project whose page was never loaded.
                    runningSessionIds = setOf("chat-a2"),
                    projects = foldedProjects,
                )
            }
        }

        composeTestRule.onNodeWithTag("project_running_item-b").assertIsDisplayed()
        composeTestRule.onNodeWithTag("project_running_item-a").assertDoesNotExist()
        composeTestRule.onNodeWithTag("projects_section_header_running").assertIsDisplayed()
    }

    @Test
    fun aRunningChatWithNoProjectLightsNoProjectRow() {
        // The case that must not be "helpfully" attributed somewhere.
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats.map { it.copy(projectId = null) },
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("chat-a2"),
                    // Same two projects, both with nothing loaded — so the recents are the only thing that could attribute a run.
                    projects = ProjectsState(
                        expanded = true,
                        items = listOf(
                            ProjectSummary(
                                "item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board",
                            ),
                            ProjectSummary(
                                "item-b", "workspace-a", ProjectTypes.AGENT, "release bot",
                            ),
                        ),
                        expandedItemIds = emptySet(),
                        chats = emptyMap(),
                        isLoading = false,
                        errorMessage = null,
                    ),
                )
            }
        }

        composeTestRule.onNodeWithTag("project_running_item-a").assertDoesNotExist()
        composeTestRule.onNodeWithTag("project_running_item-b").assertDoesNotExist()
        composeTestRule.onNodeWithTag("projects_section_header_running").assertDoesNotExist()
        // The chat row itself still spins — the recents indicator never depended on the project.
        composeTestRule.onNodeWithTag("chat_row_running_chat-a2").assertIsDisplayed()
    }

    @Test
    fun anIdleProjectsSectionLightsNothing() {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = emptySet(),
                    projects = twoProjectsWithChats(),
                )
            }
        }

        composeTestRule.onNodeWithTag("project_running_item-a").assertDoesNotExist()
        composeTestRule.onNodeWithTag("project_running_item-b").assertDoesNotExist()
        composeTestRule.onNodeWithTag("projects_section_header_running").assertDoesNotExist()
    }

    @Test
    fun aRunningProjectRowSaysSoInItsOwnDescription() {
        // The spinner is decorative, so the row's description is the only place the fact reaches a screen reader — same contract the chat rows keep.
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    drawerLayout = MobileDrawerLayout.Permanent,
                    runningSessionIds = setOf("task-b1"),
                    projects = twoProjectsWithChats(),
                )
            }
        }

        composeTestRule.onNodeWithTag("project_row_item-b")
            .assertContentDescriptionContains("agent is working")
        // Exactly one row in the whole section carries the phrase, so the idle one did not inherit it.
        composeTestRule.onAllNodes(describesARunningAgent).assertCountEquals(1)
    }

    private fun oneProject() = ProjectsState(
        expanded = true,
        items = listOf(ProjectSummary("item-a", "workspace-a", ProjectTypes.KANBAN, "sprint board")),
        expandedItemIds = emptySet(),
        chats = emptyMap(),
        isLoading = false,
        errorMessage = null,
    )

    /** The modal drawer, with the Recents fold as *state* rather than a value. */
    private fun showModalScreen(
        projects: ProjectsState = ProjectsState.Empty,
        recentsOpen: MutableState<Boolean> = mutableStateOf(true),
        recentsExpanded: () -> Unit = {},
        onWorkspaceSelected: (String) -> Unit = {},
        onChatSelected: (String) -> Unit = {},
        hasMoreChats: Boolean = false,
        chatsTotal: Int = 0,
        onOpenAllChats: () -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                MobileHomeScreen(
                    workspaces = workspaces,
                    chats = chats,
                    onWorkspaceSelected = onWorkspaceSelected,
                    onChatSelected = onChatSelected,
                    drawerLayout = MobileDrawerLayout.Modal,
                    hasMoreChats = hasMoreChats,
                    chatsTotal = chatsTotal,
                    onOpenAllChats = onOpenAllChats,
                    projects = projects,
                    projectActions = ProjectsActions(
                        onToggleSection = {},
                        onToggleItem = {},
                        onOpenAllChats = { _, _ -> },
                        onRetry = {},
                    ),
                    recentsExpanded = recentsOpen.value,
                    onToggleRecentsSection = recentsExpanded,
                )
            }
        }
    }
}
