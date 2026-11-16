package com.pabrik.mobile.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.LowPriority
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** The chat's composer, built as the card the web's is: one bordered rounded surface holding the text, the paperclip and the stop control on the first row, a … */
@Composable
internal fun ChatComposer(
    draft: String,
    attachments: List<ChatAttachment>,
    isSending: Boolean,
    isAttaching: Boolean,
    isWorking: Boolean,
    /** The per-session profile override, verbatim. */
    model: String,
    /** Every configured profile, for the picker. Empty renders no menu. */
    modelProfiles: List<ModelProfile> = emptyList(),
    /** The account-wide default, badged `(active)` in the picker. */
    activeModelProfile: String? = null,
    /** Whether a save is in flight. */
    isSavingModel: Boolean = false,
    onSelectModel: (String) -> Unit = {},
    cwd: String,
    onDraftChanged: (String) -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    /** Turns waiting behind the run, oldest first. */
    queuedMessages: List<QueuedChatMessage> = emptyList(),
    /** Re-read the queue — fired when the panel is opened, see [QueuedStrip]. */
    onRefreshQueue: () -> Unit = {},
    /** Put a waiting turn's text back in the box so it can be edited. */
    onUseQueuedMessage: (QueuedChatMessage) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    // Remembered so the lambdas are current without re-composing the field on every parent recomposition, which is what a plain capture would cost on a streaming …
    val onDraft by rememberUpdatedState(onDraftChanged)
    val onAttachNow by rememberUpdatedState(onAttach)
    val onRemoveNow by rememberUpdatedState(onRemoveAttachment)
    val onSendNow by rememberUpdatedState(onSend)
    val onStopNow by rememberUpdatedState(onStop)
    val onRefreshQueueNow by rememberUpdatedState(onRefreshQueue)
    val onUseQueuedNow by rememberUpdatedState(onUseQueuedMessage)

    val canSend = (draft.isNotBlank() || attachments.isNotEmpty()) && !isSending

    Column(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            // Above the keyboard, not behind it.
            .imePadding()
            .background(PabrikBackground)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = PabrikBackground,
            border = BorderStroke(1.dp, PabrikBorder),
            modifier = Modifier.testTag("chat_composer"),
        ) {
            Column(modifier = Modifier.padding(start = 14.dp, end = 8.dp, top = 4.dp, bottom = 4.dp)) {
                AttachmentStrip(
                    attachments = attachments,
                    isAttaching = isAttaching,
                    onRemove = onRemoveNow,
                )

                // Above the text, and only when there is something in it.
                QueuedStrip(
                    queuedMessages = queuedMessages,
                    onRefresh = onRefreshQueueNow,
                    onUse = onUseQueuedNow,
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    BasicTextField(
                        value = draft,
                        onValueChange = onDraft,
                        modifier = Modifier
                            .weight(1f)
                            .heightIn(min = 44.dp)
                            .padding(vertical = 10.dp)
                            .testTag("chat_composer_input"),
                        textStyle = MaterialTheme.typography.bodyMedium.copy(color = PabrikText),
                        cursorBrush = SolidColor(PabrikText),
                        maxLines = 5,
                        // A phone keyboard's action key would be a *newline* here, matching the web's textarea.
                        decorationBox = { inner ->
                            Box(modifier = Modifier.fillMaxWidth()) {
                                if (draft.isEmpty()) {
                                    Text(
                                        text = "Message",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = PabrikDim,
                                    )
                                }
                                inner()
                            }
                        },
                    )

                    Spacer(Modifier.width(4.dp))

                    IconButton(
                        onClick = onAttachNow,
                        // A decode is in flight, or there is no room left.
                        enabled = !isAttaching && attachments.size < ChatAttachments.MAX_COUNT,
                        modifier = Modifier
                            .size(40.dp)
                            .testTag("chat_attach"),
                    ) {
                        if (isAttaching) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                color = PabrikDim,
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Filled.AttachFile,
                                contentDescription = "Attach an image",
                                tint = if (attachments.size < ChatAttachments.MAX_COUNT) {
                                    PabrikMuted
                                } else {
                                    PabrikDim
                                },
                            )
                        }
                    }

                    Spacer(Modifier.width(2.dp))

                    // One slot for the two verbs that act on a run's *lifetime*: the stop replaces the send rather than sitting beside it, so the row never offers both "start a …
                    if (isWorking) {
                        if (canSend) {
                            IconButton(
                                onClick = onSendNow,
                                modifier = Modifier
                                    .size(40.dp)
                                    .testTag("chat_queue")
                                    .semantics {
                                        role = Role.Button
                                        contentDescription =
                                            "Queue this message behind the running turn"
                                    },
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.LowPriority,
                                    // Violet rather than the accent, so a queue and a send are not the same button in two states: the run keeps going, this does not end it.
                                    contentDescription = null,
                                    tint = PabrikAccent,
                                )
                            }
                        }
                        IconButton(
                            onClick = onStopNow,
                            modifier = Modifier
                                .size(40.dp)
                                .testTag("chat_stop"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Stop,
                                contentDescription = "Stop the run",
                                tint = PabrikError,
                            )
                        }
                    } else {
                        // The circle is decoration; the tag is on the control inside it.
                        Surface(
                            modifier = Modifier.size(36.dp),
                            color = if (canSend) PabrikAccent else PabrikField,
                            shape = CircleShape,
                        ) {
                            IconButton(
                                onClick = onSendNow,
                                enabled = canSend,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .testTag("chat_send"),
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.ArrowUpward,
                                    contentDescription = "Send message",
                                    tint = if (canSend) PabrikBackground else PabrikDim,
                                )
                            }
                        }
                    }
                }

                HorizontalDivider(
                    thickness = 1.dp,
                    color = PabrikBorder.copy(alpha = 0.7f),
                )

                ComposerFooter(
                    model = model,
                    modelProfiles = modelProfiles,
                    activeModelProfile = activeModelProfile,
                    isSavingModel = isSavingModel,
                    onSelectModel = onSelectModel,
                    cwd = cwd,
                )
            }
        }
    }
}

