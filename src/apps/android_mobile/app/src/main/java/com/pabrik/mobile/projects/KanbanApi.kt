package com.pabrik.mobile.projects

import com.pabrik.mobile.network.UriEncoding
import com.pabrik.mobile.recents.stringField
import org.json.JSONObject

/** The routes and the wire shapes the "New task" form needs **besides** the create POST, which lives in [ProjectsApi.createTaskBody]. */
object KanbanApi {
    /** `GET /api/workspaces/{ws}/items/{item}/kanban/columns` — the board's columns, in board order. */
    fun columnsPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/kanban/columns")
    }

    /** `PATCH /api/workspaces/{ws}/items/{item}/tasks/{taskId}/move` — put a card in a chosen column. */
    fun moveTaskPath(workspaceId: String, itemId: String, taskId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/tasks/")
        append(UriEncoding.encode(taskId))
        append("/move")
    }

    /** The move's body. */
    fun moveTaskBody(columnId: String, position: Int = 0): String {
        val json = JSONObject()
        json.put("column_id", columnId)
        json.put("position", position)
        return json.toString()
    }

    /** `GET /api/system/folder?action=list` — the **server's** home directory. */
    fun serverHomePath(): String = "/api/system/folder?action=list"

    /** The board's columns, in the order the server gave them. */
    fun parseColumns(body: String): List<KanbanColumn>? {
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        val array = json.optJSONArray("columns") ?: return null
        val columns = mutableListOf<KanbanColumn>()
        for (index in 0 until array.length()) {
            val entry = array.optJSONObject(index) ?: continue
            val id = entry.stringField("id")
            if (id.isEmpty()) continue
            columns += KanbanColumn(
                id = id,
                name = entry.stringField("name"),
                position = entry.optInt("position", index),
            )
        }
        return columns
    }

    /** The `home` string out of the folder listing, or "" when the body carries none. */
    fun parseServerHome(body: String): String {
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return ""
        }
        return json.stringField("home").trim()
    }
}
