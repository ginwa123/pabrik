package com.pabrik.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** The projects a new chat can be created in, from [projects]. */
fun projectsThatTakeAChat(projects: List<ProjectSummary>): List<ProjectSummary> =
    projects.filterNot { it.itemType == ProjectTypes.ROUTINE }

/** Which project, if any, a new chat can start in. */
fun newChatProjectCount(projects: List<ProjectSummary>): Int =
    projectsThatTakeAChat(projects).size

/** "Which project?" — the one step between pressing `+ New chat` and a `POST`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewChatProjectSheet(
    projects: List<ProjectSummary>,
    onProjectPicked: (ProjectSummary) -> Unit,
    onDismiss: () -> Unit,
) {
    val candidates = projectsThatTakeAChat(projects)
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = PabrikBackgroundRaised,
        modifier = Modifier.testTag("new_chat_project_sheet"),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "New chat in…",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )

            if (candidates.isEmpty()) {
                // The honest answer when there is nothing to choose from.
                Text(
                    text = "No projects here yet. Create one in the desktop app, " +
                        "then come back for a new chat.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = PabrikMuted,
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .testTag("new_chat_no_projects"),
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 360.dp)
                        .testTag("new_chat_project_list"),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(candidates, key = { it.id }) { project ->
                        NewChatProjectRow(
                            project = project,
                            onClick = { onProjectPicked(project) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NewChatProjectRow(
    project: ProjectSummary,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .testTag("new_chat_project_${project.id}")
            .semantics {
                role = Role.Button
                contentDescription = "New chat in ${project.displayName}"
            },
        shape = RoundedCornerShape(12.dp),
        color = PabrikField,
        contentColor = PabrikText,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.ChatBubbleOutline,
                contentDescription = null,
                tint = PabrikAccent,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = project.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    color = PabrikText,
                )
                // The type is shown because two projects can share a name across types in a workspace, and "which one" is exactly the question this sheet is asking.
                Text(
                    text = project.itemType.ifBlank { "project" },
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikDim,
                )
            }
        }
    }
}
