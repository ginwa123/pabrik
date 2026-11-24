package com.pabrik.mobile.workspace

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.FeatureScaffold
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

@Composable
fun UserSettingsScreen(
    userEmail: String?,
    serverBaseUrl: String,
    onBack: () -> Unit,
    onOpenNetworkInspector: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    FeatureScaffold(
        title = "Settings",
        subtitle = "Account and appearance",
        onBack = onBack,
        modifier = modifier,
        testTag = "user_settings_screen",
    ) {
        Section("Account") {
            SettingRow("Signed in as", userEmail ?: "Not signed in")
            SettingRow("Server", serverBaseUrl)
        }
        Section("Appearance") {
            SettingRow("Theme", "Kanagawa Dragon (dark)")
            SettingRow("Text size", "System default")
        }
        Section("Security") {
            SettingRow("Session", "Managed by this device")
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun Section(
    title: String,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .testTag("settings_section_${title.lowercase()}"),
        shape = RoundedCornerShape(16.dp),
        color = PabrikBackgroundRaised,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = PabrikAccent,
            )
            Spacer(Modifier.height(8.dp))
            content()
        }
    }
}

@Composable
private fun SettingRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikMuted,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikText,
            modifier = Modifier.weight(1.4f),
        )
    }
}
