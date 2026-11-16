package com.pabrik.mobile.chat

import org.json.JSONObject

/** What a tool row draws, decided from the row alone. */
enum class ToolKind {
    ReadFile,
    WriteFile,
    Shell,
    Search,
    Glob,
    ListDirectory,
    Diff,
    Plan,
    Question,
    SubAgentSpawn,
    AgentCatalog,
    MemorySave,
    MemoryLoad,
    MemoryList,
    // The rendering kind, not the wire name: the tool on the wire is `search_skills`.
    SkillList,
    SkillUse,
    SkillMutation,
    KanbanMove,
    KanbanList,
    PresentFiles,
    GenerateImage,
    /** `web_search` and its discovery call. */
    WebSearch,
    ListSearchProviders,
    Worktree,
    SessionReader,
    Progressive,
    Mcp,

    /** No renderer, or a payload that is not a JSON object (`{"_raw": …}`). */
    Raw,
}

/** The parsed payload of one tool result. */
sealed interface ToolBody {
    /** Nothing to draw. The card falls back to its Arguments block. */
    data object Empty : ToolBody

    /** A failure the envelope does not report. */
    val reportedError: String? get() = null

    data class ReadFile(
        val path: String = "",
        val content: String = "",
        val startLine: Int? = null,
    ) : ToolBody {
        val lines: List<String> get() = ToolDiff.splitLines(content)

        /** 1-based first display number; the backend's `start_line` is a 0-based offset. */
        val firstLineNumber: Int get() = (startLine ?: 0) + 1
    }

    data class WriteFile(
        /** The backend names this key `file_write`, not `path`. */
        val path: String = "",
    ) : ToolBody

    data class Shell(
        val command: String = "",
        val stdout: String = "",
        val stderr: String = "",
        val exitCode: Int? = null,
        val truncated: Boolean = false,
        val timedOut: Boolean = false,
        val stdoutLines: Int = 0,
        val stderrLines: Int = 0,
    ) : ToolBody {
        /** `No errors.` is the shell's placeholder for an empty stderr, and the web hides it. */
        val hasStderr: Boolean
            get() = stderr.isNotBlank() && stderr.trim() != NO_STDERR_SENTINEL

        val hasWarning: Boolean get() = timedOut
        val hasFailure: Boolean get() = exitCode != null && exitCode != 0

        private companion object {
            const val NO_STDERR_SENTINEL = "No errors."
        }
    }

    data class SearchFile(
        val path: String = "",
        val matches: List<SearchMatch> = emptyList(),
    )

    data class SearchMatch(
        val line: Int = 0,
        val text: String = "",
    )

    data class Search(
        val pattern: String = "",
        val path: String = "",
        val warning: String? = null,
        val returned: Int? = null,
        val truncatedHint: String? = null,
        val files: List<SearchFile> = emptyList(),
    ) : ToolBody

    data class Glob(
        val pattern: String = "",
        val returned: Int? = null,
        /** A *count* of dropped matches on this tool, not a boolean. */
        val truncated: Int? = null,
        val truncatedBySize: Boolean = false,
        val warning: String? = null,
        val files: List<String> = emptyList(),
    ) : ToolBody

    data class DirEntry(
        val name: String = "",
        val isDirectory: Boolean = false,
        val isSymlink: Boolean = false,
    )

    data class ListDirectory(
        val path: String = "",
        val count: Int = 0,
        val entries: List<DirEntry> = emptyList(),
    ) : ToolBody

    data class Diff(
        val path: String = "",
        val before: String = "",
        val after: String = "",
        val unified: String = "",
        val linesChanged: Int? = null,
    ) : ToolBody

    /** One line of a rendered markdown checklist. */
    data class ChecklistLine(
        val kind: ChecklistKind,
        val text: String,
    ) {
        enum class ChecklistKind { Checked, Unchecked, Text }
    }