/** The turns waiting behind the run, as a count that opens into a list. */
@Composable
private fun QueuedStrip(
    queuedMessages: List<QueuedChatMessage>,
    onRefresh: () -> Unit,
    onUse: (QueuedChatMessage) -> Unit,
) {
    if (queuedMessages.isEmpty()) return

    var expanded by remember { mutableStateOf(false) }
    val onUseNow by rememberUpdatedState(onUse)

    Column(modifier = Modifier.fillMaxWidth().testTag("chat_queued_strip")) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable {
                    val opening = !expanded
                    expanded = opening
                    if (opening) onRefresh()
                }
                .padding(start = 2.dp, top = 8.dp, bottom = 2.dp)
                .testTag("chat_queued_toggle")
                .semantics {
                    role = Role.Button
                    contentDescription = if (expanded) {
                        "Hide the ${queuedMessages.size} queued messages"
                    } else {
                        "Show the ${queuedMessages.size} queued messages"
                    }
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Filled.LowPriority,
                contentDescription = null,
                tint = PabrikAccent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = queuedLabel(queuedMessages.size),
                style = MaterialTheme.typography.labelSmall,
                color = PabrikMuted,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.weight(1f))
            Icon(
                imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = PabrikDim,
                modifier = Modifier.size(16.dp),
            )
        }

        if (expanded) {
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = PabrikBackgroundRaised,
                border = BorderStroke(1.dp, PabrikBorder),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 6.dp)
                    .testTag("chat_queued_panel"),
            ) {
                Column(
                    modifier = Modifier
                        // Bounded, so a chat with thirty queued turns cannot push the input off the top of a phone screen.
                        .heightIn(max = 200.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    queuedMessages.forEach { queued ->
                        QueuedRow(queued = queued, onUse = { onUseNow(queued) })
                    }
                }
            }
        }
    }
}

