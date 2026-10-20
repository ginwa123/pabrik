package com.pabrik.mobile.projects

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import com.pabrik.mobile.chat.BitmapPickedImageReader
import com.pabrik.mobile.chat.ChatAttachments
import com.pabrik.mobile.chat.PickedImageReader
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikErrorSoft
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/**
 * The values the "New task" form is opened with, fetched by the caller.
 *
 * A single parameter rather than four, because the form never loads anything
 * itself: the fetch belongs to [com.pabrik.mobile.recents.HomeViewModel] where
 * every other request in this app lives, and a composable that reached for a
 * client would be one no JVM test could render.
 *
 * All four degrade to empty rather than to an error. A create needs none of
 * them: the column picker, the profile picker and the worktree prefill are all
 * optional conveniences around a card the server is perfectly happy to accept
 * with nothing set.
 */
data class NewTaskDialogData(
    /** The board's columns, in board order. Empty = no column picker shown. */
    val columns: List<KanbanColumn> = emptyList(),
    /** Profile names from `GET /api/config/pabrik`. Empty = "Default" only. */
    val profiles: List<String> = emptyList(),
    /** The server's `$HOME`, for the worktree prefill. "" = unknown. */
    val serverHome: String = "",
    val isLoading: Boolean = false,
)

/**
 * The board's "New task" form, mirroring the web's create-mode dialog.
 *
 * Field for field and in the same order as `KanbanTaskDetail.vue` in create
 * mode — title, column, description, tags, then a Settings block holding the
 * project root, the profile, unattended mode and the git-worktree block, and
 * finally the split "Create task & run agent" / "Create task only" commit row.
 * The reasons for each of those, and the two places where the phone cannot do
 * what the browser does, are on the composable that owns them.
 *
 * Full-screen rather than an `AlertDialog` because the web's form is roughly a
 * phone screen and a half tall and scrolls, and an `AlertDialog` pins its own
 * header and buttons around a body it will not let grow: the Settings block
 * would be unreachable on the device this ships to.
 *
 * Drawn as an overlay in the activity's composition rather than inside a
 * platform `Dialog` window, and the commit row's visibility depends on it —
 * see the comment on the [Surface] below for the whole of it. The caller is
 * responsible for painting it over whatever it covers
 * ([com.pabrik.mobile.network.PabrikNavGraph] mounts it after the `NavHost`).
 */
