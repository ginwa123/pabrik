package com.pabrik.mobile.recents

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.projects.ProjectChatRow
import com.pabrik.mobile.projects.ProjectRow
import com.pabrik.mobile.projects.CreateTaskRow
import com.pabrik.mobile.projects.ProjectsActions
import com.pabrik.mobile.projects.ProjectsState
import com.pabrik.mobile.projects.ProjectTypes
import com.pabrik.mobile.projects.SeeAllChatsRow
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** Reserved key for the row that navigates to the full recents list. */
private const val SEE_ALL_KEY = "__recents_see_all__"

/** The destination row's test tag. */
internal const val SEE_ALL_ROW_TAG = "recents_see_all"

/** Reserved key for the recents list's own loading/error/empty row. */
private const val CHATS_STATE_KEY = "__chats_state__"

/** Reserved key for the recents section header, which is also its sticky pin. */
private const val RECENTS_HEADER_KEY = "__recents_header__"

private const val PROJECTS_HEADER_KEY = "__projects_header__"

/** The gap above the Projects header, as its own row. */
private const val PROJECTS_GAP_KEY = "__projects_gap__"

private const val CONTENT_TYPE_SENTINEL = "sentinel"

private const val CONTENT_TYPE_CHAT = "chat"

private const val CONTENT_TYPE_STATE = "state"

private const val CONTENT_TYPE_SECTION_HEADER = "section-header"

private const val CONTENT_TYPE_PROJECT = "project"

/** How many chat rows the drawer asks the ViewModel for, restated here as the row count it renders. */
internal fun recentsVisibleChatCount(totalChats: Int): Int =
    minOf(totalChats, RecentsApi.DRAWER_PREVIEW_ROWS)

@Composable
fun RecentsSidebar(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
    /** Read once per composition, not once per recomposition. */
    nowEpochMillis: Long = remember { System.currentTimeMillis() },
    /** Leave the sidebar because a chat was opened — a chat is a destination. */
    onOpenChat: () -> Unit = {},
    isLoading: Boolean = false,
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    /** Whether the server says the workspace holds chats the drawer is not showing. */
    hasMoreChats: Boolean = false,
    /** The server's full filtered count for this workspace; 0 when it sent none. */
    chatsTotal: Int = 0,
    /** Leave the drawer for the full recents list. The row is a destination. */
    onOpenAllChats: () -> Unit = {},
    /** Session ids with a live worker, so a chat the user is not in can still be seen to be busy. */
    runningSessionIds: Set<String> = emptySet(),
    /** False when the server runs without `--auth`. */
    isAuthEnabled: Boolean = false,
    signedInEmail: String? = null,
    isLoggingOut: Boolean = false,
    onLogout: () -> Unit = {},
    /** The Projects section, and the four things a reader can do to it. */
    projects: ProjectsState = ProjectsState.Empty,
    projectActions: ProjectsActions = ProjectsActions.None,
    /** Whether the Recents section is unfolded, and the tap that folds it. */
    recentsExpanded: Boolean = true,
    onToggleRecents: () -> Unit = {},
    /** The top-level "New Chat" row: create a chat in the workspace's default project and open it. */
    isCreatingChat: Boolean = false,
    onNewChat: () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .padding(horizontal = 12.dp),
    ) {
        Spacer(Modifier.height(12.dp))

        SidebarBody(
            modifier = Modifier.weight(1f),
            workspaces = workspaces,
            chats = chats,
            selectedWorkspaceId = selectedWorkspaceId,
            selectedChatId = selectedChatId,
            onWorkspaceSelected = onWorkspaceSelected,
            onChatSelected = onChatSelected,
            nowEpochMillis = nowEpochMillis,
            onOpenChat = onOpenChat,
            isLoading = isLoading,
            errorMessage = errorMessage,
            onRetry = onRetry,
            hasMoreChats = hasMoreChats,
            chatsTotal = chatsTotal,
            onOpenAllChats = onOpenAllChats,
            runningSessionIds = runningSessionIds,
            projects = projects,
            projectActions = projectActions,
            recentsExpanded = recentsExpanded,
            onToggleRecents = onToggleRecents,
            isCreatingChat = isCreatingChat,
            onNewChat = onNewChat,
        )

        // Deliberately outside the body.
        if (isAuthEnabled) {
            AccountFooter(
                email = signedInEmail,
                isLoggingOut = isLoggingOut,
                onLogout = onLogout,
            )
        }
    }
}

