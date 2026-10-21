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

/**
 * The chat's composer, built as the card the web's is: one bordered rounded
 * surface holding the text, the paperclip and the stop control on the first
 * row, a divider, and the turn's facts on the second.
 *
 * ### What is a control here and what is not
 *
 * The web's footer row is five dropdowns. Two of them are real on a phone: the
 * model, because a profile is picked from a list the server hands us and the
 * choice is persisted per session, and the `cwd` expander, because there is a
 * whole path hidden behind one line. The other three are wired to nothing, and
 * a dropdown that opens an empty menu is worse than no dropdown — it teaches
 * the reader that the footer is decoration. So those stay as text.
 *
 * The chevron is drawn only when there is a `cwd` to expand. A permanently
 * mounted expander is a control that lies about whether anything is hidden.
 *
 * ### The stop control lives here, not in the app bar
 *
 * It replaced the top-bar stop, so there is exactly one answer to "can I stop
 * this run". Two of them disagreeing — one present, one gone, during a
 * reconnect — is the same lie told twice, and a reader who has learned to
 * distrust the composer distrusts the send button too.
 *
 * ### Queue is a third control, and it sits *beside* the stop
 *
 * Sending a turn and queueing one are the same request — `POST /llm/session`
 * with a `queue_message` — and the server decides which it is: a worker that
 * is already live takes the message into `session_queue_messages` and drains
 * it when it finishes (`workflow.zig:688` and the loop check at
 * `workflow.zig:1565`), an idle one starts immediately. So the client never
 * picks a different endpoint; it only changes *when* it will let the reader
 * press send.
 *
 * That is what makes the queue button necessary and why it is not a second
 * send: a reader watching a three-minute tool call has a follow-up in their
 * head right now, and before this the only way to act on it was to stop the run
 * and restart it — throwing away the work in progress. Queueing is the third
 * verb, and it is neither of the other two, so it gets its own control rather
 * than a long-press nobody will discover.
 *
 * It appears only while there is something to queue. A queue button over an
 * empty box is a control that does nothing, which is the same lie this
 * composer already refuses to tell about the model chip and the cwd expander.
 *
 * ### Why `BasicTextField` and not `TextField`
 *
 * `TextField` draws its own container and indicator, and there is no way to
 * remove both without leaving a rounded grey block inside a rounded bordered
 * card — two frames for one input. The card is the frame here, so the field
 * draws text and a cursor and nothing else.
 */
