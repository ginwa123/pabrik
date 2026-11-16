package com.pabrik.mobile.network

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatMessage
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The chat route has to *observe* the transcript, not be handed a sample of it. */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w390dp-h844dp")
class PabrikNavGraphChatStateTest {

    @get:Rule
    val compose = createComposeRule()

    private val chatState = MutableStateFlow(ChatUiState(sessionId = "sess_1", isLoading = false))

    /** The production graph, resumed straight onto the chat route. */
    private fun renderChatRoute() {
        compose.setContent {
            PabrikTheme {
                val controller: NavHostController = rememberNavController()
                GraphWithChatState(
                    navController = controller,
                    chatState = chatState,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun theRouteStartsOnTheChatTheResumeOpened() {
        // The precondition every other test here rests on: without this, a failing assertion below could just be a route that never opened.
        renderChatRoute()

        compose.onNodeWithTag("chat_title").assertIsDisplayed()
        compose.onNodeWithTag("chat_composer_input").assertIsDisplayed()
    }

    @Test
    fun anEmissionReachesTheChatAlreadyOnScreen() {
        renderChatRoute()

        // This is the whole bug in one line.
        chatState.value = chatState.value.copy(
            messages = listOf(
                ChatMessage(
                    id = "m1",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that arrived live",
                    createdAtEpochMillis = 1_800_000_000_000L,
                    sortKeyNanos = 1_800_000_000_000_000_000L,
                ),
            ),
        )
        compose.waitForIdle()

        compose.onNodeWithText("a turn that arrived live").assertIsDisplayed()
    }

    @Test
    fun aDraftEmissionReachesTheComposerAlreadyOnScreen() {
        renderChatRoute()

        // Typing is the reported symptom, and it is the one emission with no second source: nothing else in the tree changes when a keystroke is written to the draft.
        chatState.value = chatState.value.copy(draft = "hello")
        compose.waitForIdle()

        compose.onNodeWithText("hello").assertIsDisplayed()
    }

    @Test
    fun anErrorEmissionReachesTheBannerAlreadyOnScreen() {
        renderChatRoute()

        chatState.value = chatState.value.copy(errorMessage = "the send did not land")
        compose.waitForIdle()

        compose.onNodeWithText("the send did not land").assertIsDisplayed()
    }
}

/** The production graph, so the test drives the real destination and the real resume. */
@androidx.compose.runtime.Composable
private fun GraphWithChatState(
    navController: NavHostController,
    chatState: StateFlow<ChatUiState>,
) {
    PabrikNavGraph(
        authState = AuthUiState(phase = SessionPhase.Authenticated, userId = "user_a"),
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = HomeUiState(
            isLoading = false,
            workspaces = listOf(WorkspaceOption("ws_a", "One")),
            selectedWorkspaceId = "ws_a",
            chats = listOf(
                ChatSummary(
                    id = "sess_1",
                    workspaceId = "ws_a",
                    title = "Chat sess_1",
                    updatedAtEpochMillis = 1_000L,
                ),
            ),
            selectedChatId = "sess_1",
        ),
        chatState = chatState,
        positionStore = FixedPosition(LastPosition(workspaceId = "ws_a", sessionId = "sess_1")),
        onSelectWorkspace = {},
        onSelectChat = {},
        onRetryHome = {},
        onOpenSession = {},
        onChatDraftChanged = {},
        onSendChatMessage = {},
        onStopChatRun = {},
        onLoadOlderChatMessages = {},
        onDismissChatError = {},
        onAnswerChatQuestion = {},
    )
}

/** A store that answers one position and records nothing. */
private class FixedPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}
