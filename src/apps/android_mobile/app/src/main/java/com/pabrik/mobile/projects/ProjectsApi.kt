package com.pabrik.mobile.projects

import com.pabrik.mobile.chat.optNullableString
import com.pabrik.mobile.network.UriEncoding
import com.pabrik.mobile.recents.RecentsApi
import com.pabrik.mobile.recents.stringField
import org.json.JSONObject
import java.net.URLEncoder

/** The drawer's two project endpoints, and the wire shapes that come back. */
object ProjectsApi {

    /** Matches the server's own `DEFAULT_PAGE_SIZE` (`tasks_list.zig:33`). */
    const val TASKS_PAGE_LIMIT = 20

    /** The `mode` a kanban card create sends — the plain card, with no agent run. */
    const val KANBAN_MODE_CREATE = "create"

    /** The other half of the web's split button. */
    const val KANBAN_MODE_CREATE_AND_RUN = "create_and_run"

    /** How many of a project's chats the drawer shows before offering the rest. */
    const val DRAWER_PREVIEW_ROWS = 5

    // `/api/workspaces/{id}/items` — the projects of one workspace.
    fun defaultProjectPath(workspaceId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/default-project")
    }

    fun itemsPath(workspaceId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items")
    }

    /** `/api/workspaces/{ws}/items/{item}/tasks` — one page of a project's chats. */
    fun tasksPath(
        workspaceId: String,
        itemId: String,
        cursor: String? = null,
        limit: Int = TASKS_PAGE_LIMIT,
    ): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks?sort_by=updated_at&direction=desc")
        append("&limit=")
        append(limit.coerceIn(1, MAX_LIMIT))
        // A blank cursor is indistinguishable from "first page" to the server, so sending it would restart the list and re-serve page 1 forever.
        if (!cursor.isNullOrBlank()) {
            append("&cursor=")
            append(encodeQueryValue(cursor))
        }
    }

    // `{"items":[…],"count":N}` — every item of one workspace. No pagination
    fun parseDefaultProject(body: String): ProjectSummary? {
        val item = JSONObject(body).optJSONObject("item") ?: return null
        val id = item.stringField("id")
        // A row without an id cannot be scoped to, so it is unusable.
        if (id.isEmpty()) return null
        return ProjectSummary(
            id = id,
            workspaceId = item.stringField("workspace_id"),
            itemType = item.stringField("item_type"),
            name = item.stringField("name"),
            path = item.stringField("path"),
            isDefault = item.optInt("is_default", 1) == 1,
        )
    }

    fun parseItems(body: String): List<ProjectSummary> {
        val items = JSONObject(body).optJSONArray("items") ?: return emptyList()

        return buildList(items.length()) {
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val id = item.stringField("id")
                // A row without an id cannot be scoped to, so it is unusable.
                if (id.isEmpty()) continue
                add(
                    ProjectSummary(
                        id = id,
                        workspaceId = item.stringField("workspace_id"),
                        // Unknown types are kept, not dropped: the UI maps them to a fallback glyph.
                        itemType = item.stringField("item_type"),
                        // Both nullable server-side; `stringField` maps an explicit null to "", and `displayName` turns that into "Untitled project" rather than a blank row.
                        name = item.stringField("name"),
                        path = item.stringField("path"),
                        // Migration 094 sends 0/1, not a JSON boolean, because the column is an INTEGER.
                        isDefault = item.optInt("is_default", 0) == 1,
                    ),
                )
            }
        }
    }

    /** `{"tasks":[…],"count":N,"has_more":B,"next_cursor":S}` — one page. */
    fun parseProjectChatsPage(body: String, projectId: String): ProjectChatsPage {
        val root = JSONObject(body)
        val tasks = root.optJSONArray("tasks")

        val chats = buildList {
            if (tasks == null) return@buildList
            for (index in 0 until tasks.length()) {
                val task = tasks.optJSONObject(index) ?: continue
                // The task id IS the session id, so this is also the key the chat route takes.
                val id = task.stringField("id")
                if (id.isEmpty()) continue
                add(
                    ProjectChat(
                        id = id,
                        projectId = projectId,
                        name = task.stringField("name"),
                        updatedAtEpochMillis = RecentsApi.parseTimestampEpochMillis(
                            task.stringField("updated_at"),
                        ) ?: RecentsApi.parseTimestampEpochMillis(
                            task.stringField("created_at"),
                        ) ?: RecentsApi.UNKNOWN_TIMESTAMP,
                    ),
                )
            }
        }

        val serverHasMore =
            if (root.isNull("has_more")) false else root.optBoolean("has_more", false)

        return ProjectChatsPage(
            chats = chats,
            hasMore = serverHasMore && chats.isNotEmpty(),
            nextCursor = root.optNullableString("next_cursor")?.takeIf { it.isNotBlank() },
        )
    }

    /** Write-through merge for a page append: a same-id incoming row replaces the one already held, order is preserved. */
    fun mergeProjectChatsById(
        current: List<ProjectChat>,
        incoming: List<ProjectChat>,
    ): List<ProjectChat> {
        if (incoming.isEmpty()) return current
        val byId = LinkedHashMap<String, ProjectChat>(current.size + incoming.size)
        current.forEach { chat -> byId[chat.id] = chat }
        incoming.forEach { chat -> byId[chat.id] = chat }
        return byId.values.toList()
    }

    /** `POST /api/workspaces/{ws}/items/{item}/tasks` — create a task. */
    fun createTaskPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks")
    }

    /** `POST /api/workspaces/{ws}/items/{item}/kanban/tasks` — a card on a board. */
    fun createKanbanTaskPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/kanban/tasks")
    }

    /** The JSON body for one [CreateTaskRequest]. */
    fun createTaskBody(request: CreateTaskRequest): String {
        val json = JSONObject()
        when (request) {
            is CreateTaskRequest.StandardChat -> {
                json.put("name", request.name.trim())
                json.put("task_type", TaskTypes.STANDARD)
            }

            is CreateTaskRequest.Memory -> {
                val fileName = request.name.trim()
                json.put("name", fileName)
                json.put("task_type", TaskTypes.MEMORY)
                json.put("memory_name", fileName)
                json.put("memory_content", request.content)
            }

            is CreateTaskRequest.KanbanTask -> {
                // `mode` is not optional and has no default: the handler answers 400 without it (`kanban_tasks_create.zig:110`).
                json.put(
                    "mode",
                    if (request.runAgent) KANBAN_MODE_CREATE_AND_RUN else KANBAN_MODE_CREATE,
                )
                json.put("name", request.name.trim())
                // Sent even when blank.
                json.put("description", request.description)

                // The server's own rules, applied before the wire rather than after: an invalid tag is a 400 that names no field, so the form drops it and the reader never …
                val tags = KanbanTags.normalize(request.tags)
                if (tags.isNotEmpty()) {
                    // A JSON *string* holding an array, not a nested array.
                    json.put("tags", org.json.JSONArray(tags).toString())
                }

                // Migration 070 — the per-task project root.
                json.put("cwd", request.cwd)

                // Migration 063.
                json.put("is_auto_retry_until_stop", if (request.unattended) "1" else "0")

                if (request.runAgent) {
                    json.put("queue_message", request.queueMessage)
                    // The web sends this on create-and-run only ("Path A": the plain create has no sessions row of its own to stamp, so a profile sent there would be a choice the …
                    json.put("selected_profile_model", request.profile)
                }

                // Base64 data URLs.
                val images = request.imageUrls.filter { it.isNotBlank() }
                if (images.isNotEmpty()) {
                    json.put("image_urls", images.joinToString("||"))
                }
            }
        }
        return json.toString()
    }


    /** The one task object `POST .../tasks` returns, as a [ProjectChat]. */
    fun parseCreatedTask(body: String, projectId: String): ProjectChat? {
        val task = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }

        val id = task.stringField("id")
        if (id.isEmpty()) return null

        return ProjectChat(
            id = id,
            projectId = projectId,
            name = task.stringField("name"),
            // Prefer `updated_at` and fall back the same way the list parser does, so a created row and a listed row of the same task are ordered the same way in a merged …
            updatedAtEpochMillis = RecentsApi.parseTimestampEpochMillis(
                task.stringField("updated_at"),
            ) ?: RecentsApi.parseTimestampEpochMillis(
                task.stringField("created_at"),
            ) ?: RecentsApi.UNKNOWN_TIMESTAMP,
            taskType = task.optNullableString("task_type"),
        )
    }

    /** `POST .../kanban/tasks` answers `201 {"task": {…}, "session": null}` — an **envelope**, not a bare row. */
    fun parseCreatedKanbanTask(body: String, projectId: String): ProjectChat? {
        val envelope = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }

        val task = envelope.optJSONObject("task") ?: return null
        val id = task.stringField("id")
        if (id.isEmpty()) return null

        return ProjectChat(
            id = id,
            projectId = projectId,
            name = task.stringField("name"),
            updatedAtEpochMillis = RecentsApi.UNKNOWN_TIMESTAMP,
        )
    }

    private fun encodeQueryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    /** The server clamps to 100 (`tasks_list.zig:37`); clamp again to be safe. */
    private const val MAX_LIMIT = 100
}
