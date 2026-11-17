package com.pabrik.mobile.workspace

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.FeatureScaffold
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

@Composable
fun DocumentsScreen(
    state: WorkspaceDataState,
    onBack: () -> Unit,
    onOpenDocument: (DocumentEntry) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    FeatureScaffold(
        title = "Documents",
        subtitle = state.workspaceId,
        onBack = onBack,
        modifier = modifier,
        isLoading = state.isLoading,
        errorMessage = state.errorMessage.takeIf { state.documents.isEmpty() },
        testTag = "documents_screen",
    ) {
        Text(
            text = "Workspace items (${state.documents.size})",
            style = MaterialTheme.typography.titleSmall,
            color = PabrikAccent,
            modifier = Modifier.padding(vertical = 8.dp),
        )
        if (state.documents.isEmpty()) {
            Text(
                text = "No documents in this workspace.",
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikMuted,
                modifier = Modifier.padding(16.dp),
            )
        }
        state.documents.forEach { document ->
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 5.dp)
                    .clickable { onOpenDocument(document) }
                    .testTag("document_row_${document.id}"),
                shape = RoundedCornerShape(14.dp),
                color = PabrikBackgroundRaised,
                border = BorderStroke(1.dp, PabrikBorder),
            ) {
                Row(
                    modifier = Modifier.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = document.name.ifBlank { document.id },
                            style = MaterialTheme.typography.bodyLarge,
                            color = PabrikText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = document.itemType,
                            style = MaterialTheme.typography.labelSmall,
                            color = PabrikAccent,
                        )
                        if (document.path.isNotEmpty()) {
                            Text(
                                text = document.path,
                                style = MaterialTheme.typography.labelSmall,
                                color = PabrikDim,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}