/** The workspace picker, the stale-data notice and the recents list. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SidebarBody(
    workspaces: List<WorkspaceOption>,
    chats: List<ChatSummary>,
    selectedWorkspaceId: String?,
    selectedChatId: String?,
    onWorkspaceSelected: (String) -> Unit,
    onChatSelected: (String) -> Unit,
    nowEpochMillis: Long,
    /** Leave the sidebar because a chat was opened — a chat is a destination. */
    onOpenChat: () -> Unit,
    isLoading: Boolean,
    errorMessage: String?,
    onRetry: () -> Unit,
    /** Whether more chats exist beyond the preview, and the tap that leaves the drawer for them. */
    hasMoreChats: Boolean,
    chatsTotal: Int,
    onOpenAllChats: () -> Unit,
    runningSessionIds: Set<String>,
    projects: ProjectsState,
    projectActions: ProjectsActions,
    recentsExpanded: Boolean,
    onToggleRecents: () -> Unit,
    /** The top-level "New Chat" row's busy flag and its tap. */
    isCreatingChat: Boolean,
    onNewChat: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        if (workspaces.isEmpty()) {
            // No workspace means no scope, so there is nothing to scope chats to.
            when {
                isLoading -> SidebarPlaceholder(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_loading",
                    title = "Loading workspaces",
                    detail = "Fetching your workspaces from Pabrik.",
                    showSpinner = true,
                )

                errorMessage != null -> SidebarError(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_error",
                    message = errorMessage,
                    onRetry = onRetry,
                )

                else -> SidebarPlaceholder(
                    modifier = Modifier.weight(1f),
                    testTag = "sidebar_no_workspaces",
                    title = "No workspaces yet",
                    detail = "Create a workspace on the web app and it will show up here.",
                )
            }
            return@Column
        }

        WorkspaceDropdown(
            workspaces = workspaces,
            selectedWorkspaceId = selectedWorkspaceId,
            onWorkspaceSelected = onWorkspaceSelected,
        )

        // Top-level "New Chat", above the scroller and outside it.
        if (selectedWorkspaceId != null) {
            NewChatRow(
                isBusy = isCreatingChat,
                onClick = onNewChat,
            )
        }

        // Rows survived a failed refresh.
        if (errorMessage != null && !isLoading) {
            Spacer(Modifier.height(10.dp))
            StaleDataNotice(
                modifier = Modifier.testTag("sidebar_stale_notice"),
                message = errorMessage,
                onRetry = onRetry,
            )
        }

        // Half of what this was. 24dp of nothing between "New Chat" and the first section read as two unrelated blocks on a phone, and a drawer whose sections cannot be …
        Spacer(Modifier.height(12.dp))

        val visibleChats = selectedWorkspaceId
            ?.let { workspaceId -> recentChatsForWorkspace(chats, workspaceId) }
            .orEmpty()

        // Which project rows are busy, resolved once for the whole section rather than per row — the header asks the same question, and N rows each re-scanning the …
        val runningProjectIds = projects.runningProjectIds(runningSessionIds, visibleChats)

        // The preview the drawer renders, and the one thing it does not decide for itself.
        val renderedChats = visibleChats.take(recentsVisibleChatCount(visibleChats.size))

        // The destination row, and whether it is honest to offer at all.
        val canOpenAllChats =
            visibleChats.size > RecentsApi.DRAWER_PREVIEW_ROWS || hasMoreChats

        val listState = rememberLazyListState()

        // A workspace switch shows a different set of rows at the same indices, so the old scroll offset would land the user mid-list in a workspace they have not looked …
        LaunchedEffect(selectedWorkspaceId) {
            listState.scrollToItem(0)
        }

        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                // Not the transcript's `chat_message_list`.
                .testTag("sidebar_chat_list")
                .selectableGroup(),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // ── Recents ───────────────────────────────────────────────────
            stickyHeader(key = RECENTS_HEADER_KEY, contentType = CONTENT_TYPE_SECTION_HEADER) {
                SidebarSectionHeader(
                    title = "Recent",
                    // The server's count, not `visibleChats.size`.
                    itemCount = if (chatsTotal > 0) chatsTotal else visibleChats.size,
                    unit = "chats",
                    expanded = recentsExpanded,
                    onClick = onToggleRecents,
                    testTag = "recents_section_header",
                )
            }

            if (recentsExpanded) {
                if (visibleChats.isEmpty()) {
                    // A row in the list, not a weighted placeholder beside it.
                    item(key = CHATS_STATE_KEY, contentType = CONTENT_TYPE_STATE) {
                        when {
                            isLoading -> SidebarPlaceholder(
                                testTag = "chats_loading",
                                title = "Loading chats",
                                detail = "Fetching the most recent chats in this workspace.",
                                showSpinner = true,
                            )

                            errorMessage != null -> SidebarError(
                                testTag = "chats_error",
                                message = errorMessage,
                                onRetry = onRetry,
                            )

                            else -> EmptyChats()
                        }
                    }
                } else {
                    items(
                        items = renderedChats,
                        key = { chat -> chat.id },
                        contentType = { CONTENT_TYPE_CHAT },
                    ) { chat ->
                        ChatRow(
                            chat = chat,
                            selected = chat.id == selectedChatId,
                            isRunning = chat.id in runningSessionIds,
                            nowEpochMillis = nowEpochMillis,
                            onClick = {
                                onChatSelected(chat.id)
                                onOpenChat()
                            },
                        )
                    }

                    // A destination, not a toggle: it closes the drawer and pushes a route.
                    if (canOpenAllChats) {
                        item(key = SEE_ALL_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                            SeeAllChatsRow(
                                testTag = SEE_ALL_ROW_TAG,
                                subject = "in this workspace",
                                onClick = onOpenAllChats,
                            )
                        }
                    }
                }
            }

            // ── Projects ──────────────────────────────────────────────────
            item(key = PROJECTS_GAP_KEY, contentType = CONTENT_TYPE_SENTINEL) {
                Spacer(Modifier.height(8.dp))
            }

            stickyHeader(key = PROJECTS_HEADER_KEY, contentType = CONTENT_TYPE_SECTION_HEADER) {
                SidebarSectionHeader(
                    title = "Projects",
                    itemCount = projects.items.size,
                    unit = "projects",
                    expanded = projects.expanded,
                    onClick = projectActions.onToggleSection,
                    testTag = "projects_section_header",
                    // Read once per composition of the body rather than per row, so N projects do not each re-scan the loaded chat pages for the same answer.
                    isRunning = runningProjectIds.isNotEmpty(),
                )
            }

            if (!projects.expanded) return@LazyColumn

            if (projects.isEmpty && !projects.isLoading && projects.errorMessage == null) {
                item(key = "projects_empty", contentType = CONTENT_TYPE_STATE) {
                    SidebarPlaceholder(
                        testTag = "projects_empty",
                        title = "No projects yet",
                        // Vue's copy points at the "+" it has and this does not have, so it would send the reader looking for a button that is not on this screen.
                        detail = "Create one on the web app and it will show up here.",
                    )
                }
                return@LazyColumn
            }

            if (projects.isLoading && projects.items.isEmpty()) {
                item(key = "projects_loading", contentType = CONTENT_TYPE_STATE) {
                    SidebarPlaceholder(
                        testTag = "projects_loading",
                        title = "Loading projects",
                        detail = "Fetching the projects in this workspace.",
                        showSpinner = true,
                    )
                }
                return@LazyColumn
            }

            if (projects.errorMessage != null && projects.items.isEmpty()) {
                item(key = "projects_error", contentType = CONTENT_TYPE_STATE) {
                    SidebarError(
                        testTag = "projects_error",
                        message = projects.errorMessage,
                        onRetry = projectActions.onRetry,
                    )
                }
                return@LazyColumn
            }

            items(
                items = projects.items,
                key = { project -> project.id },
                contentType = { CONTENT_TYPE_PROJECT },
            ) { project ->
                val expanded = projects.isProjectExpanded(project.id)
                Column {
                    ProjectRow(
                        project = project,
                        expanded = expanded,
                        onClick = { projectActions.onToggleItem(project.id) },
                        isRunning = project.id in runningProjectIds,
                    )

                    if (expanded) {
                        val preview = projects.previewFor(project.id)
                        Column(
                            modifier = Modifier
                                .padding(start = 12.dp)
                                .padding(start = 12.dp),
                        ) {
                            // Above the rows, not below: the thing the reader just made should be the first thing they see, and the list grows downward, so a create affordance at the bottom …
                            if (project.itemType != ProjectTypes.ROUTINE) {
                                CreateTaskRow(
                                    projectName = project.id,
                                    isBusy = projects.creatingTaskItemId == project.id,
                                    onClick = {
                                        // Same fallback "See all chats" uses one row below: a project read back from cache can carry a blank workspace, and the create endpoint is nested under it — so a …
                                        projectActions.onCreateTask(
                                            project.copy(
                                                workspaceId = project.workspaceId
                                                    .ifEmpty { selectedWorkspaceId.orEmpty() },
                                            ),
                                        )
                                    },
                                )
                            }

                            preview.forEach { chat ->
                                ProjectChatRow(
                                    chat = chat,
                                    selected = chat.id == selectedChatId,
                                    isRunning = chat.id in runningSessionIds,
                                    nowEpochMillis = nowEpochMillis,
                                    onClick = {
                                        onChatSelected(chat.id)
                                        // A chat is a destination, and this row opens the identical one the Recent list opens — the task id IS the session id.
                                        onOpenChat()
                                    },
                                )
                            }

                            if (projects.shouldOfferSeeAllChats(project.id)) {
                                SeeAllChatsRow(
                                    testTag = "project_see_all_${project.id}",
                                    subject = "in this project",
                                    onClick = {
                                        projectActions.onOpenAllChats(
                                            project.workspaceId.ifEmpty { selectedWorkspaceId.orEmpty() },
                                            project.id,
                                        )
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Who is signed in, and the one control that ends it. */
@Composable
private fun AccountFooter(
    email: String?,
    isLoggingOut: Boolean,
    onLogout: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
    ) {
        HorizontalDivider(
            modifier = Modifier.testTag("sidebar_account_divider"),
            color = PabrikBorder,
        )

        Spacer(Modifier.height(10.dp))

        Text(
            text = "SIGNED IN AS",
            modifier = Modifier.padding(horizontal = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            color = PabrikDim,
        )

        Text(
            text = email?.takeIf { it.isNotBlank() } ?: "Your account",
            modifier = Modifier
                .padding(horizontal = 8.dp)
                .testTag("sidebar_account_email"),
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Spacer(Modifier.height(4.dp))

        TextButton(
            onClick = onLogout,
            enabled = !isLoggingOut,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("sidebar_logout"),
        ) {
            Text(
                text = if (isLoggingOut) "Logging out…" else "Log out",
                color = PabrikDim,
            )
        }

        Spacer(Modifier.height(4.dp))
    }
}

/** The row under the last chat: a spinner while the next page is in flight, and an end-of-list marker only once the server has said there is nothing more. */
@Composable
internal fun ChatListFooter(
    isLoading: Boolean,
    hasReachedEnd: Boolean,
    /** Why the last page failed, or null. */
    errorMessage: String? = null,
    onRetry: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .testTag("chats_list_footer"),
        contentAlignment = Alignment.Center,
    ) {
        when {
            isLoading -> CircularProgressIndicator(
                modifier = Modifier
                    .size(18.dp)
                    .testTag("chats_load_more_spinner"),
                strokeWidth = 2.dp,
                color = PabrikMuted,
            )

            // Checked before the end marker: a page that failed is not the end of the list, and saying "No older chats" over a network error is the one claim a reader cannot …
            errorMessage != null -> Text(
                text = "$errorMessage — tap to retry",
                modifier = Modifier
                    .clickable(onClick = onRetry)
                    .testTag("chats_load_more_error"),
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
                textAlign = TextAlign.Center,
            )

            hasReachedEnd -> Text(
                text = "No older chats",
                modifier = Modifier.testTag("chats_list_end"),
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
            )

            // More may exist and nothing is in flight.
            else -> Text(
                text = "Scroll for older chats",
                modifier = Modifier.testTag("chats_load_more_hint"),
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
            )
        }
    }
}

@Composable
private fun WorkspaceDropdown(
    workspaces: List<WorkspaceOption>,
    selectedWorkspaceId: String?,
    onWorkspaceSelected: (String) -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val selectedWorkspace = workspaces.firstOrNull { it.id == selectedWorkspaceId }
    val selectedName = selectedWorkspace?.displayName ?: "Select workspace"

    Box(modifier = Modifier.fillMaxWidth()) {
        Surface(
            onClick = { expanded = true },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("workspace_dropdown")
                .semantics {
                    role = Role.Button
                    contentDescription = "Select workspace. Current: $selectedName"
                    stateDescription = if (expanded) "Expanded" else "Collapsed"
                },
            shape = RoundedCornerShape(14.dp),
            color = PabrikField,
            contentColor = PabrikText,
            border = BorderStroke(1.dp, PabrikBorder),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = "WORKSPACE",
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikDim,
                    )
                    Text(
                        text = selectedName,
                        style = MaterialTheme.typography.titleMedium,
                        color = PabrikText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = PabrikMuted,
                )
            }
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.testTag("workspace_menu"),
        ) {
            if (workspaces.isEmpty()) {
                DropdownMenuItem(
                    text = { Text("No workspaces yet") },
                    onClick = {},
                )
            } else {
                workspaces.forEach { workspace ->
                    val isSelected = workspace.id == selectedWorkspaceId
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = workspace.displayName,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        onClick = {
                            // Only the dropdown closes here.
                            expanded = false
                            onWorkspaceSelected(workspace.id)
                        },
                        trailingIcon = if (isSelected) {
                            {
                                Icon(
                                    imageVector = Icons.Filled.Check,
                                    contentDescription = null,
                                )
                            }
                        } else {
                            null
                        },
                        modifier = Modifier
                            .testTag("workspace_option_${workspace.id}")
                            .semantics { selected = isSelected },
                    )
                }
            }
        }
    }
}

/** A chat row: title, the human's last-visit pill, the running dot. */
@Composable
internal fun ChatRow(
    chat: ChatSummary,
    selected: Boolean,
    isRunning: Boolean,
    nowEpochMillis: Long,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("chat_row_${chat.id}")
            .semantics(mergeDescendants = true) {
                contentDescription = buildString {
                    append(chat.displayTitle)
                    if (chat.hasTimestamp) {
                        append(", ")
                        // The label key, not the order key: this row can be at the top of the list because the *agent* is working it, and "updated just now" would be a claim about the …
                        append(
                            formatRelativeTimeForAccessibility(
                                chat.lastHumanTouchedAtEpochMillis,
                                nowEpochMillis,
                            ),
                        )
                    }
                    // Spoken as part of the row rather than left to the spinner.
                    if (isRunning) append(", agent is working")
                }
            }
            .selectable(
                selected = selected,
                role = Role.Tab,
                onClick = onClick,
            ),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) PabrikAccent.copy(alpha = 0.16f) else Color.Transparent,
        contentColor = PabrikText,
        border = if (selected) {
            BorderStroke(1.dp, PabrikAccent.copy(alpha = 0.36f))
        } else {
            null
        },
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = chat.displayTitle,
                    style = MaterialTheme.typography.bodyLarge,
                    color = PabrikText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                // A session with no parseable timestamp gets no time pill rather than a fabricated one.
                if (chat.hasTimestamp) {
                    Text(
                        text = formatRelativeTime(chat.lastHumanTouchedAtEpochMillis, nowEpochMillis),
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikMuted,
                    )
                }
            }

            // One trailing slot for both markers, so they cannot overlap and so the selected dot keeps the position it already had.
            Row(
                modifier = Modifier.padding(start = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (selected) {
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .background(PabrikAccent, CircleShape),
                    )
                }
                if (isRunning) {
                    // Gaps rather than a fixed offset: the running spinner is the only marker on an unselected row and the one that matters most, so it is not pushed away from the …
                    Spacer(Modifier.size(if (selected) 6.dp else 0.dp))
                    CircularProgressIndicator(
                        modifier = Modifier
                            // Cleared *before* the tag: `clearAndSetSemantics` discards everything a preceding modifier set, and the row above merges descendants, so an un-cleared progress …
                            .clearAndSetSemantics { }
                            .size(14.dp)
                            .testTag("chat_row_running_${chat.id}"),
                        strokeWidth = 2.dp,
                        color = PabrikAccent,
                    )
                }
            }
        }
    }
}