/** One waiting turn, tappable to bring its text back into the box. */
@Composable
private fun QueuedRow(
    queued: QueuedChatMessage,
    onUse: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onUse)
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .testTag("chat_queued_${queued.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                // A queued row can carry an image and no text — the client sends `image_urls` on the same POST as `queue_message`, and Migration 054 made the column nullable so …
                text = queued.message.ifBlank { "Image only" },
                style = MaterialTheme.typography.bodySmall,
                color = PabrikText,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = "Tap to edit before it runs",
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
            )
        }
    }
}

/** The count, worded. */
internal fun queuedLabel(count: Int): String =
    if (count == 1) "1 queued" else "$count queued"

/** The attached images, as removable thumbnails. */
@Composable
private fun AttachmentStrip(
    attachments: List<ChatAttachment>,
    isAttaching: Boolean,
    onRemove: (String) -> Unit,
) {
    if (attachments.isEmpty() && !isAttaching) return

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(top = 8.dp, bottom = 2.dp)
            .testTag("chat_attachments_strip"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        attachments.forEach { attachment ->
            AttachmentThumbnail(
                attachment = attachment,
                onRemove = { onRemove(attachment.id) },
            )
        }
    }
}

/** One thumbnail with a remove button on its corner. */
@Composable
private fun AttachmentThumbnail(
    attachment: ChatAttachment,
    onRemove: () -> Unit,
) {
    Box(modifier = Modifier.size(56.dp).testTag("chat_attachment_${attachment.id}")) {
        val bitmap = remember(attachment.dataUrl) { attachment.thumbnail() }
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = "Attached image",
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(PabrikField),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(PabrikField),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "image",
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikDim,
                )
            }
        }

        Surface(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(2.dp)
                .size(20.dp)
                .clip(CircleShape),
            color = PabrikBackground,
            shape = CircleShape,
        ) {
            IconButton(
                onClick = onRemove,
                modifier = Modifier
                    .size(20.dp)
                    .testTag("chat_attachment_remove_${attachment.id}"),
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Remove image",
                    tint = PabrikMuted,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
    }
}

