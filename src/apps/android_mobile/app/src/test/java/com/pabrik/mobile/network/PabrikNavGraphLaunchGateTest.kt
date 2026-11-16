package com.pabrik.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
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
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The launch gate, against the real `NavHost` — and on the JVM. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PabrikNavGraphLaunchGateTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    @Test
    fun aResumedChatStaysBehindTheGateUntilItsTranscriptLands() {
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            // A cold open: the route is on the back stack and the first page has not arrived.
            chatState = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = true)),
        )

        // The navigation has already happened.
        composeTestRule.onNodeWithTag("chat_title").assertTextEquals("Chat sess_c")
        composeTestRule.onNodeWithTag("launch_gate").assertIsDisplayed()
    }

    @Test
    fun theGateLiftsOnceTheResumedTranscriptHasLanded() {
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            // Loaded, and nothing to scroll because the transcript is empty — which is also what a failed load looks like, and a gate that waited for a scroll in that case …
            chatState = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = false)),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_drawer_menu").assertIsDisplayed()
    }

    @Test
    fun aFirstLaunchRevealsTheShellWithoutAnyChat() {
        // Nothing to resume is an *answer*, not a wait.
        launch(saved = LastPosition())

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSavedChatTheListNoLongerHasStillRevealsTheShell() {
        // The answer is "no", for a reason.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_deleted"),
            homeState = settledHome(chats = listOf(chat("sess_a"), chat("sess_c"))),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun aSignInScreenIsNeverCovered() {
        // The gate blocks by being opaque, and a gate over the sign-in form is an app nobody can get into.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(phase = SessionPhase.NeedsLogin),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    @Test
    fun theChatIsOpenedOnceAndLeavesTheShellUnderneathIt() {
        val opened = mutableListOf<String>()
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            onOpenSession = { opened += it },
        )

        // A second chat route for the same session is a second copy of the chat under Back, and it is invisible until someone presses Back twice.
        assertEquals(listOf("sess_c"), opened)
        // The shell still underneath says the resume *pushed* a route rather than replacing the whole stack, which would have left the reader with nowhere to go.
        assertEquals(
            PabrikRoutes.SHELL,
            controller.previousBackStackEntry?.destination?.route,
        )
    }

    @Test
    fun aRestoringLaunchScreenIsNotCoveredByASecondOne() {
        // The shell already paints `AuthRestoringScreen` in this phase.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(phase = SessionPhase.Restoring),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    @Test
    fun aRetryScreenIsNeverCovered() {
        // "Try again" and "Sign in" are the only way out of a rejected cookie.
        launch(
            saved = LastPosition(workspaceId = "ws_b", sessionId = "sess_c"),
            authState = AuthUiState(
                phase = SessionPhase.NeedsRetry,
                errorMessage = "Cannot reach the server",
            ),
        )

        composeTestRule.onNodeWithTag("launch_gate").assertDoesNotExist()
    }

    private fun launch(
        saved: LastPosition,
        homeState: HomeUiState = settledHome(),
        authState: AuthUiState = AuthUiState(
            phase = SessionPhase.Authenticated,
            userId = "user_1",
        ),
        onOpenSession: (String) -> Unit = {},
        chatState: StateFlow<ChatUiState> = MutableStateFlow(ChatUiState(sessionId = "sess_c", isLoading = false)),
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                GateGraph(
                    navController = controller,
                    homeState = homeState,
                    positionStore = FixedLastPosition(saved),
                    authState = authState,
                    onOpenSession = onOpenSession,
                    chatState = chatState,
                )
            }
        }
        composeTestRule.waitForIdle()
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

/** A store that answers one position and records nothing. */
internal class FixedLastPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}

/** The production graph, so the test drives the real effect and the real routes. */
@Composable
private fun GateGraph(
    navController: NavHostController,
    homeState: HomeUiState,
    positionStore: LastPositionStore,
    authState: AuthUiState,
    onOpenSession: (String) -> Unit,
    chatState: StateFlow<ChatUiState>,
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