@Composable
private fun StaleDataNotice(
    message: String,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = PabrikBackgroundRaised,
        contentColor = PabrikDim,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Showing saved data · $message",
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium,
                color = PabrikDim,
            )
            TextButton(
                onClick = onRetry,
                modifier = Modifier.testTag("sidebar_stale_retry"),
            ) {
                Text(text = "Retry", color = PabrikAccent)
            }
        }
    }
}

@Composable
internal fun SidebarPlaceholder(
    title: String,
    detail: String,
    testTag: String,
    modifier: Modifier = Modifier,
    showSpinner: Boolean = false,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 24.dp),
        ) {
            if (showSpinner) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = PabrikMuted,
                )
            }
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = PabrikMuted,
                textAlign = TextAlign.Center,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikDim,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun SidebarError(
    message: String,
    onRetry: () -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(horizontal = 24.dp),
        ) {
            Text(
                text = "Could not load your sidebar",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikMuted,
                textAlign = TextAlign.Center,
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikDim,
                textAlign = TextAlign.Center,
            )
            TextButton(
                onClick = onRetry,
                modifier = Modifier.testTag("sidebar_retry"),
            ) {
                Text(text = "Retry", color = PabrikAccent)
            }
        }
    }
}

@Composable
private fun EmptyChats(modifier: Modifier = Modifier) {
    SidebarPlaceholder(
        modifier = modifier,
        testTag = "chats_empty",
        title = "No recent chats",
        detail = "Chats in this workspace will appear here.",
    )
}
