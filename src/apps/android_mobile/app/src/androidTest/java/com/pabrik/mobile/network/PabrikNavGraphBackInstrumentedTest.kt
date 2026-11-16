package com.pabrik.mobile.network

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.espresso.Espresso
import androidx.navigation.NavGraph
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pabrik.mobile.auth.AuthUiState
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.chat.ChatUiState
import com.pabrik.mobile.recents.HomeUiState
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore
import com.pabrik.mobile.ui.PabrikTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The blank screen, reproduced. */
@RunWith(AndroidJUnit4::class)
class PabrikNavGraphBackInstrumentedTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var controller: NavHostController

    private fun setUpGraph() {
        composeTestRule.setContent {
            PabrikTheme {
                controller = rememberNavController()
                TestNavGraph(navController = controller)
            }
        }
        composeTestRule.waitForIdle()
    }

    /** Leaves a leaf as the *only* destination, which is the deep-link shape. */
    private fun navigateToDeepLinkedLeaf() {
        composeTestRule.runOnUiThread {
            controller.navigate(PabrikRoutes.chat("sess_1")) {
                popUpTo(controller.graph.id) { inclusive = true }
            }
        }
        composeTestRule.waitForIdle()
        assertFalse(
            "precondition: the leaf should be the only destination",
            controller.previousBackStackEntry.let { it == null || it.destination is NavGraph },
        )
    }

    /** The chat's way out: the system Back button, which the route claims. */
    private fun leaveChatWithTheSystemBackButton() {
        composeTestRule.onNodeWithTag("chat_drawer_menu").performClick()
        composeTestRule.waitForIdle()
        Espresso.pressBack()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("sidebar_sheet").assertIsNotDisplayed()

        Espresso.pressBack()
        composeTestRule.waitForIdle()
    }

    @Test
    fun systemBackLeavesTheShellOnScreenFromASingleDestinationStack() {
        setUpGraph()
        navigateToDeepLinkedLeaf()

        leaveChatWithTheSystemBackButton()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun theInspectorBackArrowLeavesTheShellOnScreenFromASingleDestinationStack() {
        setUpGraph()
        composeTestRule.runOnUiThread {
            controller.navigate(PabrikRoutes.NETWORK) {
                popUpTo(controller.graph.id) { inclusive = true }
            }
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("network_back").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun systemBackReturnsToTheShellFromAChatPushedOverIt() {
        setUpGraph()
        composeTestRule.runOnUiThread { controller.navigate(PabrikRoutes.chat("sess_1")) }
        composeTestRule.waitForIdle()

        leaveChatWithTheSystemBackButton()

        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }

    @Test
    fun anEmptiedBackStackShowsTheRecoveryScreenRatherThanNothing() {
        setUpGraph()
        // Empty the back stack the way the inclusive pop did, and assert the graph answers it rather than leaving a bare window.
        composeTestRule.runOnUiThread {
            controller.popBackStack(controller.graph.id, inclusive = true)
        }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag("navigation_lost").assertIsDisplayed()
        composeTestRule.onNodeWithTag("navigation_lost_home").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("home_screen").assertIsDisplayed()
    }
}

/** The production graph with inert data, so the test exercises the real routes and the real back affordances rather than a stand-in for them. */
@Composable
private fun TestNavGraph(navController: NavHostController) {
    PabrikNavGraph(
        authState = AuthUiState(phase = SessionPhase.Authenticated, userId = "user_1"),
        onSignIn = { _, _ -> },
        onRetrySession = {},
        onUseAnotherAccount = {},
        navController = navController,
        homeState = HomeUiState(isLoading = false),
        chatState = MutableStateFlow(ChatUiState(sessionId = "sess_1", isLoading = false)),
        // Nothing saved: the back stack is what this file is about, and a position that resumed would navigate out from under the test.
        positionStore = NoLastPosition,
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

/** A store with nothing in it: a first launch. */
internal object NoLastPosition : LastPositionStore {
    override fun read(userId: String?): LastPosition = LastPosition()
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}

/** A store that always reports the same saved position. */
internal class FixedLastPosition(private val position: LastPosition) : LastPositionStore {
    override fun read(userId: String?): LastPosition = position
    override fun save(userId: String?, position: LastPosition) = Unit
    override fun saveWorkspace(userId: String?, workspaceId: String) = Unit
    override fun clear() = Unit
}