@Composable
fun NewTaskDialog(
    projectName: String,
    /** The board's own path, used to prefill "Project root". */
    defaultCwd: String,
    data: NewTaskDialogData = NewTaskDialogData(),
    isSubmitting: Boolean,
    errorMessage: String?,
    onSubmit: (KanbanTaskForm) -> Unit,
    onClose: () -> Unit,
    /**
     * Turns a picked image URI into the base64 data URL `image_urls` wants.
     *
     * Null means "use the real one", which is built from the composition's
     * context — so a caller never has to thread a `ContentResolver` through the
     * nav graph to make a paperclip work, and a test can pass a fake to render
     * the form without an Android runtime.
     *
     * It is the chat composer's own reader rather than a second implementation,
     * because the two surfaces need byte-identical output: the same image picked
     * from the chat and from a card has to encode the same way or the 10 MB
     * budget means two different things on two screens.
     */
    imageReader: PickedImageReader? = null,
) {
    val context = LocalContext.current
    val reader = remember(context, imageReader) {
        imageReader ?: BitmapPickedImageReader(context.contentResolver)
    }
    val scope = rememberCoroutineScope()
    var form by remember(projectName) { mutableStateOf(KanbanTaskForm(cwd = defaultCwd)) }
    var tagDraft by remember(projectName) { mutableStateOf("") }
    var columnMenuOpen by remember { mutableStateOf(false) }
    var profileMenuOpen by remember { mutableStateOf(false) }
    var commitMenuOpen by remember { mutableStateOf(false) }
    var readError by remember(projectName) { mutableStateOf<String?>(null) }

    // One launcher for the whole form, for the same reason the chat transcript
    // has one rather than one per chip: it is a registration against the
    // activity, and re-registering leaves the previous callback live.
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val attachment = reader.read(uri.toString())
            if (attachment == null) {
                readError = "That image could not be read."
                return@launch
            }
            val next = form.imageUrls + attachment.dataUrl
            // The same 10 MB cap the chat enforces, checked on the *joined*
            // string because that is what the server measures
            // (`MAX_IMAGE_URLS_BYTES` in `image_urls_validation.zig`). Refused
            // here so the reader is told which attachment did not fit instead of
            // finding out from a 413 that names no file.
            val joined = next.joinToString("||")
            if (joined.toByteArray().size > ChatAttachments.MAX_TOTAL_BYTES) {
                readError = "That image is too large. The limit is " +
                    "${ChatAttachments.MAX_TOTAL_BYTES / (1024 * 1024)} MB in total."
                return@launch
            }
            readError = null
            form = form.copy(imageUrls = next)
        }
    }

    // The committed form is what the button is judged on, so a tag still sitting
    // in the draft counts — the same rule as the web's `commitDraft()` on the
    // Save button's mousedown.
    val committedTags = remember(form.tags, tagDraft) {
        KanbanTags.normalize(form.tags + tagDraft.split(','))
    }
    val canSubmit = canSubmitKanbanTask(form.copy(tags = committedTags)) && !isSubmitting

    fun commit(runAgent: Boolean) {
        if (!canSubmit) return
        onSubmit(form.copy(tags = committedTags, runAgent = runAgent))
    }

    // The form covers the board rather than floating above it, so Back has to be
    // claimed explicitly: a `Dialog` used to get this from the window for free,
    // and an overlay that swallowed the screen without taking Back would strand
    // a reader who presses it on the way out of the form.
    BackHandler(enabled = !isSubmitting) { onClose() }

    // Not a platform `Dialog`, and the reason is a bug this form shipped with.
    // `Dialog(usePlatformDefaultWidth = false)` measures its content against
    // `Configuration.screenHeightDp` — the *whole* display, status bar and
    // navigation bar included — and then calls `window.setLayout()` with the
    // child's measured size (`DialogLayout.internalOnMeasure` /
    // `internalOnLayout` in compose-ui's `AndroidDialog.android.kt`). A
    // `fillMaxSize()` surface therefore fills the raw display, and the pinned
    // commit row at the bottom of the form lands underneath the navigation bar:
    // "▶ Create task & run agent" is drawn at the very edge of the screen and
    // half of it is clipped away, so the one control the whole form exists for
    // is the one control nobody can see or tap.
    //
    // `windowInsetsPadding` cannot rescue that from inside the dialog — the
    // window is sized from the child, so the decor's own inset padding is
    // added *on top* of an already-full-height child and pushed off the bottom.
    // Drawn in the activity's composition instead, the form's bounds are the
    // window's bounds and [WindowInsets.safeDrawing] is the honest answer to
    // "where is the safe area", the same one the chat composer and the login
    // screen already read correctly.
    Surface(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .testTag("create_task_dialog"),
        color = PabrikBackgroundRaised,
        contentColor = PabrikText,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            NewTaskHeader(
                isSubmitting = isSubmitting,
                onBack = onClose,
                onClose = onClose,
            )
            if (errorMessage != null) {
                ErrorBanner(errorMessage)
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    // The IME is part of `safeDrawing`, which the root already
                    // pads for, so the scroll area stops where the footer does.
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FieldLabel("Task name")
                OutlinedTextField(
                    value = form.name,
                    onValueChange = { form = form.copy(name = it) },
                    readOnly = isSubmitting,
                    singleLine = true,
                    placeholder = { Text("Enter task name…") },
                    textStyle = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("create_task_name"),
                    colors = kanbanFieldColors(),
                )

                if (data.columns.isNotEmpty()) {
                    ColumnPicker(
                        columns = data.columns,
                        selectedId = form.columnId,
                        expanded = columnMenuOpen,
                        onExpandedChange = { columnMenuOpen = it },
                        onSelect = {
                            form = form.copy(columnId = it)
                            columnMenuOpen = false
                        },
                    )
                }

                FieldLabel("Description")
                HintText("Markdown supported. Type @ to link a file. Paste or attach images.")
                OutlinedTextField(
                    value = form.description,
                    onValueChange = { form = form.copy(description = it) },
                    readOnly = isSubmitting,
                    // Tall enough to write in: this is the card's face, read
                    // at a glance on the board.
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp)
                        .testTag("create_task_description"),
                    colors = kanbanFieldColors(),
                )
                AttachmentRow(
                    imageCount = form.imageUrls.size,
                    enabled = !isSubmitting,
                    canPick = true,
                    onPick = {
                        // `PickVisualMedia` needs no runtime permission on
                        // any API level, so there is nothing to ask for
                        // first — a permission dialog in front of "attach a
                        // screenshot" is a dialog that gets in the way.
                        picker.launch(
                            PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageOnly,
                            ),
                        )
                    },
                )
                if (readError != null) {
                    Text(
                        text = readError!!,
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikError,
                        modifier = Modifier.testTag("create_task_attach_error"),
                    )
                }

                FieldLabel("Tags")
                HintText("Optional. Press Enter or comma to add. Letters, digits, underscores, hyphens.")
                TagRow(
                    tags = form.tags,
                    draft = tagDraft,
                    isSubmitting = isSubmitting,
                    onDraftChange = { tagDraft = it },
                    onCommit = { tagDraft = "" },
                    onRemove = { tag -> form = form.copy(tags = form.tags - tag) },
                )

                NewTaskSettings(
                    form = form,
                    data = data,
                    isSubmitting = isSubmitting,
                    profileMenuOpen = profileMenuOpen,
                    onProfileMenuChange = { profileMenuOpen = it },
                    onChange = { form = it },
                )
                Spacer(Modifier.height(12.dp))
            }
            NewTaskFooter(
                canSubmit = canSubmit,
                isSubmitting = isSubmitting,
                commitMenuOpen = commitMenuOpen,
                onCommitMenuChange = { commitMenuOpen = it },
                onCreateAndRun = { commit(runAgent = true) },
                onCreateOnly = { commit(runAgent = false) },
                onCancel = onClose,
            )
        }
    }
}

