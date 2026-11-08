package com.pabrik.mobile.sse

object KanbanSseHelper {
    const val LOCAL_MUTATION_TTL_MS = 1_500L

    fun shouldHandle(eventWorkspaceId: String, activeWorkspaceId: String): Boolean =
        eventWorkspaceId == activeWorkspaceId

    fun eventFamily(hasColumnId: Boolean, hasTaskId: Boolean): String = when {
        hasColumnId -> "column"
        hasTaskId -> "task"
        else -> "unknown"
    }

    fun isHumanTouched(action: String): Boolean = action == "human_touched"

    fun shouldRefetchColumn(hasSearch: Boolean, hasCustomSort: Boolean, isCached: Boolean): Boolean =
        !hasSearch && !hasCustomSort && isCached

    fun isRecentLocalMutation(lastMutationAt: Long, nowMillis: Long, ttlMs: Long = LOCAL_MUTATION_TTL_MS): Boolean =
        lastMutationAt > 0 && nowMillis - lastMutationAt < ttlMs
}
