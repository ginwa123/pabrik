package com.pabrik.mobile.projects

/** One column of a kanban board, as `GET .../kanban/columns` returns it. */
data class KanbanColumn(
    val id: String,
    val name: String,
    val position: Int,
) {
    /** What the picker chip reads. */
    val displayName: String
        get() = name.trim().ifEmpty { "Untitled column" }
}

/** Everything the "New task" form collects, in one value. */
data class KanbanTaskForm(
    val name: String = "",
    val description: String = "",
    /** Empty = "let the server auto-assign", which is what it does today. */
    val columnId: String = "",
    val tags: List<String> = emptyList(),
    /** Migration 070 — per-task cwd. Empty is the "no override" sentinel. */
    val cwd: String = "",
    val unattended: Boolean = false,
    /** Empty = "Default (top-level config)", which the server resolves. */
    val profile: String = "",
    /** Whether the agent starts on the new card. */
    val runAgent: Boolean = false,
    val useGitWorktree: Boolean = false,
    val worktreePath: String = "",
    val worktreeBaseBranch: String = "",
    /** Base64 data URLs, `||`-joined on the wire. See [ChatAttachment]. */
    val imageUrls: List<String> = emptyList(),
)

/** Whether the form carries enough to create a card. */
fun canSubmitKanbanTask(form: KanbanTaskForm): Boolean = form.name.isNotBlank()

/** The `queue_message` the agent's first turn sees, for `mode=create_and_run`. */
fun buildKanbanTaskCreateMessage(form: KanbanTaskForm): String {
    val lines = mutableListOf("Task : ${form.name.trim()}")
    val description = form.description.trim()
    if (description.isNotEmpty()) {
        lines += "Description: $description"
    }
    if (form.useGitWorktree) {
        lines += ""
        lines += "#Notes UseGitWorktree"
        val path = form.worktreePath.trim()
        if (path.isNotEmpty()) {
            lines += "Path: $path"
        }
        val base = form.worktreeBaseBranch.trim()
        if (base.isNotEmpty()) {
            lines += "Base: $base"
        }
    }
    return lines.joinToString("\n")
}

/** The server's own tag rules, applied before the POST. */
object KanbanTags {
    /** `TAG_MAX_LENGTH` in `tags_validation.zig`. */
    const val MAX_LENGTH: Int = 50

    /** The characters a tag may hold, as the server defines them. */
    private fun isAllowed(c: Char): Boolean =
        c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '_' || c == '-'

    /** One cleaned tag, or null when there is nothing to add. */
    fun sanitize(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length > MAX_LENGTH) return null
        if (!trimmed.all { isAllowed(it) }) return null
        return trimmed
    }

    /** Add [raw] to [tags] unless it is a duplicate. */
    fun add(tags: List<String>, raw: String): List<String> {
        val clean = sanitize(raw) ?: return tags
        if (tags.any { it.equals(clean, ignoreCase = true) }) return tags
        return tags + clean
    }

    /** Split a field's contents on commas and add every complete tag. */
    fun commitDraft(tags: List<String>, draft: String): List<String> {
        var next = tags
        for (part in draft.split(',')) {
            next = add(next, part)
        }
        return next
    }

    /** Drop a tag the server would not have accepted. */
    fun normalize(tags: List<String>): List<String> {
        var next = emptyList<String>()
        for (tag in tags) {
            next = add(next, tag)
        }
        return next
    }
}

/** The worktree paths this app proposes, and the slug that names one. */
object KanbanWorktree {
    /** `$HOME`-relative; joined onto the server's home by [defaultPath]. */
    const val DIR_SUFFIX: String = ".config/pabrik/.worktrees"

    /** Longest slug the web produces, so a name change here is a visible diff. */
    private const val MAX_SLUG_LENGTH: Int = 50

    /** A filesystem-safe stem for [taskName]. */
    fun slugify(taskName: String): String {
        val slug = buildString {
            var lastWasDash = true // Leading dashes are stripped below anyway.
            for (c in taskName.trim().lowercase()) {
                if (c in 'a'..'z' || c in '0'..'9') {
                    append(c)
                    lastWasDash = false
                } else if (!lastWasDash) {
                    append('-')
                    lastWasDash = true
                }
            }
        }.trim('-')
        return slug.take(MAX_SLUG_LENGTH).ifEmpty { "task" }
    }

    /** The prefill the web writes into the path field when the toggle flips on. */
    fun defaultPath(serverHome: String, taskName: String, nowMillis: Long): String {
        val home = serverHome.trim().trimEnd('/')
        val root = if (home.isEmpty()) "~/$DIR_SUFFIX" else "$home/$DIR_SUFFIX"
        return "$root/${slugify(taskName)}-$nowMillis"
    }
}