/**
 * `‹ Back  ＋ New task` and the ✕, in a band that never scrolls away.
 *
 * A fixed header because the form scrolls: the web makes its header and its
 * action row `position: sticky` for exactly this reason ("sticky so Back/Close
 * stay reachable on long forms"), and on a phone the commit row is 100dp of
 * screen a reader must not have to scroll back to find.
 */
@Composable
private fun NewTaskHeader(
    isSubmitting: Boolean,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(PabrikBackgroundRaised)
            .padding(start = 4.dp, end = 4.dp, top = 12.dp, bottom = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(
                onClick = onBack,
                enabled = !isSubmitting,
                modifier = Modifier.testTag("create_task_back"),
            ) {
                Icon(
                    imageVector = Icons.Filled.ArrowBack,
                    contentDescription = null,
                    tint = PabrikMuted,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text("Back", color = PabrikMuted)
            }
            Text(
                text = "＋ New task",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = PabrikText,
                modifier = Modifier.weight(1f),
            )
            IconButton(
                onClick = onClose,
                enabled = !isSubmitting,
                modifier = Modifier.testTag("create_task_close"),
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Close",
                    tint = PabrikMuted,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        Text(
            // The web's own create-mode subtitle, verbatim. It is the line that
            // tells the reader the button is not going to open a chat.
            text = "Create a new task, or start an agent on it right away.",
            style = MaterialTheme.typography.bodySmall,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 12.dp),
        )
    }
}

/**
 * The red strip above the body.
 *
 * Above the scroll, not inside it, for the reason the web's is
 * (`KanbanTaskDetail.vue`, "Error banner. Lifted OUT of the scrollable body so
 * it stays permanently visible"): a failed create keeps the form open with
 * everything typed still in it, and an error at the bottom of a scrolled form
 * is an error nobody sees.
 */
@Composable
private fun ErrorBanner(message: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(PabrikErrorSoft)
            .padding(horizontal = 16.dp, vertical = 10.dp)
            .testTag("create_task_error"),
    ) {
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikError,
        )
    }
}

