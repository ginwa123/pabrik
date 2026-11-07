package com.pabrik.mobile.sync

import com.pabrik.mobile.cache.OutboxDao
import com.pabrik.mobile.cache.OutboxEntry
import java.util.UUID

// Single offline write queue. Owns persistence and ordering; network calls
// are delegated to the SyncHandler supplied per drain.
class OutboxQueue(private val dao: OutboxDao) {

    interface SyncHandler {
        suspend fun sync(entry: OutboxEntry): SyncResult
    }

    sealed class SyncResult {
        object Success : SyncResult()
        data class Retryable(val reason: String) : SyncResult()
        data class Permanent(val reason: String) : SyncResult()
    }

    @Volatile
    private var draining: Boolean = false

    val isDraining: Boolean get() = draining

    suspend fun enqueue(
        userId: String,
        entityType: String,
        entityId: String,
        operation: String,
        payload: String,
        updatedAtEpochMillis: Long = 0,
    ): Long {
        val entry = OutboxEntry(
            userId = userId,
            entityType = entityType,
            entityId = entityId,
            operation = operation,
            payload = payload,
            idempotencyKey = UUID.randomUUID().toString(),
            createdAtEpochMillis = System.currentTimeMillis(),
            updatedAtEpochMillis = updatedAtEpochMillis,
        )
        return dao.insert(entry)
    }

    suspend fun pendingCount(userId: String): Int =
        dao.countByStatus(userId, OutboxEntry.STATUS_PENDING)

    suspend fun failedCount(userId: String): Int =
        dao.countByStatus(userId, OutboxEntry.STATUS_FAILED)

    suspend fun pendingEntries(userId: String): List<OutboxEntry> =
        dao.listByStatus(userId, OutboxEntry.STATUS_PENDING)

    // Drain pending rows in createdAt order. Returns count completed.
    suspend fun drain(userId: String, handler: SyncHandler): Int {
        if (draining) return 0
        draining = true
        var done = 0
        try {
            val pending = dao.listByStatus(userId, OutboxEntry.STATUS_PENDING)
            for (entry in pending) {
                dao.update(entry.copy(status = OutboxEntry.STATUS_IN_FLIGHT))
                when (val result = handler.sync(entry)) {
                    is SyncResult.Success -> {
                        dao.deleteById(entry.id)
                        done++
                    }
                    is SyncResult.Retryable -> {
                        dao.update(
                            entry.copy(
                                status = OutboxEntry.STATUS_PENDING,
                                retryCount = entry.retryCount + 1,
                                lastError = result.reason,
                            ),
                        )
                    }
                    is SyncResult.Permanent -> {
                        dao.update(
                            entry.copy(
                                status = OutboxEntry.STATUS_FAILED,
                                lastError = result.reason,
                            ),
                        )
                    }
                }
            }
        } finally {
            draining = false
        }
        return done
    }

    suspend fun retryFailed(userId: String) {
        val failed = dao.listByStatus(userId, OutboxEntry.STATUS_FAILED)
        for (entry in failed) {
            dao.update(entry.copy(status = OutboxEntry.STATUS_PENDING, retryCount = 0, lastError = null))
        }
    }

    suspend fun clearForUser(userId: String) {
        dao.deleteAllForUser(userId)
    }
}
