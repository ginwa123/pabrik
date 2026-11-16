package com.pabrik.mobile.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccentSoft
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** Which tool cards the reader has opened. */
@Composable
fun rememberToolExpansion(): ToolExpansion =
    rememberSaveable(saver = ToolExpansion.Saver) { ToolExpansion() }

/** An explicit open/closed decision per row. */
class ToolExpansion(initial: Map<String, Boolean> = emptyMap()) {
    private var overrides: Map<String, Boolean> by mutableStateOf(initial)

    fun isExpanded(id: String, defaultsToOpen: Boolean = false): Boolean =
        overrides[id] ?: defaultsToOpen

    fun toggle(id: String, defaultsToOpen: Boolean = false) {
        overrides = overrides + (id to !isExpanded(id, defaultsToOpen))
    }

    companion object {
        /** Saves only the *open* ids. */
        val Saver = listSaver<ToolExpansion, String>(
            save = { state -> state.overrides.filterValues { it }.keys.toList() },
            restore = { ids -> ToolExpansion(ids.associateWith { true }) },
        )
    }
}

/** The header for tool calls that no card has answered yet. */
@Composable
fun ToolCallSummaryRow(
    calls: List<ToolCallEntry>,
    expansion: ToolExpansion,
    id: String,
    modifier: Modifier = Modifier,
) {
    if (calls.isEmpty()) return
    val expanded = expansion.isExpanded(id)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(PabrikCard)
            .testTag("tool_call_summary"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expansion.toggle(id) }
                .padding(horizontal = 8.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (calls.size == 1) "1 TOOL" else "${calls.size} TOOLS",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = PabrikAccentSoft,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = calls.joinToString(", ") { it.name }.ifBlank { "unknown" },
                style = MaterialTheme.typography.labelSmall,
                color = PabrikMuted,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (expanded) {
                    Icons.Filled.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = PabrikMuted,
                modifier = Modifier.testTag("tool_call_summary_chevron"),
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier.padding(bottom = 4.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                calls.forEach { call ->
                    Column(modifier = Modifier.padding(horizontal = 8.dp)) {
                        Text(
                            text = call.name.ifEmpty { "(unnamed)" },
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = PabrikText,
                        )
                        val arguments = call.summary
                        if (arguments.isNotEmpty()) {
                            Text(
                                text = arguments,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                color = PabrikDim,
                            )
                        }
                    }
                }
            }
        }
    }
}
