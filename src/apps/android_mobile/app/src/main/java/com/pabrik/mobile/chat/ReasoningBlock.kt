package com.pabrik.mobile.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim

/** The header a collapsed reasoning block is drawn behind. */
const val REASONING_LABEL = "Thought"

/** Leading rule marking the reasoning body, the web's `border-l-2`. */
private val reasoningRuleWidth = 2.dp

/** Does this turn draw a reasoning block at all? */
fun showsReasoning(message: ChatMessage): Boolean =
    !message.isUser && message.reasoningContent.isNotBlank()

/** The key this turn's reasoning block is filed under in [ToolExpansion]. */
fun reasoningKey(id: String): String = "reasoning-$id"

/** The model chain of thought, folded away until the reader asks for it. */
@Composable
fun ReasoningBlock(
    message: ChatMessage,
    expansion: ToolExpansion,
    modifier: Modifier = Modifier,
) {
    if (!showsReasoning(message)) return
    val key = reasoningKey(message.id)
    val expanded = expansion.isExpanded(key)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("chat_reasoning_${message.id}"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expansion.toggle(key) }
                .testTag("chat_reasoning_header_${message.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = REASONING_LABEL,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = PabrikDim,
            )
            Spacer(Modifier.width(6.dp))
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = PabrikDim,
                modifier = Modifier.testTag("chat_reasoning_chevron_${message.id}"),
            )
        }

        if (expanded) {
            Spacer(Modifier.height(4.dp))
            Text(
                text = message.reasoningContent,
                style = MaterialTheme.typography.bodySmall,
                color = PabrikDim,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    // The web's `border-l-2 pl-3` on the reasoning body.
                    .drawBehind {
                        drawRect(
                            color = PabrikBorder,
                            size = Size(reasoningRuleWidth.toPx(), size.height),
                        )
                    }
                    .padding(start = 10.dp)
                    .testTag("chat_reasoning_body_${message.id}"),
            )
        }
    }
}
