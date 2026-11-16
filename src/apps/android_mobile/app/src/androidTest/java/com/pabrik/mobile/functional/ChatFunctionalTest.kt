package com.pabrik.mobile.functional

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pabrik.mobile.BuildConfig
import com.pabrik.mobile.MainActivity
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith

/** The phone, rendering rows it did not invent. */
@RunWith(AndroidJUnit4::class)
class ChatFunctionalTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private val composeRule: ComposeTestRule = createEmptyComposeRule()

    @get:Rule
    val chain: TestRule = RuleChain.outerRule(ClearAppStateRule(context)).around(composeRule)

    private var launched: ActivityScenario<MainActivity>? = null

    /** Refuse to run against anything but a local server. */
    @Before
    fun requireALocalServer() {
        val base = BuildConfig.API_BASE_URL
        assertTrue(
            "this suite must run against a local pabrik, but the APK was built " +
                "with API_BASE_URL=$base — pass " +
                "-PpabrikBaseUrl=http://10.0.2.2:<port> to Gradle",
            base.startsWith("http://"),
        )
    }

    @After
    fun closeTheApp() {
        launched?.close()
        launched = null
    }

    // ─── the scenarios ─────────────────────────────────────────────────────

    @Test
    fun empty() {
        open(FunctionalScenario.EMPTY)

        assertPresent("chat_empty")
    }

    @Test
    fun exchange() {
        open(FunctionalScenario.EXCHANGE)

        assertPresent("chat_message_${FunctionalScenario.EXCHANGE_USER}")
        assertPresent("chat_message_${FunctionalScenario.EXCHANGE_ASSISTANT}")
    }

    @Test
    fun multiturn() {
        open(FunctionalScenario.MULTITURN)

        // The tail, not the head: the list is virtualized, and the transcript scrolls to the newest turn, so the first exchange is legitimately not composed.
        assertPresent("chat_message_${FunctionalScenario.MULTITURN_IDS.last()}")
        assertTrue(
            "the transcript composed no assistant group at all",
            nodes("chat_group_assistant").fetchSemanticsNodes().isNotEmpty(),
        )
    }

    @Test
    fun toolcalls() {
        open(FunctionalScenario.TOOL_CALLS)

        // `chat_tool_<id>` names the card for a tool *result*.
        assertPresent("chat_tool_calls_${FunctionalScenario.TOOL_CALLS_ASSISTANT}")
    }

    @Test
    fun toolresult() {
        open(FunctionalScenario.TOOL_RESULT)

        assertPresent("chat_tool_${FunctionalScenario.TOOL_RESULT_TOOL}")
        // Collapsed by default, so the tool's *name* is the part that is always on screen.
        assertPresent("tool_card_name")
    }

    @Test
    fun markdown() {
        open(FunctionalScenario.MARKDOWN)

        // A fenced block has to have been recognised as one; if `Markdown` fell back to plain paragraphs this tag would not exist.
        assertPresent("markdown_code")
    }

    @Test
    fun images() {
        open(FunctionalScenario.IMAGES)

        assertPresent("chat_message_${FunctionalScenario.IMAGES_USER}")
        assertPresent("chat_attachments")
    }

    @Test
    fun reasoning() {
        open(FunctionalScenario.REASONING)

        assertPresent("chat_reasoning_${FunctionalScenario.REASONING_ASSISTANT}")
    }

    @Test
    fun html() {
        open(FunctionalScenario.HTML)

        // The scenario with no JVM equivalent at all: `HtmlPreview` takes its height from a script running inside a real `WebView`, and Robolectric's `WebView` is a …
        assertPresent("chat_html_frame")
        assertPresent("markdown_p")
    }

    @Test
    fun presentfiles() {
        open(FunctionalScenario.PRESENT_FILES)

        // `chat_tool_<id>` names the card for the tool *result* row, and the result here is the `present_files` envelope.
        assertPresent("chat_tool_${FunctionalScenario.PRESENT_FILES_TOOL}")
        assertPresent("tool_card_name")

        // KNOWN GAP, and it is a gap in this test rather than in the app.
    }

    // ─── finding nodes ─────────────────────────────────────────────────────

    /** Every lookup goes through the **unmerged** tree. */
    private fun node(tag: String): SemanticsNodeInteraction =
        composeRule.onNodeWithTag(tag, useUnmergedTree = true)

    private fun nodes(tag: String): SemanticsNodeInteractionCollection =
        composeRule.onAllNodesWithTag(tag, useUnmergedTree = true)

    /** Asserts a tag reached the tree, and lists what did when it did not. */
    private fun assertPresent(tag: String, timeoutMillis: Long = TAG_TIMEOUT_MILLIS) {
        try {
            composeRule.waitUntil(timeoutMillis) {
                nodes(tag).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (timedOut: Throwable) {
            throw AssertionError(
                "no node with testTag '$tag' after ${timeoutMillis}ms. " +
                    "Tags present: ${renderedTags()}",
                timedOut,
            )
        }
    }

    private fun renderedTags(): List<String> =
        composeRule.onAllNodes(SemanticsMatcher("every node") { true }, useUnmergedTree = true)
            .fetchSemanticsNodes()
            .mapNotNull { it.config.getOrNull(SemanticsProperties.TestTag) }
            .sorted()

    // ─── driving the app ───────────────────────────────────────────────────

    /** Launches the app on one seeded chat. */
    private fun open(sessionId: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("pabrik://chat/$sessionId"))
            .setClassName(context, MainActivity::class.java.name)

        launched = ActivityScenario.launch(intent)
        awaitTranscript()
    }

    /** Waits for the transcript, and says what it saw when it never arrives. */
    private fun awaitTranscript() {
        composeRule.waitUntil(timeoutMillis = TRANSCRIPT_TIMEOUT_MILLIS) {
            nodes("chat_message_list").fetchSemanticsNodes().isNotEmpty()
        }

        assertTrue(
            "the launch gate is still on screen after waiting for the transcript — " +
                "the app never reached a session at all (base URL ${BuildConfig.API_BASE_URL})",
            nodes("launch_gate").fetchSemanticsNodes().isEmpty(),
        )
    }

    private companion object {
        /** Generous: a cold app against a local server, on a loaded device. */
        const val TRANSCRIPT_TIMEOUT_MILLIS = 30_000L

        /** Per-tag. */
        const val TAG_TIMEOUT_MILLIS = 20_000L
    }
}