    data class Plan(
        val sessionId: String? = null,
        val updatedAt: String? = null,
        val body: String? = null,
        val empty: Boolean = false,
    ) : ToolBody {
        val lines: List<ChecklistLine>
            get() = body.orEmpty().split("\n").map { raw ->
                val line = raw.trimEnd()
                val unchecked = UNCHECKED.matchEntire(line)
                val checked = if (unchecked == null) CHECKED.matchEntire(line) else null
                when {
                    unchecked != null -> ChecklistLine(
                        ChecklistLine.ChecklistKind.Unchecked,
                        unchecked.groupValues[1].trim(),
                    )

                    checked != null -> ChecklistLine(
                        ChecklistLine.ChecklistKind.Checked,
                        checked.groupValues[1].trim(),
                    )

                    else -> ChecklistLine(ChecklistLine.ChecklistKind.Text, line)
                }
            }

        private companion object {
            /** One capture per pattern, so the match and the text extraction cannot disagree about which line matched. */
            val CHECKED = Regex("""^\s*- \[x]\s+(.*)$""", RegexOption.IGNORE_CASE)
            val UNCHECKED = Regex("""^\s*- \[ ]\s+(.*)$""")
        }
    }

    /** `ask_user`. */
    data class Question(
        val status: String = "",
        val questionId: String? = null,
        val question: String = "",
        val answer: String? = null,
        val header: String? = null,
        val multiSelect: Boolean = false,
        val recommended: String? = null,
        val allowFreeText: Boolean = true,
        val options: List<String> = emptyList(),
        val instruction: String? = null,
    ) : ToolBody {
        val isPending: Boolean
            get() = status == STATUS_PENDING || status == STATUS_INVALID
        val isAnswered: Boolean get() = status == STATUS_ANSWERED

        companion object {
            const val STATUS_PENDING = "pending"
            const val STATUS_INVALID = "invalid"
            const val STATUS_ANSWERED = "answered"
            const val STATUS_SKIPPED = "skipped"
            const val STATUS_ABANDONED = "abandoned"
            const val STATUS_UNAVAILABLE = "unavailable"
        }
    }

    data class SubAgentResult(
        val name: String = "",
        val success: Boolean = false,
        val response: String? = null,
        val error: String? = null,
    )

    data class SubAgentSpawn(
        val results: List<SubAgentResult> = emptyList(),
        val succeeded: Int = 0,
        val failed: Int = 0,
    ) : ToolBody

    data class AgentCatalogEntry(
        val name: String = "",
        val model: String = "",
        val thinking: String = "",
    )

    data class AgentCatalog(
        val count: Int = 0,
        val agents: List<AgentCatalogEntry> = emptyList(),
    ) : ToolBody

    data class MemorySave(val id: String = "") : ToolBody

    data class MemoryHit(
        val id: String = "",
        val snippet: String = "",
    )

    /** One file the memory store wrote. `list_memory` names the key `memories`. */
    data class StoredMemory(
        val id: String = "",
        val title: String = "",
        val path: String = "",
        val sizeBytes: Long = 0L,
    )

    data class MemoryList(
        val memories: List<StoredMemory> = emptyList(),
    ) : ToolBody

    data class MemoryLoad(
        val query: String = "",
        val count: Int = 0,
        val totalCount: Int = 0,
        val results: List<MemoryHit> = emptyList(),
    ) : ToolBody

    data class SkillEntry(
        val name: String = "",
        val description: String = "",
        /** `global` or `local`, per row. */
        val scope: String = "",
        val path: String = "",
    )

    /** One page of `search_skills`. */
    data class SkillList(
        val query: String = "",
        /** Rows in *this* page. Not the number of matches. */
        val count: Int = 0,
        /** Matches before paging. */
        val total: Int = 0,
        val truncated: Boolean = false,
        /** Where the next page starts; null when this page is the last one. */
        val nextOffset: Int? = null,
        val skills: List<SkillEntry> = emptyList(),
    ) : ToolBody {
        /** False when the card is showing a slice of the answer, so no renderer or test reads a short page as "these are all of them". */
        val sawEverything: Boolean get() = !truncated && count >= total
    }

    data class SkillUse(
        val skillName: String = "",
        val content: String = "",
        val loaded: Boolean = false,
        /** `use_skill` is the only skill tool that never sets `success: false` — `tools_exec_skills.zig` wraps it unconditionally — so a failure is only visible here … */
        val error: String? = null,
    ) : ToolBody {
        override val reportedError: String? get() = error
    }

    data class SkillMutation(
        val skillName: String = "",
        val name: String = "",
        val changed: Boolean = false,
        val path: String? = null,
        val error: String? = null,
    ) : ToolBody {
        override val reportedError: String? get() = error
    }

