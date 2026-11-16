package com.pabrik.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.espresso.Espresso
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** "Close the app, open it again, and it is where I was" — against a real `NavController`. */
@RunWith(AndroidJUnit4::class)
class PabrikNavGraphResumeInstrumentedTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    private fun launch(
        saved: LastPosition,
        homeState: HomeUiState = settledHome(),
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = homeState,
                    positionStore = FixedLastPosition(saved),
                )
            }
        }
        composeTestRule.waitForIdle()
    }

    @Test
    fun aRelaunchOpensTheSavedChat() {
        launch(LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        // The title bar, not `currentDestination.route`: a destination's route is the *pattern* it was declared with, so it reads `chat/{sessionId}` for every chat the …
        composeTestRule.onNodeWithTag("chat_title").assertTextEquals("Chat sess_c")
        // The chat's way out is the hamburger's drawer, not an arrow.
        composeTestRule.onNodeWithTag("chat_drawer_menu").assertIsDisplayed()
    }

    @Test
    fun theResumeOpensTheSessionBeforeItNavigates() {
        // Otherwise Back lands on a chat route whose transcript was never requested, and the user gets an empty screen with a title and no explanation — the same failure …
        val opened = mutableListOf<String>()
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    onOpenSession = { opened += it },
                )
            }
        }
        composeTestRule.waitForIdle()

        assertEquals(listOf("sess_c"), opened)
    }

    @Test
    fun backFromAResumedChatReturnsToTheShell() {
        launch(LastPosition(workspaceId = "ws_b", sessionId = "sess_c"))

        // The chat route's way home: the system Back button, claimed by the destination so it works from a resumed deep link where the shell was never pushed.
        Espresso.pressBack()
        composeTestRule.waitForIdle()

        // A `popUpTo` here would drop the shell and put the user on the recovery screen, or nowhere at all.
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aFirstLaunchStaysOnTheShell() {
        launch(LastPosition())

        assertEquals(PabrikRoutes.SHELL, controller.currentDestination?.route)
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSavedChatTheListNoLongerHasIsNotOpened() {
        launch(
            LastPosition(workspaceId = "ws_b", sessionId = "sess_deleted"),
            homeState = settledHome(chats = listOf(chat("sess_a"), chat("sess_c"))),
        )

        // Opening a route whose session is gone gives an empty transcript, and the shell is the truthful answer.
        assertEquals(PabrikRoutes.SHELL, controller.currentDestination?.route)
    }

    @Test
    fun nothingIsRestoredBeforeTheSessionIsAuthenticated() {
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    authState = AuthUiState(phase = SessionPhase.NeedsLogin),
                )
            }
        }
        composeTestRule.waitForIdle()

        // A chat opened here would 401, and a 401 signs the user out of an app they were only ever trying to log into.
        assertEquals(PabrikRoutes.SHELL, controller.currentDestination?.route)
    }

    @Test
    fun theChatIsOpenedOnceNotOncePerRecomposition() {
        val opened = mutableListOf<String>()
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    onOpenSession = { opened += it },
                )
            }
        }
        composeTestRule.waitForIdle()

        // A second chat route for the same session is a second copy of the chat under Back, and it is invisible until someone presses Back twice.
        assertEquals(1, opened.size)
        composeTestRule.onNodeWithTag("chat_title").assertTextEquals("Chat sess_c")
        assertTrue(
            "the shell must still be under the chat",
            controller.previousBackStackEntry?.destination?.route == PabrikRoutes.SHELL,
        )
    }

    @Test
    fun theChatStaysBehindTheGateUntilItsTranscriptLands() {
        // A cold open: the route is on the back stack and the first page has not arrived.
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    chatState = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = true)),
                )
            }
        }
        composeTestRule.waitForIdle()

        // The navigation has already happened.
        composeTestRule.onNodeWithTag("chat_title").assertTextEquals("Chat sess_c")
        composeTestRule.onNodeWithTag("launch_gate").assertIsDisplayed()
    }

    @Test
    fun theGateLiftsOnceTheResumedTranscriptHasLanded() {
        // The other half of the pair, and the one a test written only for the gate being up would pass without: a gate that never lifts is a splash with no way out of it.
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                )
            }
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_drawer_menu").assertIsDisplayed()
    }

    @Test
    fun aFirstLaunchRevealsTheShellWithoutAnyChat() {
        // Nothing to resume is an answer, not a wait.
        launch(LastPosition())

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    @Test
    fun aSignInScreenIsNeverCovered() {
        // The gate blocks by being opaque, and a gate over the sign-in form is an app nobody can get into.
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                ResumeGraph(
                    navController = controller,
                    homeState = settledHome(),
                    positionStore = FixedLastPosition(
                        LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
                    ),
                    authState = AuthUiState(phase = SessionPhase.NeedsLogin),
                )
            }
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    private fun settledHome(chats: List<ChatSummary> = listOf(chat("sess_a"), chat("sess_c"))) =
        HomeUiState(
            isLoading = false,
            workspaces = listOf(WorkspaceOption("ws_b", "Two")),
            selectedWorkspaceId = "ws_b",
            chats = chats,
            selectedChatId = chats.firstOrNull()?.id,
        )

    private fun chat(id: String) = ChatSummary(
        id = id,
        workspaceId = "ws_b",
        title = "Chat $id",
        updatedAtEpochMillis = 1_000L,
    )
}

/** The production graph, so the test drives the real effect and the real routes. */
@Composable
private fun ResumeGraph(
    navController: NavHostController,
    homeState: HomeUiState,
    positionStore: LastPositionStore,
    authState: AuthUiState = AuthUiState(
        phase = SessionPhase.Authenticated,
        userId = "user_1",
    ),
    onOpenSession: (String) -> Unit = {},
    /** The transcript the chat route paints. */
    chatState: StateFlow<ChatUiState> = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = false)),
) {
    PabrikNavGraph(
        authState = authState,
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = homeState,
        chatState = chatState,
        positionStore = positionStore,
        onSelectWorkspace = {},
        onSelectChat = {},
        onRetryHome = {},
        onOpenSession = onOpenSession,
        onChatDraftChanged = {},
        onSendChatMessage = {},
        onStopChatRun = {},
        onLoadOlderChatMessages = {},
        onDismissChatError = {},
        onAnswerChatQuestion = {},
    )
}
