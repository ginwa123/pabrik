package com.pabrik.mobile.recents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikText

/** The drawer's top-level "New Chat" row. */
@Composable
internal fun NewChatRow(
    isBusy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        // The affordance half of the invariant; HomeViewModel is the other.
        enabled = !isBusy,
        modifier = modifier
            .fillMaxWidth()
            .testTag("sidebar_new_chat")
            .semantics {
                role = Role.Button
                contentDescription = "Start a new chat"
            },
        shape = RoundedCornerShape(10.dp),
        color = Color.Transparent,
        contentColor = PabrikText,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .testTag("sidebar_new_chat_busy")
                        .semantics { contentDescription = "Starting a new chat" },
                    color = PabrikAccent,
                    strokeWidth = 2.dp,
                )
            } else {
                androidx.compose.material3.Icon(
                    imageVector = Icons.Filled.Edit,
                    // The a11y name is on the Surface above, so this is hidden from the semantics tree to avoid a doubled announcement.
                    contentDescription = null,
                    tint = PabrikAccent,
                    modifier = Modifier.testTag("sidebar_new_chat_icon"),
                )
            }
            Text(
                text = "New Chat",
                style = androidx.compose.material3.MaterialTheme.typography.labelLarge,
                color = PabrikText,
            )
        }
    }
}