@Composable
private fun FieldLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        color = PabrikMuted,
        modifier = Modifier.padding(top = 6.dp),
    )
}

@Composable
private fun HintText(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = PabrikDim,
    )
}

/**
 * The column chip and its dropdown.
 *
 * Renders nothing at all when the board has no columns — including while the
 * list is still loading. The web does the same (`v-if="isCreateMode &&
 * props.availableColumns.length > 0"`), and a chip that appears a frame later
 * would shift the description field down under the reader's thumb.
 *
 * The chip's value is the chosen column's *name*, and when nothing is chosen it
 * says the first column's name rather than a blank: the server auto-assigns to
 * the first column, so naming it is what is going to happen, and an empty chip
 * would claim the card has no column at all.
 */
@Composable
private fun ColumnPicker(
    columns: List<KanbanColumn>,
    selectedId: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelect: (String) -> Unit,
) {
    val label = columns.firstOrNull { it.id == selectedId }?.displayName
        ?: columns.firstOrNull()?.displayName.orEmpty()
    Box {
        PickerChip(
            label = label,
            testTag = "create_task_column",
            onClick = { onExpandedChange(!expanded) },
        )
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { onExpandedChange(false) },
            modifier = Modifier.testTag("create_task_column_menu"),
        ) {
            for (column in columns) {
                DropdownMenuItem(
                    text = { Text(column.displayName) },
                    trailingIcon = {
                        if (column.id == selectedId) {
                            Icon(
                                imageVector = Icons.Filled.Check,
                                contentDescription = null,
                                tint = PabrikAccent,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    },
                    onClick = { onSelect(column.id) },
                    modifier = Modifier.testTag("create_task_column_item_${column.id}"),
                )
            }
        }
    }
}

/**
 * The chip both pickers draw, so "Project root" and "Agent" read as a pair.
 *
 * The web builds the same chip twice with the same classes and says why ("Both
 * use the same chip-style trigger so they read as siblings").
 */
@Composable
private fun PickerChip(
    label: String,
    testTag: String,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = PabrikField,
        contentColor = PabrikText,
        border = BorderStroke(1.dp, PabrikBorder),
        modifier = Modifier
            .testTag(testTag)
            .semantics {
                role = Role.Button
                contentDescription = label
            },
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = PabrikText,
                maxLines = 1,
            )
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = PabrikDim,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/**
 * The paperclip and the count, under the description.
 *
 * One row rather than the web's floating button because a floating overlay on a
 * scrolling form is a target that moves while a thumb is heading for it. The
 * images themselves are the caller's business — this app already reads picked
 * images into data URLs for the chat composer ([com.pabrik.mobile.chat.ChatAttachment]),
 * and the form reuses exactly that, because `image_urls` wants the same
 * `data:<mime>;base64,…` strings on both surfaces.
 */
@Composable
private fun AttachmentRow(
    imageCount: Int,
    enabled: Boolean,
    canPick: Boolean,
    onPick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (canPick) {
            Surface(
                onClick = onPick,
                enabled = enabled,
                shape = RoundedCornerShape(8.dp),
                color = PabrikField,
                contentColor = PabrikText,
                border = BorderStroke(1.dp, PabrikBorder),
                modifier = Modifier
                    .testTag("create_task_attach")
                    .semantics {
                        role = Role.Button
                        contentDescription = "Attach an image"
                    },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Filled.AttachFile,
                        contentDescription = null,
                        tint = PabrikMuted,
                        modifier = Modifier.size(16.dp),
                    )
                    Text("Attach", style = MaterialTheme.typography.labelLarge)
                }
            }
        }
        Text(
            // The web prints "0 chars" beside the field. The count here is the
            // number of attached images, because a phone reader's only question
            // about the description is what is *in* it, not how long it is.
            text = "$imageCount image${if (imageCount == 1) "" else "s"}",
            style = MaterialTheme.typography.labelMedium,
            color = PabrikDim,
        )
    }
}

