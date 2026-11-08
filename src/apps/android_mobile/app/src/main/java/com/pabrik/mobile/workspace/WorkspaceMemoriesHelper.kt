package com.pabrik.mobile.workspace

data class WorkspaceMemory(
    val id: String,
    val content: String,
    val tags: List<String>,
    val updatedAtEpochMillis: Long,
)

object WorkspaceMemoriesHelper {
    const val MAX_CONTENT_LEN = 100_000

    fun isValidContent(content: String): Boolean {
        val trimmed = content.trim()
        return trimmed.isNotEmpty() && trimmed.length <= MAX_CONTENT_LEN
    }

    fun parseTags(raw: String): List<String> =
        raw.split(',', ' ', '\n', '\t')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()

    fun joinTags(tags: List<String>): String = tags.joinToString(",")

    fun filterByQuery(memories: List<WorkspaceMemory>, query: String): List<WorkspaceMemory> {
        val q = query.trim()
        if (q.isEmpty()) return memories
        return memories.filter { memory ->
            memory.content.contains(q, ignoreCase = true) ||
                memory.tags.any { it.contains(q, ignoreCase = true) }
        }
    }

    fun sortByUpdatedDesc(memories: List<WorkspaceMemory>): List<WorkspaceMemory> =
        memories.sortedByDescending { it.updatedAtEpochMillis }

    fun dedupe(memories: List<WorkspaceMemory>): List<WorkspaceMemory> {
        val seen = mutableSetOf<String>()
        return memories.filter { seen.add(it.content.trim()) }
    }
}
