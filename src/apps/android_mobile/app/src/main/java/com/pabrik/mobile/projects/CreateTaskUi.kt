package com.pabrik.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** The `+` that opens the create flow, drawn at the top of an unfolded project. */
@Composable
internal fun CreateTaskRow(
    projectName: String,
    isBusy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        // Disabled while the create is in flight, so a second tap cannot become a second "New Chat".
        enabled = !isBusy,
        modifier = modifier
            .fillMaxWidth()
            .testTag("create_task_row_$projectName")
            .semantics {
                role = Role.Button
                contentDescription = "Add a chat or a memory to $projectName"
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
                        .size(16.dp)
                        .testTag("create_task_busy_$projectName"),
                    strokeWidth = 2.dp,
                    color = PabrikAccent,
                )
            } else {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = null,
                    tint = PabrikAccent,
                    modifier = Modifier.size(16.dp),
                )
            }
            Text(
                text = if (isBusy) "Creating…" else "New chat",
                style = MaterialTheme.typography.labelLarge,
                color = PabrikAccent,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** The two cards, and nothing else. */
@Composable
fun CreateTaskPickerSheet(
    projectName: String,
    onPickStandardChat: () -> Unit,
    onPickMemory: () -> Unit,
    onDismiss: () -> Unit,
) = PickerSheetScaffold(projectName = projectName, onDismiss = onDismiss) {
    PickerCard(
        title = "Standard Chat",
        detail = "Starts a conversation you can write in right away.",
        glyph = Icons.Filled.ChatBubbleOutline,
        testTag = "create_task_pick_standard",
        onClick = onPickStandardChat,
    )
    PickerCard(
        title = "Memory",
        detail = "Saves a markdown file the agent reads on its next run here.",
        glyph = Icons.Filled.Description,
        testTag = "create_task_pick_memory",
        onClick = onPickMemory,
    )
}

/** The sheet chrome both pickers share: the "Add to …" heading, the card list, and the drag handle a `ModalBottomSheet` puts above them. @param sheetTestTag lets … */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheetScaffold(
    projectName: String,
    onDismiss: () -> Unit,
    sheetTestTag: String = "create_task_picker",
    cards: @Composable ColumnScope.() -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = PabrikBackgroundRaised,
        modifier = Modifier.testTag(sheetTestTag),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Add to $projectName",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            cards()
        }
    }
}

@Composable
private fun PickerCard(
    title: String,
    detail: String,
    glyph: ImageVector,
    testTag: String,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .testTag(testTag)
            .semantics {
                role = Role.Button
                contentDescription = "$title. $detail"
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
                imageVector = glyph,
                contentDescription = null,
                tint = PabrikAccent,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = PabrikText,
                )
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikMuted,
                )
            }
        }
    }
}

/** The memory form: a file name and a body. */
@Composable
fun NewMemoryDialog(
    projectName: String,
    isSubmitting: Boolean,
    errorMessage: String?,
    onSubmit: (name: String, content: String) -> Unit,
    onBack: () -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var content by remember { mutableStateOf("") }
    val canSubmit = canSubmitMemory(name, content) && !isSubmitting

    androidx.compose.material3.AlertDialog(
        onDismissRequest = { if (!isSubmitting) onDismiss() },
        modifier = Modifier.testTag("create_memory_dialog"),
        containerColor = PabrikBackgroundRaised,
        title = {
            Text(
                text = "New memory in $projectName",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    // Not `enabled = !isSubmitting`: a field that goes dead the instant Submit is pressed loses focus and the keyboard, and on a slow network that is a visible …
                    readOnly = isSubmitting,
                    singleLine = true,
                    label = { Text("File name (must end in .md)") },
                    placeholder = { Text("my-memory.md") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("create_memory_name"),
                    colors = fieldColors(),
                )
                OutlinedTextField(
                    value = content,
                    onValueChange = { content = it },
                    readOnly = isSubmitting,
                    label = { Text("Content") },
                    modifier = Modifier
                        .fillMaxWidth()
                        // Tall enough to write in.
                        .heightIn(min = 120.dp)
                        .testTag("create_memory_content"),
                    colors = fieldColors(),
                )
                if (errorMessage != null) {
                    Text(
                        text = errorMessage,
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikError,
                        modifier = Modifier.testTag("create_task_error"),
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { onSubmit(name, content) },
                enabled = canSubmit,
                modifier = Modifier.testTag("create_memory_submit"),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PabrikAccent,
                    contentColor = PabrikBackgroundRaised,
                ),
            ) {
                Text(if (isSubmitting) "Creating…" else "Create")
            }
        },
        dismissButton = {
            // "Back" rather than "Cancel": there is a step behind this form, and a button labelled Cancel invites the reader to close the flow when what they mean is "not …
            TextButton(
                onClick = onBack,
                enabled = !isSubmitting,
                modifier = Modifier.testTag("create_memory_back"),
            ) {
                Text("Back", color = PabrikMuted)
            }
        },
    )
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = PabrikText,
    unfocusedTextColor = PabrikText,
    focusedBorderColor = PabrikAccent,
    unfocusedBorderColor = PabrikBorder,
    focusedLabelColor = PabrikAccent,
    unfocusedLabelColor = PabrikMuted,
    cursorColor = PabrikAccent,
)

/** Renders whichever step [controller] is on, over whatever is already there. */
@Composable
fun CreateTaskHost(
    controller: CreateTaskController,
    isSubmitting: Boolean,
    errorMessage: String?,
    kanbanData: NewTaskDialogData = NewTaskDialogData(),
    onRequestKanbanData: (workspaceId: String, itemId: String) -> Unit = { _, _ -> },
) {
    when (val step = controller.step) {
        CreateTaskStep.Idle -> Unit

        is CreateTaskStep.Picking -> CreateTaskPickerSheet(
            projectName = step.projectName,
            onPickStandardChat = controller::pickStandardChat,
            onPickMemory = controller::pickMemory,
            onDismiss = controller::dismiss,
        )

        is CreateTaskStep.NamingTask -> {
            LaunchedEffect(step.workspaceId, step.itemId) {
                onRequestKanbanData(step.workspaceId, step.itemId)
            }
            NewTaskDialog(
                projectName = step.projectName,
                defaultCwd = step.projectPath,
                data = kanbanData,
                isSubmitting = isSubmitting,
                errorMessage = errorMessage,
                onSubmit = controller::submitTaskForm,
                onClose = controller::dismiss,
            )
        }

        is CreateTaskStep.NamingMemory -> NewMemoryDialog(
            projectName = step.projectName,
            isSubmitting = isSubmitting,
            errorMessage = errorMessage,
            onSubmit = controller::submitMemory,
            onBack = controller::backToPicker,
            onDismiss = controller::dismiss,
        )
    }
}