    data class KanbanMove(
        val taskName: String = "",
        val columnName: String = "",
        val position: Int = 0,
    ) : ToolBody

    data class KanbanColumn(
        val name: String = "",
        val taskCount: Int = 0,
    )

    data class KanbanTask(
        val name: String = "",
        val columnName: String? = null,
    )

    data class KanbanList(
        val columns: List<KanbanColumn> = emptyList(),
        val tasks: List<KanbanTask> = emptyList(),
        val totalCount: Int = 0,
        val hasMore: Boolean = false,
    ) : ToolBody

    data class PresentedFile(
        val path: String = "",
        val bytes: Long = 0L,
        val label: String = "",
        /** The tool reports it (`{"path":…,"bytes":…,"mime":…,"label":…}`) and it is the only thing that says whether a file can be previewed inline, so dropping it left … */
        val mime: String = "",
    )

    data class PresentFiles(
        val count: Int = 0,
        val files: List<PresentedFile> = emptyList(),
    ) : ToolBody

    data class GeneratedImage(
        val index: Int = 0,
        val path: String = "",
    )

    data class GenerateImage(
        val count: Int = 0,
        val model: String = "",
        val size: String = "",
        val images: List<GeneratedImage> = emptyList(),
        val revisedPrompt: String? = null,
    ) : ToolBody

    data class Worktree(
        val path: String? = null,
        val branch: String? = null,
        val base: String? = null,
        val note: String? = null,
    ) : ToolBody

    /** `read_workspace_session` has three incompatible payload shapes, told apart by its own `behavior` key — list, search, read — so they cannot be one model with … */
    data class SessionReader(
        val behavior: String = "",
        val query: String? = null,
        val count: Int = 0,
        val totalCount: Int = 0,
        val sessions: List<SkillEntry> = emptyList(),
        val results: List<SearchFile> = emptyList(),
    ) : ToolBody

    data class ProgressiveTool(
        val name: String = "",
        val description: String = "",
        val error: String? = null,
        val query: String = "",
        val count: Int = 0,
        val total: Int = 0,
        /** A partial page. The same flag `search_skills` sends. */
        val truncated: Boolean = false,
        val tools: List<SkillEntry> = emptyList(),
    ) : ToolBody {
        // `view_tool` / `use_tool` on a miss: found=false with an error, in an envelope that still claims success.
        override val reportedError: String? get() = error
    }

    /** Raw server text. `mcp_*` bypasses the envelope entirely on success. */
    data class Mcp(val text: String = "") : ToolBody

    /** Unparsed text: a legacy XML body, or a `{"_raw": …}` payload. */
    data class Raw(val text: String = "") : ToolBody
}

/** A tool row, resolved down to what one card needs. */
data class ToolCardModel(
    val id: String,
    /** The join key back to the assistant turn that declared this call. */
    val toolCallId: String,
    val kind: ToolKind,
    val label: String,
    val primary: String?,
    val rightMeta: String?,
    val success: Boolean,
    val pending: Boolean,
    val errorText: String?,
    val parametersJson: String,
    val body: ToolBody,
    val defaultsExpanded: Boolean = false,
) {
    /** The card is one the reader has to open; the badge is not decoration. */
    val isBlocking: Boolean
        get() = body is ToolBody.Question && (body as ToolBody.Question).isPending
}

/** Turns a wire row into a [ToolCardModel]. */
object ToolCard {
    /** Tool names that all share the shell payload and renderer. */
    val SHELL_TOOLS = setOf("bash", "pwsh", "run_command", "command")

    /** The progressive-discovery trio, which shares one renderer. */
    val PROGRESSIVE_TOOLS = setOf("search_tool", "view_tool", "use_tool")

    /** The tools the web opens by default, because their content *is* the message rather than detail supporting it. */
    private val DEFAULT_EXPANDED = setOf("ask_user", "update_plan", "get_plan", "list_agents")

