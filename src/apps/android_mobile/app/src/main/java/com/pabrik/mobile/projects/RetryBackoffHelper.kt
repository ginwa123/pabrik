package com.pabrik.mobile.projects

// Retry backoff helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object RetryBackoffHelper {

    const val MIN_RETRIES = 0
    const val MAX_RETRIES = 10
    const val MIN_BACKOFF_MS = 100L
    const val MAX_BACKOFF_MS = 60_000L

    fun isValidRetryCount(n: Int): Boolean = n in MIN_RETRIES..MAX_RETRIES

    fun isValidBackoffMs(ms: Long): Boolean = ms in MIN_BACKOFF_MS..MAX_BACKOFF_MS

    // Compute next backoff given current attempt (exponential, capped).
    fun nextBackoffMs(currentMs: Long, attempt: Int): Long {
        val next = currentMs * (1L shl attempt.coerceAtMost(10))
        return next.coerceAtMost(MAX_BACKOFF_MS)
    }
}