/** The turn's facts, under a divider. */
@Composable
private fun ComposerFooter(
    model: String,
    modelProfiles: List<ModelProfile>,
    activeModelProfile: String?,
    isSavingModel: Boolean,
    onSelectModel: (String) -> Unit,
    cwd: String,
) {
    // Nothing to expand means no expander: a chevron that toggles one line when both lines are already visible is a control that does nothing.
    val canExpand = cwd.isNotBlank()
    var expanded by remember { mutableStateOf(false) }

    // The cascade's answer, computed once and used by both the chip's label and the picker's tick.
    val effective = effectiveProfileName(model, activeModelProfile)
    // A menu with nothing in it is a menu that opens onto an empty list, so the chip degrades to the plain label it used to be.
    val canPickModel = modelProfiles.isNotEmpty() || model.isNotEmpty()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(36.dp)
            .padding(start = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (effective != null) {
            if (canPickModel) {
                ModelPicker(
                    effectiveProfile = effective,
                    profiles = modelProfiles,
                    activeProfile = activeModelProfile,
                    selectedProfile = model,
                    isSaving = isSavingModel,
                    onSelect = onSelectModel,
                )
            } else {
                FooterFact(label = "Model", value = effective, tag = "chat_footer_model")
            }
            Spacer(Modifier.width(12.dp))
        }
        if (canExpand) {
            FooterFact(
                label = "Cwd",
                value = cwd,
                // Collapsed is the *short* form with a leading ellipsis, which is what a phone-width row can afford; expanded shows the path from the root, because the part a …
                maxLines = if (expanded) 3 else 1,
                tag = "chat_footer_cwd",
            )
        }

        Spacer(Modifier.weight(1f))

        if (canExpand) {
            IconButton(
                onClick = { expanded = !expanded },
                modifier = Modifier
                    .size(32.dp)
                    .testTag("chat_footer_expand")
                    .semantics {
                        contentDescription = if (expanded) "Hide the working directory" else "Show the working directory"
                    },
            ) {
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = PabrikDim,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/** The model chip and its menu. */
@Composable
private fun ModelPicker(
    effectiveProfile: String,
    profiles: List<ModelProfile>,
    activeProfile: String?,
    selectedProfile: String,
    isSaving: Boolean,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    // The action a row fires is current without capturing the lambda the composable was composed with — the same reason the composer's other callbacks go through …
    val onSelectNow by rememberUpdatedState(onSelect)

    Box {
        Surface(
            onClick = { expanded = true },
            shape = RoundedCornerShape(6.dp),
            color = Color.Transparent,
            contentColor = PabrikText,
            modifier = Modifier
                .testTag("chat_footer_model")
                .semantics {
                    role = Role.Button
                    contentDescription = "Model $effectiveProfile. Change model"
                },
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 2.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Model",
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikDim,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = effectiveProfile,
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 140.dp),
                )
                // The affordance.
                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = PabrikDim,
                    modifier = Modifier
                        .padding(start = 3.dp)
                        .size(12.dp),
                )
            }
        }

        DropdownMenu(
            expanded = expanded,
            // Dismissed on a *pick* as well as on an outside tap, or the menu would stay open over the transcript after the choice landed.
            onDismissRequest = { expanded = false },
            modifier = Modifier
                .background(PabrikBackgroundRaised, RoundedCornerShape(10.dp))
                .border(1.dp, PabrikBorder, RoundedCornerShape(10.dp))
                .widthIn(min = 240.dp, max = 320.dp)
                .testTag("chat_model_menu"),
            containerColor = PabrikBackgroundRaised,
        ) {
            // "Default" clears the per-session override rather than naming a profile, and the server treats the empty string as that instruction — so the row's tick answers …
            ProfileMenuRow(
                title = "Default (top-level config)",
                detail = "Follows the agent marked active in settings.",
                isChecked = selectedProfile.isEmpty(),
                enabled = !isSaving,
                testTag = "chat_model_default",
                onClick = {
                    expanded = false
                    onSelectNow("")
                },
            )

            profiles.forEach { profile ->
                ProfileMenuRow(
                    title = profile.name,
                    detail = profile.detail,
                    isChecked = effectiveProfile == profile.name,
                    isActiveDefault = activeProfile == profile.name,
                    enabled = !isSaving,
                    testTag = "chat_model_${profile.name}",
                    onClick = {
                        expanded = false
                        onSelectNow(profile.name)
                    },
                )
            }

            if (profiles.isEmpty()) {
                Text(
                    text = "No agents configured. Add one in Settings.",
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikMuted,
                    modifier = Modifier
                        .padding(horizontal = 14.dp, vertical = 10.dp)
                        .testTag("chat_model_empty"),
                )
            }
        }
    }
}

/** One row of the profile menu. */
@Composable
private fun ProfileMenuRow(
    title: String,
    detail: String,
    isChecked: Boolean,
    enabled: Boolean,
    testTag: String,
    onClick: () -> Unit,
    isActiveDefault: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .testTag(testTag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PabrikText,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (isActiveDefault) {
                    Spacer(Modifier.width(6.dp))
                    Surface(
                        shape = RoundedCornerShape(4.dp),
                        color = PabrikAccent.copy(alpha = 0.18f),
                    ) {
                        Text(
                            text = "active",
                            style = MaterialTheme.typography.labelSmall,
                            color = PabrikAccent,
                            modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
                        )
                    }
                }
            }
            if (detail.isNotEmpty()) {
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (isChecked) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = "In use",
                tint = PabrikAccent,
                modifier = Modifier
                    .padding(start = 10.dp)
                    .size(16.dp),
            )
        }
    }
}

/** One labelled fact in the footer. */
@Composable
private fun FooterFact(
    label: String,
    value: String,
    maxLines: Int = 1,
    tag: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag(tag)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = value,
            style = MaterialTheme.typography.labelSmall,
            color = PabrikMuted,
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