    fun from(message: ChatMessage): ToolCardModel {
        val envelope = ToolOutput.tryUnwrap(message.content)
        val toolName = message.toolName.ifBlank { envelope?.name.orEmpty() }
        val data = envelope?.data
        val rawPayload = envelope?.rawPayload

        val kind = kindOf(toolName)
        val body = bodyOf(kind, envelope, data, message, rawPayload)
        val parameters = envelope?.parametersJson.orEmpty()

        val pending = envelope?.isPending == true
        val bodyError = errorInBody(body)
        val success = when {
            envelope == null -> !looksInterrupted(message.content)
            // `use_skill` reports failure inside a success envelope.
            bodyError != null -> false
            else -> envelope.success
        }

        return ToolCardModel(
            id = message.id,
            toolCallId = message.toolCallId,
            kind = kind,
            label = labelFor(toolName),
            primary = primaryFor(kind, body, parameters),
            rightMeta = rightMetaFor(body, pending),
            success = success,
            pending = pending,
            errorText = envelope?.error ?: bodyError,
            parametersJson = parameters,
            body = body,
            defaultsExpanded = toolName in DEFAULT_EXPANDED,
        )
    }

    private fun kindOf(toolName: String): ToolKind = when {
        toolName in SHELL_TOOLS -> ToolKind.Shell
        toolName in PROGRESSIVE_TOOLS -> ToolKind.Progressive
        toolName.startsWith("mcp_") -> ToolKind.Mcp
        toolName == "read_file" -> ToolKind.ReadFile
        toolName == "write_file" -> ToolKind.WriteFile
        toolName == "search" -> ToolKind.Search
        toolName == "glob" -> ToolKind.Glob
        toolName == "list_directory" -> ToolKind.ListDirectory
        // `text_replace` has a renderer, but a tool this client has never heard of can still carry `diffview_before`/`after`, and the web's generic fallback renders …
        toolName == "text_replace" -> ToolKind.Diff
        toolName == "update_plan" || toolName == "get_plan" -> ToolKind.Plan
        toolName == "ask_user" -> ToolKind.Question
        toolName == "spawn_sub_agent" -> ToolKind.SubAgentSpawn
        toolName == "list_agents" -> ToolKind.AgentCatalog
        toolName == "save_memory" -> ToolKind.MemorySave
        toolName == "load_memory" -> ToolKind.MemoryLoad
        toolName == "list_memory" -> ToolKind.MemoryList
        // The wire name of ToolKind.SkillList.
        toolName == "search_skills" -> ToolKind.SkillList
        toolName == "use_skill" -> ToolKind.SkillUse
        toolName == "add_skill" || toolName == "edit_skill" ||
            toolName == "remove_skill" -> ToolKind.SkillMutation
        toolName == "kanban_move_task" -> ToolKind.KanbanMove
        toolName == "kanban_list" -> ToolKind.KanbanList
        toolName == "present_files" -> ToolKind.PresentFiles
        toolName == "generate_image" -> ToolKind.GenerateImage
        toolName == "web_search" -> ToolKind.WebSearch
        toolName == "list_web_search_providers" -> ToolKind.ListSearchProviders
        toolName == "set_git_worktree" -> ToolKind.Worktree
        toolName == "read_workspace_session" -> ToolKind.SessionReader
        else -> ToolKind.Raw
    }

