package com.pabrik.mobile.sse

object DocumentsSseHelper {
    const val REFRESH_THROTTLE_MS = 10_000L

    fun shouldHandle(eventWorkspaceId: String, activeWorkspaceId: String): Boolean =
        eventWorkspaceId == activeWorkspaceId

    fun shouldRefresh(lastFetchAt: Long, nowMillis: Long, throttleMs: Long = REFRESH_THROTTLE_MS): Boolean =
        lastFetchAt <= 0 || nowMillis - lastFetchAt >= throttleMs
}
