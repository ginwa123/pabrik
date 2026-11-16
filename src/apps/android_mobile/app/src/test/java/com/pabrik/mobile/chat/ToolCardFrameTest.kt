package com.pabrik.mobile.chat

import androidx.compose.ui.graphics.Color
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The tool card's frame, which is a 2dp left rule and nothing else. */
class ToolCardFrameTest {

    @Test
    fun `a failed card's rule is the only red the card has`() {
        assertEquals(Color(0xFF6B3A38), CardRuleColor(model(success = false, pending = false)))
    }

    @Test
    fun `a settled success keeps the neutral rule`() {
        assertEquals(PabrikBorder, CardRuleColor(model(success = true, pending = false)))
    }

    @Test
    fun `a running card is dim rather than green`() {
        // Pending is checked first on purpose. A placeholder row is a success
        // with no payload yet, so ordering the branches the other way paints a
        // finished-looking rule on a call that has not returned.
        assertEquals(PabrikDim, CardRuleColor(model(success = true, pending = true)))
    }

    @Test
    fun `failure is visually distinct from every other state`() {
        val failure = CardRuleColor(model(success = false, pending = false))
        assertNotEquals(PabrikBorder, failure)
        assertNotEquals(PabrikDim, failure)
    }

    @Test
    fun `the card frame draws a rule and not a box`() {
        val source = toolCardsSource()
        assertEquals(
            "the frame must not call Modifier.border: a four-sided stroke is the box " +
                "this card no longer has, and the web's own frame is `border: none` " +
                "with a `border-left`",
            0,
            Regex("""\.border\s*\(""").findAll(source).count(),
        )
        assertTrue(
            "the leading rule must be drawn at the card's full height, otherwise it " +
                "reads as a tick beside the header rather than as the row's edge",
            source.contains("Size(TOOL_CARD_RULE_WIDTH.toPx(), size.height)"),
        )
    }

    @Test
    fun `the rule is 2dp wide, matching the web's border-left`() {
        assertTrue(
            "the web's .chat-tool-card is `border-left: 2px`; a phone rule of any " +
                "other weight is a visible difference from the browser, which is the " +
                "whole point of this change",
            Regex("""TOOL_CARD_RULE_WIDTH\s*=\s*2\.dp""").containsMatchIn(toolCardsSource()),
        )
    }

    @Test
    fun `the rule recolours rather than snapping`() {
        // The web transitions `border-left-color` over 0.15s, so a streaming
        // transcript steps through states rather than flashing.
        assertTrue(
            "the rule colour must be animated so a card that fails mid-stream " +
                "recolours like the web's `transition: border-left-color 0.15s ease`",
            Regex("""animateColorAsState\(\s*targetValue\s*=\s*CardRuleColor\(model\)""")
                .containsMatchIn(toolCardsSource()),
        )
    }

    private fun model(success: Boolean, pending: Boolean) = ToolCardModel(
        id = "call-1",
        toolCallId = "call-1",
        kind = ToolKind.ReadFile,
        label = "read_file",
        primary = "/tmp/a.txt",
        rightMeta = "3L",
        success = success,
        pending = pending,
        errorText = null,
        parametersJson = "",
        body = ToolBody.Empty,
    )

    /**
     * The module's own source, or a hard failure when the test runs from
     * somewhere that cannot see it. The colour assertions above stand on their
     * own; only the frame-shape ones need the file.
     */
    private fun toolCardsSource(): String =
        sequenceOf(
            "src/main/java/com/pabrik/mobile/chat/ToolCards.kt",
            "app/src/main/java/com/pabrik/mobile/chat/ToolCards.kt",
        )
            .map(::File)
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("ToolCards.kt not reachable from ${File(".").absolutePath}")
}