@Composable
internal fun ChatComposer(
    draft: String,
    attachments: List<ChatAttachment>,
    isSending: Boolean,
    isAttaching: Boolean,
    isWorking: Boolean,
    /**
     * The per-session profile override, verbatim.
     *
     * The **raw** column, not what the chip shows: it is `""` on every chat
     * nobody has picked a profile for, and the chip's label is the cascade
     * over this and [activeModelProfile] — see [effectiveProfileName]. Keeping
     * the raw value as the single input is what stops the chip and the
     * picker's tick from being able to disagree.
     */
    model: String,
    /** Every configured profile, for the picker. Empty renders no menu. */
    modelProfiles: List<ModelProfile> = emptyList(),
    /** The account-wide default, badged `(active)` in the picker. */
    activeModelProfile: String? = null,
    /**
     * Whether a save is in flight.
     *
     * The menu is not *hidden* while this is true — a menu that vanishes
     * under the reader's thumb is worse than a slow one — but its rows are
     * inert, because a second pick would race the first.
     */
    isSavingModel: Boolean = false,
    onSelectModel: (String) -> Unit = {},
    cwd: String,
    onDraftChanged: (String) -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    /**
     * Turns waiting behind the run, oldest first. Empty draws no strip at all.
     *
     * Not fetched here and not cached: the list is server state with no replay,
     * so it is [ChatViewModel]'s to own and re-read when the panel opens.
     */
    queuedMessages: List<QueuedChatMessage> = emptyList(),
    /** Re-read the queue — fired when the panel is opened, see [QueuedStrip]. */
    onRefreshQueue: () -> Unit = {},
    /** Put a waiting turn's text back in the box so it can be edited. */
    onUseQueuedMessage: (QueuedChatMessage) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    // Remembered so the lambdas are current without re-composing the field on
    // every parent recomposition, which is what a plain capture would cost on
    // a streaming turn.
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
            // Above the keyboard, not behind it. `adjustResize` is declared in
            // the manifest, but on API 30+ that no longer resizes the window —
            // the IME overlap arrives as an inset instead, so this is the line
            // that keeps the composer reachable while the reader types.
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

                // Above the text, and only when there is something in it. This
                // strip is the answer to "where did the message I just sent
                // go" — a queued turn is in no transcript and no bubble until
                // the worker drains it, so without a list on screen a queued
                // message and a lost one look identical.
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
                        // A phone keyboard's action key would be a *newline*
                        // here, matching the web's textarea. The send button is
                        // the send; a keyboard that sends on Enter is a
                        // surprise on a device where Enter is also how you
                        // finish a sentence.
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
                        // Both states refuse the tap, and the reason is on the
                        // control rather than in a toast.
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

                    // One slot for the two verbs that act on a run's
                    // *lifetime*: the stop replaces the send rather than
                    // sitting beside it, so the row never offers both "start a
                    // turn" and "end a turn" at once.
                    //
                    // Queueing is not one of those two — it does not touch the
                    // run in progress at all, it adds a turn behind it — so it
                    // gets its own control next to the stop rather than
                    // displacing either.
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
                                    // Violet rather than the accent, so a
                                    // queue and a send are not the same button
                                    // in two states: the run keeps going, this
                                    // does not end it.
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
                        // The circle is decoration; the tag is on the control
                        // inside it. A `testTag` on the `Surface` describes a
                        // container that has no enabled state of its own, so
                        // every assertion about whether send is available was
                        // reading a node that could never answer.
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

/**
 * The turns waiting behind the run, as a count that opens into a list.
 *
 * This is the web's `queuedMessages` panel (`FileInput.vue:753`) rebuilt for a
 * phone: the web puts the button on the input row beside the textarea, and
 * there is no room for it there — the row is already text, paperclip and send,
 * and a fourth control steals width from the only thing on the card the reader
 * came here to use. So the count is its own line above the text, which is
 * also where the reader's eye goes after queueing something.
 *
 * **Nothing queued means nothing drawn.** Not a zero, not a disabled chip: an
 * empty queue is the state the reader is in almost every turn, and a permanent
 * "0 queued" is a control that is telling them there is nothing on the only
 * row where something else might be.
 *
 * The list is re-read when it is *opened* rather than only on every frame:
 * between them, the rows on screen are built from SSE frames the reader can
 * watch arrive, and a drained turn that is still listed would have them
 * compose a duplicate of one the agent is already answering.
 */
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
                        // Bounded, so a chat with thirty queued turns cannot
                        // push the input off the top of a phone screen.
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

/**
 * One waiting turn, tappable to bring its text back into the box.
 *
 * The row does not leave the queue when it is tapped. The turn belongs to the
 * server — the only thing that removes it is the worker draining it — so
 * copying the text out is the whole gesture, and the reader is told so on the
 * row rather than discovering it by sending the message twice.
 */
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
                // A queued row can carry an image and no text — the client
                // sends `image_urls` on the same POST as `queue_message`, and
                // Migration 054 made the column nullable so those rows can
                // exist. An empty row would render as a blank the reader
                // cannot tap with any confidence about.
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

/**
 * The count, worded. Split out so the plural is a rule with a test rather than
 * an inline `if`.
 */
internal fun queuedLabel(count: Int): String =
    if (count == 1) "1 queued" else "$count queued"

/**
 * The attached images, as removable thumbnails.
 *
 * Laid out above the text rather than inline with it, because the text field
 * is a fixed height and a chip row beside it would steal width from the only
 * thing on this card the reader came here to use.
 *
 * The row scrolls horizontally rather than wrapping: a wrapped second line
 * pushes the send button down as each image is added, so the target the reader
 * is aiming at moves *while* they are aiming at it.
 */
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

/**
 * One thumbnail with a remove button on its corner.
 *
 * The image is decoded from the same base64 the turn will send, rather than
 * from a separate cached copy of the file: the reader's check that they picked
 * the right screenshot is a check of the bytes that are about to go, and a
 * thumbnail of a *different* copy is a thumbnail that can lie.
 *
 * A decode that fails renders as a labelled placeholder rather than an empty
 * box — a 56dp hole in the strip reads as a broken layout, and "image" at
 * least tells the reader the attachment is still there to be removed.
 */
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

/**
 * The turn's facts, under a divider.
 *
 * The model is a control; the working directory is not. See [ChatComposer] for
 * why the cwd stays text — the honest reason it has nothing to change *to* is
 * also the honest reason the model is now a menu: a profile is picked from a
 * list the server hands us, and the per-session choice is persisted with a
 * `PUT` the backend has an endpoint for.
 */
@Composable
private fun ComposerFooter(
    model: String,
    modelProfiles: List<ModelProfile>,
    activeModelProfile: String?,
    isSavingModel: Boolean,
    onSelectModel: (String) -> Unit,
    cwd: String,
) {
    // Nothing to expand means no expander: a chevron that toggles one line
    // when both lines are already visible is a control that does nothing.
    val canExpand = cwd.isNotBlank()
    var expanded by remember { mutableStateOf(false) }

    // The cascade's answer, computed once and used by both the chip's label and
    // the picker's tick. Two independent readings of "which agent is this"
    // is how a chip and its own menu end up disagreeing.
    val effective = effectiveProfileName(model, activeModelProfile)
    // A menu with nothing in it is a menu that opens onto an empty list, so
    // the chip degrades to the plain label it used to be. A per-session choice
    // on its own is enough to keep the menu: the reader then has a way to undo
    // it, which is the one row a picker with a single implicit choice needs.
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
                // Collapsed is the *short* form with a leading ellipsis, which
                // is what a phone-width row can afford; expanded shows the
                // path from the root, because the part a reader needs is
                // usually the leaf and never the home directory.
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

/**
 * The model chip and its menu.
 *
 * This is the composer's one dropdown, and it is the mirror of the web's
 * `ChatView.vue` profile picker: same cascade, same `(active)` badge, same
 * "Default (top-level config)" row that clears the per-session override.
 *
 * **`DropdownMenu`, not a bottom sheet.** The web anchors this to the chip and
 * a phone has the same affordance — Material's menu is a `Popup` positioned
 * against its anchor, so it opens *upward* out of a footer pinned to the
 * bottom of the screen, which is where a thumb is not. A sheet would have
 * covered the transcript, and this menu is short.
 *
 * The menu is a child of the `Box` around the chip, not of the footer `Row`:
 * a `Row` child that grows would push the cwd and the expander sideways the
 * moment the menu opened.
 */
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
    // The action a row fires is current without capturing the lambda the
    // composable was composed with — the same reason the composer's other
    // callbacks go through `rememberUpdatedState`.
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
                // The affordance. Without it the chip is a label that happens
                // to be tappable, and a tappable label is the one control a
                // reader has the least reason to try.
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
            // Dismissed on a *pick* as well as on an outside tap, or the menu
            // would stay open over the transcript after the choice landed.
            onDismissRequest = { expanded = false },
            modifier = Modifier
                .background(PabrikBackgroundRaised, RoundedCornerShape(10.dp))
                .border(1.dp, PabrikBorder, RoundedCornerShape(10.dp))
                .widthIn(min = 240.dp, max = 320.dp)
                .testTag("chat_model_menu"),
            containerColor = PabrikBackgroundRaised,
        ) {
            // "Default" clears the per-session override rather than naming a
            // profile, and the server treats the empty string as that
            // instruction — so the row's tick answers the *cascade*, not the
            // column: a chat with no override but an account-wide active
            // profile is already running on a named one.
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

/**
 * One row of the profile menu.
 *
 * [isActiveDefault] is the `(active)` badge and [isChecked] is the tick, and
 * they are different facts: one profile can be the account-wide default while
 * a *different* one is in force for this chat, and a picker that conflated
 * them would tell the reader the wrong profile is about to be used.
 */
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

/**
 * One labelled fact in the footer.
 *
 * The label is a fixed-width prefix rather than a trailing dim suffix, so two
 * facts on one row start their values at the same x — the alternative is two
 * values that begin wherever their labels happened to end, which reads as
 * misalignment on a row this short.
 */
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