    private fun bodyOf(
        kind: ToolKind,
        envelope: ToolEnvelope?,
        data: JSONObject?,
        message: ChatMessage,
        rawPayload: String?,
    ): ToolBody {
        // A payload that is not an object is text, whichever tool produced it.
        if (rawPayload != null) return ToolBody.Raw(rawPayload)

        // No envelope at all. Three things land here, and each has to render
        if (envelope == null) {
            if (kind == ToolKind.Mcp) return ToolBody.Mcp(message.content)
            if (message.hasDiff) return diffOf(message)
            return if (message.content.isBlank()) {
                ToolBody.Empty
            } else {
                ToolBody.Raw(message.content)
            }
        }

        if (data == null) {
            // A placeholder row: the tool has been asked for and has not answered.
            return if (message.hasDiff) diffOf(message) else ToolBody.Empty
        }

        return when (kind) {
            ToolKind.ReadFile -> ToolBody.ReadFile(
                path = data.string("path"),
                content = data.string("content"),
                startLine = data.intOrNull("start_line"),
            )

            ToolKind.WriteFile -> ToolBody.WriteFile(
                // The key is `file_write`; `path` is the Vue parser's fallback for a shape the backend does not emit.
                path = data.string("file_write").ifEmpty { data.string("path") },
            )

            ToolKind.Shell -> ToolBody.Shell(
                command = data.string("command"),
                stdout = data.string("stdout"),
                stderr = data.string("stderr"),
                exitCode = data.intOrNull("exit_code"),
                truncated = data.boolOr("truncated", fallback = false),
                timedOut = data.boolOr("timeout", fallback = false),
                stdoutLines = data.intOrNull("stdout_lines") ?: 0,
                stderrLines = data.intOrNull("stderr_lines") ?: 0,
            )

            ToolKind.Search -> ToolBody.Search(
                pattern = data.string("pattern"),
                path = data.string("path"),
                warning = data.stringOrNull("warning"),
                returned = data.intOrNull("returned"),
                truncatedHint = data.stringOrNull("truncated_hint"),
                files = data.arrayOrEmpty("files").mapObjects { file ->
                    ToolBody.SearchFile(
                        path = file.string("path"),
                        matches = file.arrayOrEmpty("matches").mapObjects { match ->
                            ToolBody.SearchMatch(
                                line = match.intOrNull("line") ?: 0,
                                text = match.string("text"),
                            )
                        },
                    )
                },
            )

            ToolKind.Glob -> ToolBody.Glob(
                pattern = data.string("pattern"),
                returned = data.intOrNull("returned"),
                // A *number* of dropped matches here, unlike every other tool.
                truncated = data.intOrNull("truncated"),
                truncatedBySize = data.boolOr("truncated_by_size", fallback = false),
                warning = data.stringOrNull("warning"),
                // `files` is an array of plain strings, not objects.
                files = data.arrayOrEmpty("files").stringList(),
            )

            ToolKind.ListDirectory -> ToolBody.ListDirectory(
                path = data.string("path"),
                count = data.intOrNull("count") ?: 0,
                entries = data.arrayOrEmpty("entries").mapObjects { entry ->
                    ToolBody.DirEntry(
                        name = entry.string("name"),
                        isDirectory = entry.boolOr("is_directory", fallback = false),
                        isSymlink = entry.boolOr("is_symlink", fallback = false),
                    )
                },
            )

            ToolKind.Diff -> ToolBody.Diff(
                path = data.string("path"),
                before = data.stringOrNull("before").orEmpty(),
                after = data.stringOrNull("after").orEmpty(),
                unified = data.stringOrNull("unified").orEmpty(),
                linesChanged = data.intOrNull("lines_changed"),
            )

            ToolKind.Plan -> ToolBody.Plan(
                sessionId = data.stringOrNull("session_id"),
                updatedAt = data.stringOrNull("updated_at"),
                body = data.stringOrNull("plan"),
                // `get_plan` with no plan emits `{"empty": true}` and no `plan` key at all, which is otherwise indistinguishable from a plan whose body was empty.
                empty = data.boolOr("empty", fallback = false),
            )

            ToolKind.Question -> ToolBody.Question(
                status = data.string("status"),
                questionId = data.stringOrNull("question_id"),
                question = data.string("question"),
                answer = data.stringOrNull("answer"),
                header = data.stringOrNull("header"),
                multiSelect = data.boolOr("multi_select", fallback = false),
                recommended = data.stringOrNull("recommended"),
                allowFreeText = data.boolOr("allow_free_text", fallback = true),
                options = data.arrayOrEmpty("options").stringList(),
                instruction = data.stringOrNull("instruction"),
            )

            ToolKind.SubAgentSpawn -> {
                val summary = data.objectOrNull("summary")
                ToolBody.SubAgentSpawn(
                    results = data.arrayOrEmpty("results").mapObjects { result ->
                        ToolBody.SubAgentResult(
                            name = result.string("name"),
                            success = result.boolOr("success", fallback = false),
                            response = result.stringOrNull("response"),
                            error = result.stringOrNull("error"),
                        )
                    },
                    succeeded = summary?.intOrNull("succeeded") ?: 0,
                    failed = summary?.intOrNull("failed") ?: 0,
                )
            }

            ToolKind.AgentCatalog -> ToolBody.AgentCatalog(
                count = data.intOrNull("count") ?: 0,
                agents = data.arrayOrEmpty("agents").mapObjects { agent ->
                    ToolBody.AgentCatalogEntry(
                        name = agent.string("name"),
                        model = agent.string("model"),
                        thinking = agent.string("thinking"),
                    )
                },
            )

            ToolKind.MemorySave -> ToolBody.MemorySave(id = data.string("id"))

            ToolKind.MemoryList -> ToolBody.MemoryList(
                memories = data.arrayOrEmpty("memories").mapObjects { memory ->
                    ToolBody.StoredMemory(
                        id = memory.string("name"),
                        title = memory.string("title"),
                        path = memory.string("path"),
                        sizeBytes = memory.opt("size").toLongOrZero(),
                    )
                },
            )

            ToolKind.MemoryLoad -> ToolBody.MemoryLoad(
                query = data.string("query"),
                count = data.intOrNull("count") ?: 0,
                totalCount = data.intOrNull("total_count") ?: 0,
                results = data.arrayOrEmpty("results").mapObjects { hit ->
                    ToolBody.MemoryHit(
                        id = hit.string("id"),
                        snippet = hit.string("snippet"),
                    )
                },
            )

            // One array of rows that carry their own scope: a regex search can interleave `global` and `local`, so there is no section to split on.
            ToolKind.SkillList -> {
                val skills = data.arrayOrEmpty("skills").mapObjects { it.toSkillEntry() }
                val count = data.intOrNull("count") ?: skills.size
                ToolBody.SkillList(
                    query = data.string("query"),
                    count = count,
                    total = data.intOrNull("total") ?: count,
                    truncated = data.boolOr("truncated", fallback = false),
                    nextOffset = data.intOrNull("next_offset"),
                    skills = skills,
                )
            }

            ToolKind.SkillUse -> ToolBody.SkillUse(
                skillName = data.string("skill_name"),
                content = data.string("content"),
                loaded = data.boolOr("loaded", fallback = false),
                error = data.stringOrNull("error"),
            )

            ToolKind.SkillMutation -> ToolBody.SkillMutation(
                skillName = data.string("skill_name"),
                name = data.string("name"),
                // `edit_skill` emits both `updated` and `edited` for one fact.
                changed = data.boolOr("created", fallback = false) ||
                    data.boolOr("updated", fallback = false) ||
                    data.boolOr("edited", fallback = false) ||
                    data.boolOr("removed", fallback = false),
                path = data.stringOrNull("path"),
                error = data.stringOrNull("error"),
            )

            ToolKind.KanbanMove -> ToolBody.KanbanMove(
                taskName = data.string("task_name"),
                columnName = data.string("column_name"),
                position = data.intOrNull("position") ?: 0,
            )

            ToolKind.KanbanList -> ToolBody.KanbanList(
                columns = data.arrayOrEmpty("columns").mapObjects { column ->
                    ToolBody.KanbanColumn(
                        name = column.string("name"),
                        taskCount = column.intOrNull("task_count") ?: 0,
                    )
                },
                tasks = data.arrayOrEmpty("tasks").mapObjects { task ->
                    ToolBody.KanbanTask(
                        name = task.string("name"),
                        columnName = task.stringOrNull("column_name"),
                    )
                },
                totalCount = data.intOrNull("total_count") ?: 0,
                hasMore = data.boolOr("has_more", fallback = false),
            )

            ToolKind.PresentFiles -> ToolBody.PresentFiles(
                count = data.intOrNull("count") ?: 0,
                files = data.arrayOrEmpty("files").mapObjects { file ->
                    ToolBody.PresentedFile(
                        path = file.string("path"),
                        bytes = file.opt("bytes").toLongOrZero(),
                        label = file.string("label"),
                        mime = file.string("mime"),
                    )
                },
            )

            ToolKind.GenerateImage -> ToolBody.GenerateImage(
                count = data.intOrNull("count") ?: 0,
                model = data.string("model"),
                size = data.string("size"),
                images = data.arrayOrEmpty("images").mapObjects { image ->
                    ToolBody.GeneratedImage(
                        index = image.intOrNull("index") ?: 0,
                        path = image.string("path"),
                    )
                },
                revisedPrompt = data.stringOrNull("revised_prompt"),
            )

            ToolKind.Worktree -> ToolBody.Worktree(
                path = data.stringOrNull("path"),
                branch = data.stringOrNull("branch"),
                base = data.stringOrNull("base"),
                note = data.stringOrNull("note"),
            )

            ToolKind.SessionReader -> ToolBody.SessionReader(
                behavior = data.string("behavior"),
                query = data.stringOrNull("query"),
                count = data.intOrNull("count") ?: 0,
                totalCount = data.intOrNull("total_count") ?: 0,
                sessions = data.arrayOrEmpty("sessions").mapObjects { session ->
                    ToolBody.SkillEntry(
                        name = session.string("name"),
                        description = session.string("preview"),
                        path = session.string("id"),
                    )
                },
                results = data.arrayOrEmpty("results").mapObjects { result ->
                    ToolBody.SearchFile(
                        path = result.string("session_name").ifEmpty { result.string("id") },
                        matches = listOf(
                            ToolBody.SearchMatch(
                                line = 0,
                                text = "[${result.string("role")}] ${result.string("snippet")}",
                            ),
                        ),
                    )
                },
            )

            ToolKind.Progressive -> ToolBody.ProgressiveTool(
                name = data.string("name"),
                description = data.string("description"),
                error = data.stringOrNull("error"),
                query = data.string("query"),
                count = data.intOrNull("count") ?: 0,
                total = data.intOrNull("total") ?: 0,
                truncated = data.boolOr("truncated", fallback = false),
                tools = data.arrayOrEmpty("tools").mapObjects { it.toSkillEntry() },
            )

            ToolKind.Mcp -> ToolBody.Mcp(message.content)

            // Both web-search tools carry an UNTYPED provider payload (D13)
            ToolKind.WebSearch,
            ToolKind.ListSearchProviders,
            -> ToolBody.Raw(ToolOutput.fallbackBodyText(data))

            // The web's generic fallback shows the diff *whenever* the row carries one, on top of the pill.
            ToolKind.Raw -> when {
                message.hasDiff -> diffOf(message)
                data.length() == 0 && !message.content.isBlank() -> {
                    ToolBody.Raw(message.content)
                }

                else -> ToolBody.Raw(ToolOutput.fallbackBodyText(data))
            }
        }
    }

