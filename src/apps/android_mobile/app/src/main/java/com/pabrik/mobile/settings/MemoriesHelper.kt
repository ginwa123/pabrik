package com.pabrik.mobile.settings

data class MemoryItem(
    val name: String,
    val title: String,
    val updatedAtEpochMillis: Long,
)

object MemoriesHelper {

    fun isValidName(name: String): Boolean {
        val trimmed = name.trim()
        return trimmed.isNotEmpty() && !trimmed.contains('/') && !trimmed.contains('\\')
    }

    fun isValidContent(content: String): Boolean = content.trim().isNotEmpty()

    fun validateNew(name: String, content: String, existing: List<String>): String? {
        if (!isValidName(name)) return "NameInvalid"
        if (existing.any { it.equals(name.trim(), ignoreCase = true) }) return "NameTaken"
        if (!isValidContent(content)) return "ContentRequired"
        return null
    }

    fun filter(memories: List<MemoryItem>, query: String): List<MemoryItem> {
        val q = query.trim()
        if (q.isEmpty()) return memories
        return memories.filter {
            it.name.contains(q, ignoreCase = true) || it.title.contains(q, ignoreCase = true)
        }
    }

    fun sortByUpdatedDesc(memories: List<MemoryItem>): List<MemoryItem> =
        memories.sortedByDescending { it.updatedAtEpochMillis }
}