/**
 * The committed chips, the draft field, and the add button.
 *
 * Enter and comma both commit, because the web's `KanbanTagsInput` does and a
 * phone keyboard's primary key is a newline rather than a comma: a reader who
 * typed one tag and pressed the blue key must get a chip, not a newline.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TagRow(
    tags: List<String>,
    draft: String,
    isSubmitting: Boolean,
    onDraftChange: (String) -> Unit,
    onCommit: () -> Unit,
    onRemove: (String) -> Unit,
) {
    val enabled = !isSubmitting

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (tags.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (tag in tags) {
                    Surface(
                        onClick = { if (enabled) onRemove(tag) },
                        enabled = enabled,
                        shape = RoundedCornerShape(6.dp),
                        color = PabrikField,
                        contentColor = PabrikText,
                        border = BorderStroke(1.dp, PabrikBorder),
                        modifier = Modifier.testTag("create_task_tag_$tag"),
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(tag, style = MaterialTheme.typography.labelMedium)
                            Icon(
                                imageVector = Icons.Filled.Close,
                                contentDescription = "Remove tag $tag",
                                tint = PabrikDim,
                                modifier = Modifier.size(12.dp),
                            )
                        }
                    }
                }
            }
        }
        OutlinedTextField(
            value = draft,
            onValueChange = { typed ->
                // A comma is a commit, not a character: it can never be part of
                // a tag the server would accept (`tags_validation.zig` allows
                // only [a-zA-Z0-9_-]), so keeping it would only produce a draft
                // that is silently dropped at submit.
                if (typed.endsWith(",")) {
                    onDraftChange("")
                } else {
                    onDraftChange(typed)
                }
            },
            // Not `enabled = !isSubmitting`: a field that goes dead the instant
            // Commit is pressed drops focus and the keyboard, and on a slow
            // network that is a visible hiccup on a form about to close anyway.
            // Read-only says the same thing without the flicker.
            readOnly = isSubmitting,
            singleLine = true,
            placeholder = { Text("Add tags (letters, digits, hyphens)…") },
            trailingIcon = {
                IconButton(
                    onClick = onCommit,
                    enabled = enabled && draft.isNotBlank(),
                    modifier = Modifier.testTag("create_task_tag_add"),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Add,
                        contentDescription = "Add tag",
                        tint = if (enabled) PabrikAccent else PabrikDim,
                        modifier = Modifier.size(16.dp),
                    )
                }
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            modifier = Modifier
                .fillMaxWidth()
                .testTag("create_task_tags"),
            colors = kanbanFieldColors(),
        )
    }
}

/**
 * The block below the divider: how this task will run.
 *
 * Grouped under one heading rather than spread through the form because all
 * five controls answer the same question, which is what the web's own comment
 * says it is for ("all three answer the same question: 'how will this task
 * run?'"). Grouping them is also what lets a phone reader find the unattended
 * toggle without reading every field above it.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun NewTaskSettings(
    form: KanbanTaskForm,
    data: NewTaskDialogData,
    isSubmitting: Boolean,
    profileMenuOpen: Boolean,
    onProfileMenuChange: (Boolean) -> Unit,
    onChange: (KanbanTaskForm) -> Unit,
) {
    val enabled = !isSubmitting

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(PabrikBorder),
        )
        Text(
            text = "Settings",
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = PabrikMuted,
        )

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // "Project root" is a text field and not a folder picker: the web
            // opens `FilePickerDialog`, which browses the *server's* filesystem
            // from a browser. The phone cannot browse a remote disk, so this is
            // the one control that is a field rather than a picker — prefilled
            // with the board's own path, which is what the web prefills it with,
            // and typed into when the card needs a different root.
            OutlinedTextField(
                value = form.cwd,
                onValueChange = { onChange(form.copy(cwd = it)) },
                readOnly = isSubmitting,
                singleLine = true,
                label = { Text("Project root") },
                placeholder = { Text("(none)") },
                modifier = Modifier
                    .weight(1f, fill = false)
                    .width(230.dp)
                    .testTag("create_task_cwd"),
                colors = kanbanFieldColors(),
            )

            Box {
                PickerChip(
                    label = form.profile.ifEmpty { "Default" },
                    testTag = "create_task_profile",
                    onClick = { onProfileMenuChange(!profileMenuOpen) },
                )
                DropdownMenu(
                    expanded = profileMenuOpen,
                    onDismissRequest = { onProfileMenuChange(false) },
                    modifier = Modifier.testTag("create_task_profile_menu"),
                ) {
                    // "Default (top-level config)" is a real entry and not the
                    // absence of one: the web draws it as the first row with a
                    // tick, and an empty string is an instruction ("use the
                    // top-level config") rather than "no choice".
                    DropdownMenuItem(
                        text = { Text("Default (top-level config)") },
                        trailingIcon = {
                            if (form.profile.isEmpty()) {
                                Icon(
                                    imageVector = Icons.Filled.Check,
                                    contentDescription = null,
                                    tint = PabrikAccent,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        },
                        onClick = {
                            onChange(form.copy(profile = ""))
                            onProfileMenuChange(false)
                        },
                        modifier = Modifier.testTag("create_task_profile_item_default"),
                    )
                    for (name in data.profiles) {
                        DropdownMenuItem(
                            text = { Text(name) },
                            trailingIcon = {
                                if (form.profile == name) {
                                    Icon(
                                        imageVector = Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = PabrikAccent,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            },
                            onClick = {
                                onChange(form.copy(profile = name))
                                onProfileMenuChange(false)
                            },
                            modifier = Modifier.testTag("create_task_profile_item_$name"),
                        )
                    }
                    if (data.profiles.isEmpty() && !data.isLoading) {
                        DropdownMenuItem(
                            text = { Text("No agents configured. Add one in Settings.") },
                            onClick = { onProfileMenuChange(false) },
                            modifier = Modifier.testTag("create_task_profile_empty"),
                        )
                    }
                }
            }
        }

        SwitchRow(
            title = "Unattended mode",
            // The web's own wording, both halves of it.
            detail = "Keep retrying past the 10-error limit for overnight runs. " +
                "Off = stop on too-many-retries.",
            checked = form.unattended,
            enabled = enabled,
            testTag = "create_task_unattended",
            onCheckedChange = { onChange(form.copy(unattended = it)) },
        )

        SwitchRow(
            title = "Use git worktree",
            detail = "Run the agent in a fresh git worktree so its changes stay " +
                "isolated from your working tree.",
            checked = form.useGitWorktree,
            enabled = enabled,
            testTag = "create_task_worktree",
            onCheckedChange = { onChange(form.copy(useGitWorktree = it)) },
        )

        if (form.useGitWorktree) {
            OutlinedTextField(
                value = form.worktreePath,
                onValueChange = { onChange(form.copy(worktreePath = it)) },
                readOnly = isSubmitting,
                singleLine = true,
                label = { Text("Worktree path") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("create_task_worktree_path"),
                colors = kanbanFieldColors(),
            )
            HintText(
                "Default: \$HOME/${KanbanWorktree.DIR_SUFFIX}/<task-name>-<timestamp>. " +
                    "Must be absolute; the parent folder must exist.",
            )
            OutlinedTextField(
                value = form.worktreeBaseBranch,
                onValueChange = { onChange(form.copy(worktreeBaseBranch = it)) },
                readOnly = isSubmitting,
                singleLine = true,
                label = { Text("Base ref") },
                placeholder = { Text("origin/main") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("create_task_worktree_base"),
                colors = kanbanFieldColors(),
            )
            HintText(
                "Optional but recommended. The new worktree's branch is created " +
                    "from this ref (e.g. origin/main). \"HEAD (default)\" branches " +
                    "from whatever the repo currently has checked out.",
            )
        }
    }
}

/**
 * A label, its explanation, and a switch — the shape both toggles share.
 *
 * The switch is the web's amber, not Material's, for the same reason the web
 * hard-codes `#f59e0b`: a "this keeps running after you go to bed" control that
 * looks like every other switch in the app is a control nobody thinks twice
 * about.
 */
