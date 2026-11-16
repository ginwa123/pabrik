package com.pabrik.mobile.projects

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.ViewKanban
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.formatRelativeTime
import com.pabrik.mobile.recents.formatRelativeTimeForAccessibility
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** Everything the Projects section draws, in one value. */
@Stable
class ProjectsState(
    val expanded: Boolean,
    val items: List<ProjectSummary>,
    val expandedItemIds: Set<String>,
    val chats: Map<String, ProjectChatsPage>,
    val isLoading: Boolean,
    val errorMessage: String?,
    /** The project whose create is in flight, or null. */
    val creatingTaskItemId: String? = null,
) {
    fun isProjectExpanded(itemId: String): Boolean = itemId in expandedItemIds

    fun chatsFor(itemId: String): ProjectChatsPage? = chats[itemId]

    /** The projects holding at least one of [runningSessionIds]'s sessions. */
    fun runningProjectIds(
        runningSessionIds: Set<String>,
        recents: List<ChatSummary> = emptyList(),
    ): Set<String> {
        if (runningSessionIds.isEmpty()) return emptySet()

        val fromUnfoldedProjects = chats.filterValues { page ->
            page.chats.any { chat -> chat.id in runningSessionIds }
        }.keys

        val fromRecents = recents.asSequence()
            .filter { chat -> chat.id in runningSessionIds }
            .mapNotNull { chat -> chat.projectId?.takeIf { it.isNotBlank() } }
            .toSet()

        return fromUnfoldedProjects + fromRecents
    }

    /** The rows the drawer unrolls under a project — the first [ProjectsApi.DRAWER_PREVIEW_ROWS] of the page, never the whole thing. */
    fun previewFor(itemId: String): List<ProjectChat> =
        chats[itemId]?.chats?.take(ProjectsApi.DRAWER_PREVIEW_ROWS).orEmpty()

    /** Whether "See all chats" is worth offering: only when the drawer is actually hiding rows. */
    fun shouldOfferSeeAllChats(itemId: String): Boolean {
        val page = chats[itemId] ?: return false
        return page.chats.size > ProjectsApi.DRAWER_PREVIEW_ROWS || page.hasMore
    }

    /** Nothing to show and nothing wrong — the workspace genuinely has none. */
    val isEmpty: Boolean
        get() = !isLoading && errorMessage == null && items.isEmpty()

    /** A fetch failed but rows survive. The section keeps them and says so. */
    val isShowingStaleData: Boolean
        get() = errorMessage != null && items.isNotEmpty()

    companion object {
        /** Empty rather than all-defaults, so a caller that forgets to pass a section gets an honest "nothing here" instead of a silent default-to-expanded one. */
        val Empty = ProjectsState(
            expanded = false,
            items = emptyList(),
            expandedItemIds = emptySet(),
            chats = emptyMap(),
            isLoading = false,
            errorMessage = null,
        )
    }
}

/** The things a reader can do to the Projects section. */
@Stable
class ProjectsActions(
    /** Fold the whole section away, or unfold it. Stays in the drawer. */
    val onToggleSection: () -> Unit,
    /** Fold one project open or shut. Stays in the drawer. */
    val onToggleItem: (String) -> Unit,
    /** Leave the drawer for the project-chats screen. */
    val onOpenAllChats: (workspaceId: String, itemId: String) -> Unit,
    val onRetry: () -> Unit,
    /** Open the create flow for a project. */
    val onCreateTask: (ProjectSummary) -> Unit = {},
) {
    companion object {
        val None = ProjectsActions(
            onToggleSection = {},
            onToggleItem = {},
            onOpenAllChats = { _, _ -> },
            onRetry = {},
            onCreateTask = {},
        )
    }
}

/** The glyph for an `item_type`. */
internal fun projectGlyph(itemType: String): ImageVector = when (itemType) {
    ProjectTypes.KANBAN -> Icons.Filled.ViewKanban
    ProjectTypes.AGENT -> Icons.Filled.SmartToy
    ProjectTypes.ROUTINE -> Icons.Filled.Autorenew
    ProjectTypes.DESIGN -> Icons.Filled.Brush
    // `folder` and anything unrecognised both land here.
    else -> Icons.Filled.Folder
}

