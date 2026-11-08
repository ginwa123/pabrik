package com.pabrik.mobile.sse

object DesignSseHelper {
    const val LOCAL_MUTATION_TTL_MS = 1_500L

    fun shouldHandle(eventWorkspaceId: String, activeWorkspaceId: String): Boolean =
        eventWorkspaceId == activeWorkspaceId

    fun extractElementIds(elementId: String?, elementIds: List<String>?): List<String> {
        val ids = mutableListOf<String>()
        if (!elementId.isNullOrBlank()) ids.add(elementId)
        elementIds?.forEach { if (it.isNotBlank()) ids.add(it) }
        return ids.distinct()
    }

    fun allLocal(
        ids: List<String>,
        lastMutationAt: Map<String, Long>,
        nowMillis: Long,
        ttlMs: Long = LOCAL_MUTATION_TTL_MS,
    ): Boolean {
        if (ids.isEmpty()) return false
        return ids.all { id ->
            val at = lastMutationAt[id] ?: return@all false
            at > 0 && nowMillis - at < ttlMs
        }
    }
}