    private fun JSONObject.toSkillEntry() = ToolBody.SkillEntry(
        name = string("name"),
        description = string("description"),
        scope = string("scope"),
        path = string("path"),
    )

    /** The header's one-line identity. */
    private fun primaryFor(kind: ToolKind, body: ToolBody, parameters: String): String? {
        for (key in primaryParameterKeys(kind)) {
            param(parameters, key)?.let { return it }
        }
        return when (body) {
            is ToolBody.ReadFile -> body.path
            is ToolBody.WriteFile -> body.path
            is ToolBody.Shell -> body.command
            is ToolBody.Search -> body.pattern
            is ToolBody.Glob -> body.pattern
            is ToolBody.ListDirectory -> body.path
            is ToolBody.Diff -> body.path
            is ToolBody.Plan -> body.sessionId
            is ToolBody.Question -> body.question
            is ToolBody.SubAgentSpawn -> null
            is ToolBody.AgentCatalog -> null
            is ToolBody.MemorySave -> body.id
            is ToolBody.MemoryList -> "${body.memories.size}"
            is ToolBody.MemoryLoad -> body.query
            // The query is what a *search* is about, so it is the card's identity — same as the other two search tools.
            is ToolBody.SkillList -> body.query.ifEmpty { null }
            is ToolBody.SkillUse -> body.skillName
            is ToolBody.SkillMutation -> body.skillName.ifEmpty { body.name }
            is ToolBody.KanbanMove -> body.taskName
            is ToolBody.KanbanList -> null
            is ToolBody.PresentFiles -> null
            is ToolBody.GenerateImage -> body.model
            is ToolBody.Worktree -> body.path ?: body.branch
            is ToolBody.SessionReader -> body.query
            is ToolBody.ProgressiveTool -> body.name.ifEmpty { body.query }
            is ToolBody.Mcp -> null
            is ToolBody.Empty, is ToolBody.Raw -> null
        }
    }

