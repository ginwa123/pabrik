package com.pabrik.mobile.projects

// Folder helpers. Folders are workspace items with item_type == "folder".
object FolderHelper {
    const val TYPE_FOLDER = "folder"

    fun isFolder(itemType: String): Boolean = itemType == TYPE_FOLDER

    // Returns items whose parentId matches folderId. parentId is supplied by
    // the caller (e.g. derived from the item's path or a parent field).
    fun <T> childrenOf(items: List<T>, folderId: String?, parentIdOf: (T) -> String?): List<T> =
        items.filter { parentIdOf(it) == folderId }

    // Returns top-level items (no parent).
    fun <T> topLevel(items: List<T>, parentIdOf: (T) -> String?): List<T> =
        items.filter { parentIdOf(it).isNullOrEmpty() }
}
