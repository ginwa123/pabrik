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
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

data class FeatureSection(
    val title: String,
    val rows: List<FeatureRow>,
)

data class FeatureRow(
    val label: String,
    val value: String,
    val detail: String? = null,
)

@Composable
fun ItemFeatureScreen(
    featureName: String,
    workspaceId: String,
    itemId: String?,
    sections: List<FeatureSection>,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FeatureScaffold(
        title = featureName,
        subtitle = if (itemId != null) "$workspaceId / $itemId" else workspaceId,
        onBack = onBack,
        modifier = modifier,
        testTag = "item_feature_screen",
    ) {
        Text(
            text = featureName,
            style = MaterialTheme.typography.headlineSmall,
            color = PabrikText,
            modifier = Modifier.padding(vertical = 8.dp),
        )
        Text(
            text = "This screen mirrors the web's $featureName view, adapted for mobile.",
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikMuted,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        sections.forEach { section ->
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 6.dp)
                    .testTag("feature_section_${section.title.lowercase().replace(' ', '_')}"),
                shape = RoundedCornerShape(16.dp),
                color = PabrikBackgroundRaised,
                border = BorderStroke(1.dp, PabrikBorder),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = section.title,
                        style = MaterialTheme.typography.titleSmall,
                        color = PabrikAccent,
                    )
                    Spacer(Modifier.height(8.dp))
                    section.rows.forEach { row ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = row.label,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = PabrikText,
                                )
                                if (!row.detail.isNullOrEmpty()) {
                                    Text(
                                        text = row.detail,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = PabrikDim,
                                    )
                                }
                            }
                            Text(
                                text = row.value,
                                style = MaterialTheme.typography.labelMedium,
                                color = PabrikAccent,
                            )
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}
