package com.pabrik.mobile.chat

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** The document turn, on a device. */
class HtmlDocumentViewTest {

    @get:Rule
    val compose = createComposeRule()

    /** The reported session: a `web-framework-html-benchmark` turn, which arrives wrapped and opens with a stylesheet. */
    private val benchmarkTurn =
        "<html><head><style>.bmw-wrap{background:#1D1C19;color:#c5c9c5}</style></head>" +
            "<body><main class=\"bmw-wrap\"><h1>BMW M4 Competition</h1></main></body></html>"

    private fun show(content: String, streaming: Boolean = false) {
        val message = mutableStateOf(
            ChatMessage(
                id = "m1",
                role = ChatMessage.ROLE_ASSISTANT,
                content = content,
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                isStreaming = streaming,
            ),
        )
        // `setContent` may be called once per rule, so the turn is held in state and swapped in place — the same thing the SSE stream does to a live turn, which is the …
        compose.setContent {
            PabrikTheme {
                ChatView(
                    state = ChatUiState(
                        sessionId = "s1",
                        isLoading = false,
                        messages = listOf(message.value),
                    ),
                )
            }
        }
    }

    private fun frameCount(): Int =
        compose.onAllNodesWithTag("chat_html_frame").fetchSemanticsNodes().size

    @Test
    fun aDocumentTurnIsDrawnInAFrame() {
        show(benchmarkTurn)

        compose.onNodeWithTag("chat_html_frame").assertIsDisplayed()
    }

    @Test
    fun aDocumentTurnDoesNotShowItsOwnSource() {
        // The screenshot this replaces: the transcript showed the reader the literal `<style>bmw-wrap{font-family:ui-sans-system…` instead of the page.
        show(benchmarkTurn)

        compose.onNodeWithText("bmw-wrap{font-family", substring = true)
            .assertDoesNotExist()
    }

    @Test
    fun aDocumentTurnKeepsTheProseAroundIt() {
        show("Here is the page.\n$benchmarkTurn")

        compose.onNodeWithText("Here is the page.").assertIsDisplayed()
        compose.onNodeWithTag("chat_html_frame").assertIsDisplayed()
    }

    @Test
    fun anOrdinaryAnswerDrawsNoFrame() {
        show("## What I built\n\nMoved the card.")

        compose.onNodeWithTag("chat_html_frame").assertDoesNotExist()
        compose.onNodeWithTag("markdown").assertIsDisplayed()
    }

    @Test
    fun aDocumentStillStreamingDrawsNoFrame() {
        // The per-delta cost this guards.
        show("<html><body><main><h1>Half a pag", streaming = true)

        assertEquals(0, frameCount())
    }

    @Test
    fun theSameTurnDrawsAFrameOnceItStopsStreaming() {
        val live = mutableStateOf(
            ChatMessage(
                id = "m1",
                role = ChatMessage.ROLE_ASSISTANT,
                content = "<html><body><main><h1>Half a pag",
                createdAtEpochMillis = 0L,
                sortKeyNanos = 0L,
                isStreaming = true,
            ),
        )
        compose.setContent {
            PabrikTheme {
                ChatView(
                    state = ChatUiState(
                        sessionId = "s1",
                        isLoading = false,
                        messages = listOf(live.value),
                    ),
                )
            }
        }
        assertEquals(0, frameCount())

        // The turn finishes: the same row, the same id, no longer streaming.
        live.value = live.value.copy(
            content = "<html><body><main><h1>Half a page</h1></main></body></html>",
            isStreaming = false,
        )
        compose.waitForIdle()

        assertEquals(1, frameCount())
    }

    @Test
    fun pastTheFrameBudgetTheRestFallsBackToText() {
        val blocks = (1..HtmlResponse.MAX_LIVE_FRAMES + 1).joinToString("") {
            "<html><body><h1>Block $it</h1></body></html>"
        }
        show(blocks)

        // Three frames, not four.
        assertEquals(HtmlResponse.MAX_LIVE_FRAMES, frameCount())
    }
}