    /** The argument names worth trying, per tool, in order. */
    private fun primaryParameterKeys(kind: ToolKind): List<String> = when (kind) {
        ToolKind.Shell -> listOf("command")
        ToolKind.Search -> listOf("pattern", "query")
        ToolKind.Glob -> listOf("pattern", "path")
        ToolKind.SkillUse, ToolKind.SkillMutation -> listOf("skill_name", "name", "path")
        ToolKind.MemoryLoad -> listOf("query", "id")
        // A placeholder row has no result yet, so the query has to come from the arguments or a running card says nothing about what it is asking.
        ToolKind.SkillList -> listOf("query")
        ToolKind.Progressive -> listOf("name", "query")
        ToolKind.KanbanMove -> listOf("task_name", "task_id")
        ToolKind.Worktree -> listOf("path", "branch")
        ToolKind.GenerateImage -> listOf("model", "prompt")
        // The provider is the only identity a search envelope has, and a placeholder row carries no result to name it from.
        ToolKind.WebSearch -> listOf("provider")
        ToolKind.Mcp -> listOf("server", "tool")
        else -> listOf(PATH_KEY)
    }

    private fun rightMetaFor(body: ToolBody, pending: Boolean): String? = when {
        pending -> null
        else -> when (body) {
            is ToolBody.ReadFile -> "${body.lines.size}L"
            // The exit code is the one number a reader needs without opening the card, and the *only* thing separating "the shell ran" from "the command worked" — the …
            is ToolBody.Shell -> shellBadges(body).ifEmpty { null }
            is ToolBody.Search -> body.returned?.let { "$it match${if (it == 1) "" else "es"}" }
            is ToolBody.Glob -> body.returned?.let { "$it file${if (it == 1) "" else "s"}" }
            is ToolBody.ListDirectory -> "${body.count}"
            is ToolBody.Diff -> body.linesChanged?.let { "$it line${if (it == 1) "" else "s"}" }
            is ToolBody.SubAgentSpawn ->
                "${body.succeeded} ok · ${body.failed} failed"

            is ToolBody.AgentCatalog -> "${body.count}"
            is ToolBody.MemoryLoad -> "${body.count}/${body.totalCount}"
            // Both paged searches read their header the same way, because they send the same counts: rows in this page over rows in the result.
            is ToolBody.SkillList -> pagingMeta(body.count, body.total, body.truncated)
            is ToolBody.KanbanList -> "${body.totalCount}"
            is ToolBody.PresentFiles -> "${body.count}"
            is ToolBody.GenerateImage -> "${body.count}"
            is ToolBody.ProgressiveTool -> body.query.takeIf { it.isNotEmpty() }
                ?.let { pagingMeta(body.count, body.total, body.truncated) }

            else -> null
        }
    }