/** One project row: a glyph, a name, and a chevron. */
@Composable
internal fun ProjectRow(
    project: ProjectSummary,
    expanded: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** Whether a chat inside this project has a live worker. */
    isRunning: Boolean = false,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag("project_row_${project.id}")
            .semantics {
                role = Role.Button
                contentDescription = buildString {
                    append("${project.displayName}. ${project.itemType} project")
                    if (isRunning) append(", agent is working")
                }
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        // The same selected treatment a chat row uses, so "the thing you are inside" looks the same whichever list you found it in.
        shape = RoundedCornerShape(12.dp),
        color = if (expanded) PabrikField else Color.Transparent,
        contentColor = PabrikText,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = projectGlyph(project.itemType),
                contentDescription = null,
                tint = PabrikMuted,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = project.displayName,
                style = MaterialTheme.typography.bodyLarge,
                color = PabrikText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            // Ahead of the chevron, and only while something runs: the row's right-hand edge must not change width as a run starts and stops, or every reader watches the …
            if (isRunning) {
                CircularProgressIndicator(
                    // Decorative — "agent is working" is already in the content description, and announcing it twice is worse than not announcing it.
                    modifier = Modifier
                        .clearAndSetSemantics { }
                        .size(14.dp)
                        .testTag("project_running_${project.id}"),
                    strokeWidth = 2.dp,
                    color = PabrikAccent,
                )
            }
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = PabrikDim,
                modifier = Modifier.size(16.dp),
                // Rotated rather than swapped for a different icon, so the row's right-hand edge does not change width as it opens.
            )
        }
    }
}

/** One chat under a project, or one chat on the project-chats screen. */
@Composable
internal fun ProjectChatRow(
    chat: ProjectChat,
    selected: Boolean,
    isRunning: Boolean,
    nowEpochMillis: Long,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .testTag("project_chat_row_${chat.id}")
            .semantics(mergeDescendants = true) {
                contentDescription = buildString {
                    append(chat.displayName)
                    if (chat.hasTimestamp) {
                        append(", ")
                        append(formatRelativeTimeForAccessibility(chat.updatedAtEpochMillis, nowEpochMillis))
                    }
                    if (isRunning) append(", agent is working")
                }
            }
            .selectable(selected, role = Role.Tab, onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) PabrikAccent.copy(alpha = 0.16f) else Color.Transparent,
        contentColor = PabrikText,
        border = if (selected) BorderStroke(1.dp, PabrikAccent.copy(alpha = 0.36f)) else null,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = chat.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    color = PabrikText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (chat.hasTimestamp) {
                    Text(
                        text = formatRelativeTime(chat.updatedAtEpochMillis, nowEpochMillis),
                        style = MaterialTheme.typography.labelMedium,
                        color = PabrikMuted,
                    )
                }
            }

            if (isRunning) {
                androidx.compose.material3.CircularProgressIndicator(
                    // Decorative: "agent is working" is already in the merged content description, and announcing it twice is worse than not announcing it.
                    modifier = Modifier
                        .clearAndSetSemantics { }
                        .size(14.dp)
                        .testTag("project_chat_running_${chat.id}"),
                    strokeWidth = 2.dp,
                    color = PabrikAccent,
                )
            }
        }
    }
}

/** The one control in either section that leaves the drawer. */
@Composable
internal fun SeeAllChatsRow(
    testTag: String,
    subject: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .testTag(testTag)
            .semantics {
                role = Role.Button
                contentDescription = "See all chats $subject"
            },
        shape = RoundedCornerShape(10.dp),
        color = PabrikAccent.copy(alpha = 0.10f),
        contentColor = PabrikText,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "See all chats",
                style = MaterialTheme.typography.labelLarge,
                color = PabrikAccent,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = PabrikAccent,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}
