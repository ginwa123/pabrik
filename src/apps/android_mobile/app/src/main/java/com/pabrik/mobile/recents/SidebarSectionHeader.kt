package com.pabrik.mobile.recents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted

/** The header above a collapsible sidebar section: the word, how many rows it holds, and a chevron that folds the section away. */
@Composable
internal fun SidebarSectionHeader(
    title: String,
    itemCount: Int,
    /** "chats" / "projects" — read out after the number. */
    unit: String,
    expanded: Boolean,
    onClick: () -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
    /** Whether anything in this section is busy right now. */
    isRunning: Boolean = false,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag)
            .semantics {
                role = Role.Button
                heading()
                contentDescription = buildString {
                    append("$title. $itemCount $unit in this workspace")
                    if (isRunning) append(", agent is working")
                }
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        shape = RoundedCornerShape(10.dp),
        color = PabrikBackground,
        contentColor = PabrikDim,
    ) {
        // 6dp, not 10dp.
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelLarge,
                color = PabrikDim,
                modifier = Modifier.weight(1f),
            )
            if (itemCount > 0) {
                Text(
                    text = itemCount.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikMuted,
                )
            }
            if (isRunning) {
                CircularProgressIndicator(
                    // Decorative — the section's own description already says it, and announcing it a second time is worse than not announcing it.
                    modifier = Modifier
                        .clearAndSetSemantics { }
                        .size(14.dp)
                        .testTag("${testTag}_running"),
                    strokeWidth = 2.dp,
                    color = PabrikAccent,
                )
            }
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = PabrikDim,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
