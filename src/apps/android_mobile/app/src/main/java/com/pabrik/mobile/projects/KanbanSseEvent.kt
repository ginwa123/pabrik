package com.pabrik.mobile.projects

import org.json.JSONObject

// Parsed kanban SSE event. Mirrors Vue's KanbanColumnEvent/KanbanTaskEvent.
sealed class KanbanSseEvent {
    data class Column(
        val action: String,
        val workspaceId: String,
        val itemId: String,
        val columnId: String,
        val newName: String? = null,
        val newDescription: String? = null,
        val newPosition: Int? = null,
    ) : KanbanSseEvent()

    data class Task(
        val action: String,
        val workspaceId: String,
        val itemId: String,
        val taskId: String,
        val newColumnId: String? = null,
        val newPosition: Int? = null,
        val needsHumanReview: Boolean? = null,
    ) : KanbanSseEvent()

    companion object {
        fun parse(json: String): KanbanSseEvent? {
            return try {
                val o = JSONObject(json)
                val workspaceId = o.optString("workspace_id")
                val itemId = o.optString("item_id")
                if (o.has("column_id")) {
                    Column(
                        action = o.optString("action"),
                        workspaceId = workspaceId,
                        itemId = itemId,
                        columnId = o.optString("column_id"),
                        newName = o.optString("new_name").takeIf { it.isNotEmpty() },
                        newDescription = o.optString("new_description").takeIf { it.isNotEmpty() },
                        newPosition = if (o.has("new_position") && !o.isNull("new_position")) o.optInt("new_position") else null,
                    )
                } else {
                    Task(
                        action = o.optString("action"),
                        workspaceId = workspaceId,
                        itemId = itemId,
                        taskId = o.optString("task_id"),
                        newColumnId = o.optString("new_column_id").takeIf { it.isNotEmpty() },
                        newPosition = if (o.has("new_position") && !o.isNull("new_position")) o.optInt("new_position") else null,
                        needsHumanReview = if (o.has("needs_human_review") && !o.isNull("needs_human_review")) o.optBoolean("needs_human_review") else null,
                    )
                }
            } catch (e: Exception) {
                null
            }
        }
    }
}
