package com.pabrik.mobile.cache

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

// One pending write in the offline outbox. Drained in createdAt order by
// OutboxQueue; removed only after the handler reports success.
@Entity(
    tableName = "outbox",
    indices = [
        Index(value = ["user_id", "status", "created_at_epoch_millis"]),
        Index(value = ["idempotency_key"], unique = true),
    ],
)
data class OutboxEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "entity_type") val entityType: String,
    @ColumnInfo(name = "entity_id") val entityId: String,
    val operation: String,
    val payload: String,
    @ColumnInfo(name = "idempotency_key") val idempotencyKey: String,
    @ColumnInfo(name = "created_at_epoch_millis") val createdAtEpochMillis: Long,
    @ColumnInfo(name = "retry_count") val retryCount: Int = 0,
    val status: String = STATUS_PENDING,
    @ColumnInfo(name = "last_error") val lastError: String? = null,
    @ColumnInfo(name = "updated_at_epoch_millis") val updatedAtEpochMillis: Long = 0,
) {
    companion object {
        const val STATUS_PENDING = "pending"
        const val STATUS_IN_FLIGHT = "in_flight"
        const val STATUS_DONE = "done"
        const val STATUS_FAILED = "failed"

        const val OP_CREATE = "create"
        const val OP_UPDATE = "update"
        const val OP_DELETE = "delete"
    }
}
