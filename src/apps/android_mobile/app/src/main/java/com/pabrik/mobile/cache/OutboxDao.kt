package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update

// Outbox table access. Reads ordered by createdAt so drains replay in order.
@Dao
interface OutboxDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entry: OutboxEntry): Long

    @Update
    suspend fun update(entry: OutboxEntry)

    @Query("SELECT * FROM outbox WHERE user_id = :userId AND status = :status ORDER BY created_at_epoch_millis ASC, id ASC")
    suspend fun listByStatus(userId: String, status: String): List<OutboxEntry>

    @Query("SELECT * FROM outbox WHERE user_id = :userId ORDER BY created_at_epoch_millis ASC, id ASC")
    suspend fun listAll(userId: String): List<OutboxEntry>

    @Query("SELECT COUNT(*) FROM outbox WHERE user_id = :userId AND status = :status")
    suspend fun countByStatus(userId: String, status: String): Int

    @Query("SELECT COUNT(*) FROM outbox WHERE user_id = :userId")
    suspend fun countAll(userId: String): Int

    @Query("DELETE FROM outbox WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("DELETE FROM outbox WHERE user_id = :userId")
    suspend fun deleteAllForUser(userId: String)

    @Query("DELETE FROM outbox WHERE user_id = :userId AND status = :status")
    suspend fun deleteByStatus(userId: String, status: String)

    @Query("SELECT * FROM outbox WHERE id = :id")
    suspend fun getById(id: Long): OutboxEntry?
}
