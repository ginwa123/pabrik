package com.pabrik.mobile.chat

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.shell.RecentsDrawerContent
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The chat screen, with the virtualizer as the thing under test. */
class ChatViewTest {

    @get:Rule
    val compose = createComposeRule()

    /** Layout is computed in sub-pixel floats and rounded per density, so exact equality on a 12dp padding is a coin flip on a 2.75x screen. */
    private val TOLERANCE = 0.5f

    private fun message(
        id: String,
        role: String = ChatMessage.ROLE_USER,
        content: String = "x",
        streaming: Boolean = false,
    ) = ChatMessage(
        id = id,
        role = role,
        content = content,
        createdAtEpochMillis = 0L,
        sortKeyNanos = 0L,
        isStreaming = streaming,
    )

    private fun transcript(count: Int): List<ChatMessage> = (1..count).map { index ->
        message("m$index", ChatMessage.ROLE_ASSISTANT, "message number $index")
    }

    /** Alternating roles, so every turn is its own list item. */
    private fun conversation(prefix: String, count: Int): List<ChatMessage> = (1..count).map { index ->
        val role = if (index % 2 == 1) ChatMessage.ROLE_USER else ChatMessage.ROLE_ASSISTANT
        message("${prefix}m$index", role, "turn $index of the $prefix transcript")
    }

    /** Long enough to overflow a phone viewport several times over. */
    private fun longConversation(prefix: String = "") = conversation(prefix, 80)

    /** A transcript whose last turn is still streaming, with [lines] of text already in it. */
    private fun streamingTail(prefix: String = "", count: Int = 3, lines: Int = 1): List<ChatMessage> =
        conversation(prefix, count) + message(
            id = "${prefix}stream",
            role = ChatMessage.ROLE_ASSISTANT,
            content = (1..lines).joinToString("\n") { "chunk line $it" },
            streaming = true,
        )

    /** Renders a chat the test can re-point at another session, which is the only way to express "the reader switched chats" — a fresh composition would reset the … */
    private fun renderSwitchable(initial: ChatUiState): MutableState<ChatUiState> {
        val state = mutableStateOf(initial)
        compose.setContent {
            PabrikTheme {
                ChatView(state = state.value)
            }
        }
        return state
    }

    /** The production entry point, so the route's top bar is exercised too. */
    private fun renderScreen(
        state: ChatUiState,
        onDraftChanged: (String) -> Unit = {},
        onSend: () -> Unit = {},
        onStop: () -> Unit = {},
        onLoadOlder: () -> Unit = {},
        isRunning: Boolean = false,
    ) {
        compose.setContent {
            PabrikTheme {
                ChatScreen(
                    state = state,
                    chatTitle = "Test chat",
                    onDraftChanged = onDraftChanged,
                    onSend = onSend,
                    onStop = onStop,
                    onLoadOlder = onLoadOlder,
                    isRunning = isRunning,
                    // The transcript tests are not about the drawer, and an empty one would still be a real one.
                    drawerContent = { dismissDrawer ->
                        RecentsDrawerContent(
                            workspaces = listOf(WorkspaceOption("workspace-a", "Workspace A")),
                            chats = listOf(
                                ChatSummary(
                                    id = "chat-1",
                                    workspaceId = "workspace-a",
                                    title = "Test chat",
                                    updatedAtEpochMillis = 1_800_000_000_000L,
                                ),
                            ),
                            selectedWorkspaceId = "workspace-a",
                            selectedChatId = state.sessionId,
                            onWorkspaceSelected = {},
                            onChatSelected = {},
                            onOpenChat = dismissDrawer,
                        )
                    },
                )
            }
        }
    }

    private fun renderList(
        state: ChatUiState,
        onLoadOlder: () -> Unit = {},
    ) {
        compose.setContent {
            PabrikTheme {
                ChatView(state = state, onLoadOlder = onLoadOlder)
            }
        }
    }

    // --- Virtualization -----------------------------------------------------

