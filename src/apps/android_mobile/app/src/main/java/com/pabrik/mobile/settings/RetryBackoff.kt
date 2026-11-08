package com.pabrik.mobile.settings

object RetryBackoff {
    const val DEFAULT_BASE_MS = 1_000L
    const val DEFAULT_CAP_MS = 60_000L

    fun delayFor(attempt: Int, baseMs: Long = DEFAULT_BASE_MS, capMs: Long = DEFAULT_CAP_MS): Long {
        if (attempt <= 0) return 0
        val shift = (attempt - 1).coerceAtMost(30)
        return (baseMs shl shift).coerceAtMost(capMs)
    }

    fun shouldRetry(attempt: Int, maxAttempts: Int): Boolean = attempt < maxAttempts
}