@Composable
private fun SwitchRow(
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean,
    testTag: String,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(testTag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelLarge,
                color = PabrikMuted,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.labelMedium,
                color = PabrikDim,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = Color(0xFFF59E0B),
                uncheckedThumbColor = Color.White,
                uncheckedTrackColor = PabrikDim,
                uncheckedBorderColor = PabrikDim,
            ),
            modifier = Modifier.testTag("${testTag}_switch"),
        )
    }
}

/**
 * `Cancel` and the split commit button, pinned to the bottom.
 *
 * The left half creates **and runs** — which is also what the keyboard's Done
 * on the name field does, so the visual default and the keyboard default agree,
 * the same pairing the web draws. The caret's menu holds "Create task only".
 *
 * `Cancel` is a text button rather than a bordered one, for the web's stated
 * reason: "a border on a button means 'this is one of the choices you make',
 * and Cancel is the absence of one. It must not compete with the commit action
 * beside it."
 */
@Composable
private fun NewTaskFooter(
    canSubmit: Boolean,
    isSubmitting: Boolean,
    commitMenuOpen: Boolean,
    onCommitMenuChange: (Boolean) -> Unit,
    onCreateAndRun: () -> Unit,
    onCreateOnly: () -> Unit,
    onCancel: () -> Unit,
) {
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(PabrikBackgroundRaised)
                // No `navigationBarsPadding` here: the form's root already
                // reserves the safe area for the whole surface, so padding
                // again would float this row a system-bar's worth above the
                // screen edge it was drawn to clear.
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(
                onClick = onCancel,
                enabled = !isSubmitting,
                modifier = Modifier.testTag("create_task_cancel"),
            ) {
                Text("Cancel", color = PabrikMuted)
            }
            Button(
                onClick = onCreateAndRun,
                enabled = canSubmit,
                shape = RoundedCornerShape(topStart = 8.dp, bottomStart = 8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PabrikAccent,
                    contentColor = PabrikBackground,
                ),
                // `weight`, not a natural width: `Row` hands each unweighted
                // child only what the ones before it left behind, so on a narrow
                // phone the label "▶  Create task & run agent" — the whole point
                // of the button — was laid out 74dp wide and clipped to
                // nothing readable. Taking the remaining width says which of
                // the three controls is the one that matters.
                modifier = Modifier
                    .weight(1f)
                    .testTag("create_task_create_and_run"),
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = PabrikBackground,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Creating…")
                } else {
                    // One line: the label is the whole affordance, and a
                    // second line would push the pinned row taller than the
                    // space the safe area leaves it.
                    Text(
                        "▶  Create task & run agent",
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Button(
                onClick = { onCommitMenuChange(!commitMenuOpen) },
                enabled = canSubmit,
                shape = RoundedCornerShape(topEnd = 8.dp, bottomEnd = 8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PabrikAccent,
                    contentColor = PabrikBackground,
                ),
                contentPadding = PaddingValues(
                    horizontal = 10.dp,
                    vertical = 8.dp,
                ),
                modifier = Modifier
                    .width(40.dp)
                    .testTag("create_task_commit_menu"),
            ) {
                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = "More commit options",
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        DropdownMenu(
            expanded = commitMenuOpen,
            onDismissRequest = { onCommitMenuChange(false) },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 16.dp, bottom = 76.dp)
                .testTag("create_task_commit_options"),
        ) {
            DropdownMenuItem(
                text = {
                    Column {
                        Text("Create task only")
                        Text(
                            "Add it to the board without starting a worker.",
                            style = MaterialTheme.typography.labelMedium,
                            color = PabrikDim,
                        )
                    }
                },
                enabled = canSubmit,
                onClick = {
                    onCommitMenuChange(false)
                    onCreateOnly()
                },
                modifier = Modifier.testTag("create_task_create_only"),
            )
        }
    }
}

@Composable
private fun kanbanFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = PabrikText,
    unfocusedTextColor = PabrikText,
    focusedBorderColor = PabrikAccent,
    unfocusedBorderColor = PabrikBorder,
    focusedLabelColor = PabrikAccent,
    unfocusedLabelColor = PabrikMuted,
    cursorColor = PabrikAccent,
)