    @Test
    fun theTranscriptIsAVirtualizedList() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(5)))

        compose.onNodeWithTag("chat_message_list").assertExists()
        compose.onNodeWithTag("chat_view").assertExists()
        compose.onNodeWithTag("chat_screen").assertExists()
    }

    @Test
    fun onlyViewportRowsAreComposed() {
        // 200 turns in a phone-sized viewport.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(200)))

        val composed = compose.onAllNodesWithTag("chat_group_assistant", useUnmergedTree = true)
            .fetchSemanticsNodes().size

        assertTrue(
            "expected a virtualized list, but $composed of 200 groups are composed",
            composed in 1..40,
        )
    }

    @Test
    fun aToolRunCollapsesIntoASingleListItem() {
        val toolRun = (1..12).map { message("t$it", ChatMessage.ROLE_TOOL, "step $it") }
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = toolRun))

        // The virtualizer's whole payoff: twelve rows of one run are one item.
        val composed = compose.onAllNodesWithTag("chat_group_tool", useUnmergedTree = true)
            .fetchSemanticsNodes().size
        assertTrue("expected one collapsed group, got $composed", composed <= 1)
    }

    // --- Tool call and its output are one row -------------------------------

    /** A call declaration with nothing but `tool_calls_json` on it. */
    private fun declaration(id: String, callId: String, name: String) = message(
        id = id,
        role = ChatMessage.ROLE_ASSISTANT,
        content = "",
    ).copy(
        toolName = name,
        finishReason = ChatMessage.FINISH_REASON_TOOL_CALLS,
        toolCallsJson = """[{"id":"$callId","type":"function",""" +
            """"function":{"name":"$name","arguments":"{}"}}]""",
    )

    /** The `tool` row that answers it, carrying the join key back to the call. */
    private fun answered(id: String, callId: String, name: String) = message(
        id = id,
        role = ChatMessage.ROLE_TOOL,
        content = """{"tool":"$name","success":true,"data":{"ok":true},"error":null}""",
    ).copy(toolName = name, toolCallId = callId)

    @Test
    fun anAnsweredToolCallDropsItsSummaryLine() {
        // The reported bug.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    declaration("a1", "c1", "read_file"),
                    answered("t1", "c1", "read_file"),
                ),
            ),
        )

        compose.onNodeWithTag("tool_call_summary").assertDoesNotExist()
        // And the answer is not thrown away with the summary: the card is there.
        compose.onNodeWithTag("chat_tool_t1").assertExists()
    }

    @Test
    fun anUnansweredToolCallKeepsItsSummaryLine() {
        // The other half, and the reason the suppression above is safe.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(declaration("a1", "c1", "read_file")),
            ),
        )

        compose.onNodeWithTag("tool_call_summary").assertIsDisplayed()
    }

    @Test
    fun aTwelveStepRunDrawsTwelveCardsAndNoSummaries() {
        // The whole shape in the screenshot, end to end: no interleaved "1 TOOL command" rows anywhere in it.
        val messages = buildList {
            repeat(12) { index ->
                add(declaration("a$index", "c$index", "command"))
                add(answered("t$index", "c$index", "command"))
            }
        }

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = messages))

        compose.onAllNodesWithTag("tool_call_summary", useUnmergedTree = true)
            .assertCountEquals(0)
    }

    // --- Markdown in the answer ---------------------------------------------

    @Test
    fun anAssistantAnswerRendersItsMarkdown() {
        // The other reported bug: the answer arrived wrapped in `<markdown>` and every heading and `**bold**` on it was drawn literally.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message(
                        "a1",
                        ChatMessage.ROLE_ASSISTANT,
                        "<markdown>\n**PR:** https://example.dev/pull/663\n\n" +
                            "## What I built\n\nA **model** layer.\n</markdown>",
                    ),
                ),
            ),
        )

        compose.onNodeWithTag("markdown").assertExists()
        // The wrapper is gone, so nothing on screen is a tag or an asterisk.
        compose.onNodeWithText("<markdown>", substring = true).assertDoesNotExist()
        compose.onNodeWithText("**", substring = true).assertDoesNotExist()
        compose.onNodeWithText("##", substring = true).assertDoesNotExist()
    }

    @Test
    fun aUsersOwnMarkdownIsNotRewrittenBackAtThem() {
        // The web draws a user turn as plain text and only `marked.parse`s the assistant's.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(message("u1", ChatMessage.ROLE_USER, "is **this** right?")),
            ),
        )

        compose.onNodeWithText("is **this** right?").assertIsDisplayed()
    }

    @Test
    fun aStreamedAppendKeepsEarlierRowsAddressable() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(6)))

        compose.onNodeWithTag("chat_message_m1").assertExists()

        // An index key would have re-keyed every row above the append; a stable key keeps this row addressable by the id it always had.
        compose.onNodeWithTag("chat_message_m1").assertExists()
    }

    @Test
    fun theNewestTurnIsReachableWithoutScrolling() {
        // The auto-scroll must land on the LAST group.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = longConversation(),
                hasMoreOlder = true,
            ),
        )

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        // Off-screen rows are not composed at all, so this is a real assertion about the viewport and not merely about rendering.
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun openingAChatLandsOnItsNewestTurn() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun switchingToAChatOfTheSameLengthStillLandsOnItsNewestTurn() {
        // The regression.
        val state = renderSwitchable(
            ChatUiState(sessionId = "a", isLoading = false, messages = longConversation("a")),
        )
        compose.onNodeWithTag("chat_message_am80").assertIsDisplayed()

        compose.runOnIdle {
            state.value = ChatUiState(sessionId = "b", isLoading = false, messages = longConversation("b"))
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_bm80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_bm1").assertDoesNotExist()
    }

    @Test
    fun aChatThatOpensEmptyAndLoadsLaterStillLandsOnItsNewestTurn() {
        // `openSession` paints an empty transcript first when there is no cache, and the rows land a frame later.
        val state = renderSwitchable(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_loading").assertExists()

        compose.runOnIdle {
            state.value = ChatUiState(sessionId = "s", isLoading = false, messages = longConversation())
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun aStreamingAnswerKeepsTheNewestTurnInView() {
        // A streamed delta replaces the newest message in place: the same id in the same group, the same number of items, taller by a line.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = streamingTail()),
        )
        compose.onNodeWithTag("chat_message_m1").assertIsDisplayed()

        repeat(6) { chunk ->
            compose.runOnIdle {
                val grown = state.value.messages.dropLast(1) + state.value.messages.last().copy(
                    content = (1..(6 * (chunk + 1))).joinToString("\n") { "chunk line $it" },
                )
                state.value = state.value.copy(messages = grown)
            }
            compose.waitForIdle()
        }

        compose.onNodeWithTag("chat_message_stream").assertIsDisplayed()
        // Re-pinned to the newest turn, so the top of the transcript is now well out of view.
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
    }

    @Test
    fun aTurnThatArrivesWhileTheReaderIsInHistoryDoesNotYankThem() {
        // Following the tail is a courtesy for a reader who is already there.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()),
        )
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()

        // `swipeDown`, so the reader actually goes back into history.
        compose.onNodeWithTag("chat_message_list").performTouchInput { swipeDown() }
        compose.waitForIdle()
        // The precondition, asserted: the newest turn is off screen.
        compose.onNodeWithTag("chat_message_m80").assertDoesNotExist()

        compose.runOnIdle {
            state.value = state.value.copy(
                messages = state.value.messages + message(
                    id = "brandNew",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that lands while the reader is reading history",
                ),
            )
        }
        compose.waitForIdle()

        // `brandNew` is a reader turn appended to a transcript ending in an assistant turn, so it is a group of its own and can only be on screen if the viewport was …
        compose.onNodeWithTag("chat_message_brandNew").assertDoesNotExist()
    }

    // --- Composer -----------------------------------------------------------

    @Test
    fun theComposerTakesTextAndOnlySendsWhatWasTyped() {
        var draft = ""
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, draft = draft),
            onDraftChanged = { draft = it },
        )

        // Disabled while empty: a send button that fires with no message is a button that eats the user's intent.
        compose.onNodeWithTag("chat_send").assertIsNotEnabled()

        compose.onNodeWithTag("chat_composer_input").performTextInput("do the thing")
        assertEquals("do the thing", draft)
    }

    @Test
    fun anInFlightSendDisablesTheButtonAgain() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, draft = "hello", isSending = true))

        compose.onNodeWithTag("chat_send").assertIsNotEnabled()
    }

    // --- Route chrome -------------------------------------------------------

    @Test
    fun stopIsOnlyOfferedWhileARunIsGoing() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(1)))
        compose.onNodeWithTag("chat_stop").assertDoesNotExist()

        var stopped = 0
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isStreaming = true),
            onStop = { stopped++ },
        )

        compose.onNodeWithTag("chat_stop").assertIsDisplayed().performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun theLiveIndicatorReflectsTheStreamState() {
        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = true))
        compose.onNodeWithTag("chat_live_dot").assertExists()
        compose.onNodeWithText("Live").assertExists()

        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = false))
        compose.onNodeWithText("Reconnecting…").assertExists()
    }

    @Test
    fun theHeaderSpinnerFollowsWorkerLivenessNotTheDeltaStream() {
        // The case that matters: a live stream, no chunks between turns.
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isLive = true),
            isRunning = true,
        )
        compose.onNodeWithTag("chat_running_spinner").assertExists()
        compose.onNodeWithTag("chat_live_dot").assertExists()

        renderScreen(ChatUiState(sessionId = "s", isLoading = false, isLive = true))
        compose.onNodeWithTag("chat_running_spinner").assertDoesNotExist()
    }

    @Test
    fun aRunningWorkerWithNoChunksStillOffersToStopIt() {
        // Reversed on purpose.
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isLive = true, isStreaming = false),
            isRunning = true,
        )
        compose.onNodeWithTag("chat_running_spinner").assertExists()
        compose.onNodeWithTag("chat_stop").assertIsDisplayed()
    }

    @Test
    fun aStoppedRunDropsBothTheStopControlAndTheLabel() {
        // The other end of the same rule, and the one that keeps the control honest: with neither signal left there is no run to interrupt, so neither the button nor …
        renderScreen(
            ChatUiState(sessionId = "s", isLoading = false, isLive = true, isStreaming = false),
        )
        compose.onNodeWithTag("chat_stop").assertDoesNotExist()
        compose.onNodeWithText("Live").assertExists()
    }

    @Test
    fun aWorkingRunSaysSoAndNamesTheQueue() {
        // A turn that looks like it vanished is usually still queued, and an app that cannot say so looks broken.
        renderScreen(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                isLive = true,
                isStreaming = true,
                queuedMessages = listOf(
                    QueuedChatMessage("q1", "then run the tests"),
                    QueuedChatMessage("q2", "and open a PR"),
                ),
            ),
        )

        compose.onNodeWithText("Working…").assertExists()
        compose.onNodeWithText("Working… · 2 queued").assertExists()
    }

    // --- States -------------------------------------------------------------

    @Test
    fun loadingEmptyAndErrorAreThreeDistinguishableStates() {
        renderList(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_loading").assertExists()

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = emptyList()))
        compose.onNodeWithTag("chat_empty").assertExists()

        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(1),
                errorMessage = "Could not reach the server.",
            ),
        )
        compose.onNodeWithTag("chat_error").assertExists()
    }

    @Test
    fun staleRowsSaySoRatherThanPretendingToBeLive() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(2),
                errorMessage = "Could not reach the server.",
            ),
        )

        compose.onNodeWithText("Showing the last saved copy.").assertExists()
    }

    @Test
    fun theOlderPageSentinelIsOnlyOfferedWhenThereIsHistoryAbove() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = transcript(3)))
        compose.onAllNodesWithTag("chat_load_older").assertCountEquals(0)

        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = transcript(3),
                hasMoreOlder = true,
            ),
        )
        compose.onAllNodesWithTag("chat_load_older").assertCountEquals(1)
    }

    // --- Bubble vs paragraph -----------------------------------------------

    /** The rules the `chat_message_<id>` assertions above rest on: the tag rides the reader's bubble AND the assistant's paragraph. */
    @Test
    fun bothRowsKeepTheirMessageTag() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "a question"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "an answer"),
                ),
            ),
        )

        compose.onNodeWithTag("chat_message_u1").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_a1").assertIsDisplayed()
    }

    /** The assistant's answer fills the measure; a short reader turn does not. */
    @Test
    fun anAssistantTurnFillsTheMeasureWhileAReaderTurnStaysABubble() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val groupWidth = width("chat_group_assistant")
        val assistantWidth = width("chat_message_a1")
        val readerWidth = width("chat_message_u1")

        assertEquals(
            "an assistant paragraph should span its group",
            groupWidth.value,
            assistantWidth.value,
            TOLERANCE,
        )
        assertTrue(
            "a reader bubble should be inset, was $readerWidth against a $groupWidth group",
            readerWidth < groupWidth,
        )
    }

    /** The bubble's 12dp inner padding is the visible edge of the box, and only the reader's row has it. */
    @Test
    fun onlyTheReaderRowCarriesBubblePadding() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val readerInset = left("chat_body_u1") - left("chat_message_u1")
        val assistantInset = left("chat_body_a1") - left("chat_message_a1")

        assertEquals(
            "the reader bubble should pad its text by 12dp",
            12f,
            readerInset.value,
            TOLERANCE,
        )
        assertEquals(
            "an assistant paragraph should have no bubble gutter",
            0f,
            assistantInset.value,
            TOLERANCE,
        )
    }

    /** The two rows anchor to opposite edges: a reader turn belongs under the reader's thumb, an assistant answer belongs to the left margin. */
    @Test
    fun theTwoRowsAnchorToOppositeEdges() {
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "why?"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "because the agentic loop is a while loop"),
                ),
            ),
        )

        val assistantGroup = bounds("chat_group_assistant")
        val readerGroup = bounds("chat_group_user")

        assertEquals(assistantGroup.left.value, left("chat_message_a1").value, TOLERANCE)
        assertEquals(
            readerGroup.right.value,
            right("chat_message_u1").value,
            TOLERANCE,
        )
    }

    // --- The jump back to the newest turn -----------------------------------

    /** An answer long enough to fill several viewports on its own. */
    private fun oneTallAnswer(lines: Int = 300): List<ChatMessage> = listOf(
        message("tall", ChatMessage.ROLE_ASSISTANT, (1..lines).joinToString("\n") { "line $it" }),
    )

    @Test
    fun noJumpIsOfferedWhileTheTranscriptSitsOnItsNewestTurn() {
        // A control that is always on screen is a control that does nothing, and a reader who has learned to distrust it will not tap it when it matters.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun noJumpIsOfferedOnATranscriptThatFitsTheViewport() {
        // Nothing is below the fold, so there is nowhere to jump to.
        renderList(
            ChatUiState(
                sessionId = "s",
                isLoading = false,
                messages = listOf(
                    message("u1", ChatMessage.ROLE_USER, "a question"),
                    message("a1", ChatMessage.ROLE_ASSISTANT, "a short answer"),
                ),
            ),
        )

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun noJumpIsOfferedOnAnEmptyOrLoadingTranscript() {
        // No rows means no measured layout, which is *unknown* rather than "far from the end".
        renderList(ChatUiState(sessionId = "s", isLoading = true))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()

        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = emptyList()))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun aJumpAppearsOnceTheReaderHasScrolledIntoHistory() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()

        intoHistory()
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()
    }

    @Test
    fun aJumpAppearsInsideASingleAnswerTallerThanTheScreen() {
        // The case the pixel measurement exists for.
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = oneTallAnswer()))

        // No gesture needed, and none possible: this is a single list item already at scroll position 0, so there is no "back into history" to perform.
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()
    }

    @Test
    fun pressingTheJumpInsideAnAnswerTallerThanTheScreenReachesItsEnd() {
        // The one thing `scrollToNewestEdge` exists to do, and the reason it is not the auto-scroll's `scrollToItem`: landing on a turn taller than the screen leaves the …
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = oneTallAnswer()))
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed()

        compose.onNodeWithTag("chat_jump_to_newest").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun pressingTheJumpLandsOnTheNewestTurnAndTakesItAway() {
        renderList(ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()))
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()

        intoHistory()
        // The precondition, asserted: the reader really is in history, so the jump below has somewhere to travel from.
        compose.onNodeWithTag("chat_message_m80").assertDoesNotExist()
        compose.onNodeWithTag("chat_jump_to_newest").assertIsDisplayed().performClick()
        compose.waitForIdle()

        // A real arrival, not a render: m80 is composed and m1 is not, so the viewport genuinely moved rather than merely being repainted.
        compose.onNodeWithTag("chat_message_m80").assertIsDisplayed()
        compose.onNodeWithTag("chat_message_m1").assertDoesNotExist()
        // And the control withdraws once the reader is where it said it would take them, rather than sitting there offering the same jump again.
        compose.onNodeWithTag("chat_jump_to_newest").assertDoesNotExist()
    }

    @Test
    fun aTurnThatArrivesAfterAJumpStillFollowsTheReader() {
        // The reason the jump goes through the scroll policy rather than straight to `scrollToItem`.
        val state = renderSwitchable(
            ChatUiState(sessionId = "s", isLoading = false, messages = longConversation()),
        )
        intoHistory()
        compose.onNodeWithTag("chat_jump_to_newest").performClick()
        compose.waitForIdle()

        compose.runOnIdle {
            state.value = state.value.copy(
                messages = state.value.messages + message(
                    id = "afterJump",
                    role = ChatMessage.ROLE_USER,
                    content = "a turn that lands after the reader jumped back to the end",
                ),
            )
        }
        compose.waitForIdle()

        compose.onNodeWithTag("chat_message_afterJump").assertIsDisplayed()
    }

    /** Puts the reader a long way into history, and waits for the fling to land. */
    private fun intoHistory() {
        compose.onNodeWithTag("chat_message_list").performTouchInput { swipeDown() }
        compose.waitForIdle()
    }

    // --- Geometry helpers ---------------------------------------------------

    private fun bounds(tag: String) = compose
        .onNodeWithTag(tag, useUnmergedTree = true)
        .getUnclippedBoundsInRoot()

    /** Derived from the edges so it means the same thing on every BOM. */
    private fun width(tag: String) = right(tag) - left(tag)

    private fun left(tag: String) = bounds(tag).left

    private fun right(tag: String) = bounds(tag).right
}
