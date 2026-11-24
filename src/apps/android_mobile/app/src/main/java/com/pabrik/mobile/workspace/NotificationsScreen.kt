package com.pabrik.mobile.workspace

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.notifications.NotificationItem
import com.pabrik.mobile.ui.FeatureScaffold
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

@Composable
fun NotificationsScreen(
    notifications: List<NotificationItem>,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FeatureScaffold(
        title = "Notifications",
        subtitle = "${notifications.size} total",
        onBack = onBack,
        modifier = modifier,
        testTag = "notifications_screen",
    ) {
        Text(
            text = "Recent activity",
            style = MaterialTheme.typography.titleSmall,
            color = PabrikAccent,
            modifier = Modifier.padding(vertical = 8.dp),
        )
        if (notifications.isEmpty()) {
            Text(
                text = "No notifications yet.",
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikMuted,
                modifier = Modifier.padding(16.dp),
            )
        }
        notifications.forEach { notification ->
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 5.dp)
                    .testTag("notification_row_${notification.id}"),
                shape = RoundedCornerShape(14.dp),
                color = PabrikBackgroundRaised,
                border = BorderStroke(1.dp, PabrikBorder),
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Text(
                        text = notification.message,
                        style = MaterialTheme.typography.bodyLarge,
                        color = PabrikText,
                    )
                    if (!notification.details.isNullOrEmpty()) {
                        Text(
                            text = notification.details,
                            style = MaterialTheme.typography.bodyMedium,
                            color = PabrikMuted,
                        )
                    }
                    Text(
                        text = notification.createdAtEpochMillis.toString(),
                        style = MaterialTheme.typography.labelSmall,
                        color = PabrikDim,
                    )
                }
            }
        }
    }
}
