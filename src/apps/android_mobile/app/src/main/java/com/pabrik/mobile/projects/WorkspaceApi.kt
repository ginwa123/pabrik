package com.pabrik.mobile.projects

import com.pabrik.mobile.network.UriEncoding
import org.json.JSONObject

// Workspace CRUD endpoints (Vue: src/api/workspaces.ts). Pure path/body helpers.
object WorkspaceApi {

    fun listPath(): String = "/api/workspaces?is_include_items=false"

    fun getPath(id: String): String = "/api/workspaces/${UriEncoding.encode(id)}"

    fun createPath(): String = "/api/workspaces"

    fun createBody(name: String): String =
        JSONObject().put("name", name).toString()

    fun updatePath(id: String): String = "/api/workspaces/${UriEncoding.encode(id)}"

    fun updateBody(name: String): String =
        JSONObject().put("name", name).toString()

    fun deletePath(id: String): String = "/api/workspaces/${UriEncoding.encode(id)}"

    fun reorderPath(): String = "/api/workspaces/reorder"

    fun reorderBody(orderedIds: List<String>): String =
        JSONObject().put("ordered_ids", org.json.JSONArray(orderedIds)).toString()

    // Items
    fun itemsPath(workspaceId: String): String =
        "/api/workspaces/${UriEncoding.encode(workspaceId)}/items"

    fun createItemPath(workspaceId: String): String =
        "/api/workspaces/${UriEncoding.encode(workspaceId)}/items"

    fun createItemBody(name: String, path: String, itemType: String = "folder"): String =
        JSONObject().put("name", name).put("path", path).put("item_type", itemType).toString()

    fun deleteItemPath(workspaceId: String, itemId: String): String =
        "/api/workspaces/${UriEncoding.encode(workspaceId)}/items/${UriEncoding.encode(itemId)}"

    fun reorderItemsPath(workspaceId: String): String =
        "/api/workspaces/${UriEncoding.encode(workspaceId)}/items/reorder"

    fun reorderItemsBody(orderedIds: List<String>): String =
        JSONObject().put("ordered_ids", org.json.JSONArray(orderedIds)).toString()

    fun parseWorkspace(body: String): String? {
        return try {
            val o = JSONObject(body)
            o.optString("id").takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            null
        }
    }
}
