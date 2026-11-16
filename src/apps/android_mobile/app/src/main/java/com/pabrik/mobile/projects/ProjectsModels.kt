package com.pabrik.mobile.projects

/** The known `item_type` values, kept as plain strings because that is what the wire sends and what the UI has to tolerate. */
object ProjectTypes {
    const val KANBAN = "kanban"
    const val AGENT = "agent"
    const val ROUTINE = "routine"
    const val DESIGN = "design"

    /** Legacy. */
    const val FOLDER = "folder"
}

/** One row of the drawer's Projects section: a `workspace_items` row. */
data class ProjectSummary(
    val id: String,
    val workspaceId: String,
    val itemType: String,
    val name: String,
    /** On-disk cwd. Empty when the server sent null. */
    val path: String = "",
    /** True when this is the workspace's default project (Migration 094) — an `agent` item whose [path] is the server user's home directory, and where the drawer's … */
    val isDefault: Boolean = false,
) {
    /** The server's `name` is nullable, and `stringField` maps an explicit JSON null to `""`. */
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled project" }
}

/** One chat belonging to a project — a `workspace_item_tasks` row. */
data class ProjectChat(
    val id: String,
    val projectId: String,
    val name: String,
    val updatedAtEpochMillis: Long,
    /** The server's `task_type`. */
    val taskType: String? = null,
) {
    val displayName: String
        get() = name.trim().ifEmpty { TaskTypes.DEFAULT_NEW_CHAT_NAME }

    /** Whether this row is a destination. */
    val isOpenable: Boolean
        get() = taskType == null || taskType == TaskTypes.STANDARD

    /** False when no timestamp parsed, so the row renders without a relative label rather than claiming the chat is decades old. */
    val hasTimestamp: Boolean
        get() = updatedAtEpochMillis > 0L
}

/** One page of a project's chats, plus the two fields the scroll needs. */
data class ProjectChatsPage(
    val chats: List<ProjectChat>,
    val hasMore: Boolean,
    /** The server's own resume value. Hand it back verbatim; never synthesize. */
    val nextCursor: String?,
)

/** The `task_type` values `POST .../tasks` accepts, and the one name this app creates chats under. */
object TaskTypes {
    const val STANDARD = "standard"
    const val MEMORY = "memory"

    /** The name a chat is created under when the reader did not type one. */
    const val DEFAULT_NEW_CHAT_NAME = "New Chat"
}

/** What the reader asked to create under a project. */
sealed interface CreateTaskRequest {
    /** An ordinary chat. */
    data class StandardChat(val name: String) : CreateTaskRequest

    /** A local memory file scoped to the project's directory. */
    data class Memory(val name: String, val content: String) : CreateTaskRequest

    /** A card on a kanban board, created through the kanban-scoped endpoint. */
    data class KanbanTask(
        val name: String,
        val description: String,
        /** Empty = server auto-assign; otherwise the move that follows. */
        val columnId: String = "",
        val tags: List<String> = emptyList(),
        val cwd: String = "",
        val unattended: Boolean = false,
        val profile: String = "",
        /** `mode=create_and_run` rather than `mode=create`. */
        val runAgent: Boolean = false,
        val useGitWorktree: Boolean = false,
        val worktreePath: String = "",
        val worktreeBaseBranch: String = "",
        val imageUrls: List<String> = emptyList(),
    ) : CreateTaskRequest {
        /** The `queue_message` this create will send, or "" when it will not run. */
        val queueMessage: String
            get() = if (runAgent) buildKanbanTaskCreateMessage(toForm()) else ""
    }

    /** Whether a successful create is a destination the reader should be sent to. */
    val opensChat: Boolean
        get() = this is StandardChat
}

/** This request as the form the "New task" dialog collects. */
fun CreateTaskRequest.KanbanTask.toForm(): KanbanTaskForm = KanbanTaskForm(
    name = name,
    description = description,
    columnId = columnId,
    tags = tags,
    cwd = cwd,
    unattended = unattended,
    profile = profile,
    runAgent = runAgent,
    useGitWorktree = useGitWorktree,
    worktreePath = worktreePath,
    worktreeBaseBranch = worktreeBaseBranch,
    imageUrls = imageUrls,
)

/** A [KanbanTaskForm] as the request that will be posted. */
fun KanbanTaskForm.toRequest(): CreateTaskRequest.KanbanTask = CreateTaskRequest.KanbanTask(
    // The title is trimmed here, not at the wire, so the row the drawer paints and the row the board shows carry the same string.
    name = name.trim(),
    description = description,
    columnId = columnId,
    // Normalized at the boundary, not while typing: the chip row is the reader's view of the tags and re-filtering it on every keystroke would make a chip vanish …
    tags = KanbanTags.normalize(tags),
    cwd = cwd.trim(),
    unattended = unattended,
    profile = profile,
    runAgent = runAgent,
    useGitWorktree = useGitWorktree,
    worktreePath = worktreePath.trim(),
    worktreeBaseBranch = worktreeBaseBranch.trim(),
    imageUrls = imageUrls,
)

/** The memory filename rules, mirrored from the backend's `isValidMemoryName` (`src/modules/agent/tools/memories.zig:425`). */
fun isValidMemoryName(name: String): Boolean {
    val trimmed = name.trim()
    if (trimmed.isEmpty()) return false
    if (!trimmed.endsWith(".md")) return false
    if (trimmed.contains('/') || trimmed.contains('\\')) return false
    if (trimmed.contains("..")) return false
    return true
}