    private fun labelFor(toolName: String): String = when (toolName) {
        "run_command" -> "bash"
        else -> toolName.ifBlank { "tool" }
    }

    /** The shell's header badges: exit code, then the warning flags the web shows. */
    private fun shellBadges(body: ToolBody.Shell): String = buildList {
        body.exitCode?.let { add(it.toString()) }
        if (body.truncated) add("truncated")
        if (body.timedOut) add("timeout")
    }.joinToString(" · ")

    /** The header for a paged result: rows in this page over rows in the whole result, with a partial page marked rather than passed off as the answer. */
    private fun pagingMeta(count: Int, total: Int, truncated: Boolean): String = buildList {
        add("$count/$total")
        if (truncated) add("truncated")
    }.joinToString(" · ")

    /** A parameter by name, or null. */
    private fun param(parameters: String, key: String): String? {
        if (parameters.isBlank()) return null
        val json = try {
            JSONObject(parameters)
        } catch (_: Exception) {
            return null
        }
        return json.stringOrNull(key)
    }

    private fun diffOf(message: ChatMessage) = ToolBody.Diff(
        path = message.toolName,
        before = message.diffviewBefore,
        after = message.diffviewAfter,
    )

    /** A failure the envelope does not report. */
    private fun errorInBody(body: ToolBody): String? = body.reportedError

    /** A row whose content is not an envelope is either a raw `mcp_*` success or a tool whose run was cut short by a server restart (`resolveStaleLoadingToolResults` … */
    private fun looksInterrupted(content: String): Boolean =
        content.contains("<interrupted>", ignoreCase = true)

    /** The arguments key that names a file, across the tools that take one. */
    private const val PATH_KEY = "path"
}
