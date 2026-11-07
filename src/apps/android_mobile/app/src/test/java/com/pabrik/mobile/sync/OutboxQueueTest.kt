package com.pabrik.mobile.sync

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.pabrik.mobile.cache.OutboxDao
import com.pabrik.mobile.cache.OutboxEntry
import com.pabrik.mobile.cache.PabrikCacheDatabase
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OutboxQueueTest {

    private lateinit var database: PabrikCacheDatabase
    private lateinit var dao: OutboxDao
    private lateinit var queue: OutboxQueue

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            PabrikCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        dao = database.outboxDao()
        queue = OutboxQueue(dao)
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun enqueueOne(userId: String = "u1", entityId: String = "e1") {
        runBlocking {
            queue.enqueue(
                userId = userId,
                entityType = "workspace",
                entityId = entityId,
                operation = OutboxEntry.OP_UPDATE,
                payload = "{}",
            )
        }
    }

    @Test
    fun enqueueInsertsPendingRow() {
        enqueueOne()
        assertEquals(1, runBlocking { queue.pendingCount("u1") })
    }

    @Test
    fun drainSuccessDeletesRow() {
        enqueueOne()
        val handler = object : OutboxQueue.SyncHandler {
            override suspend fun sync(entry: OutboxEntry): OutboxQueue.SyncResult =
                OutboxQueue.SyncResult.Success
        }
        val done = runBlocking { queue.drain("u1", handler) }
        assertEquals(1, done)
        assertEquals(0, runBlocking { queue.pendingCount("u1") })
    }

    @Test
    fun drainRetryableKeepsRowPendingAndBumpsRetry() {
        enqueueOne()
        val handler = object : OutboxQueue.SyncHandler {
            override suspend fun sync(entry: OutboxEntry): OutboxQueue.SyncResult =
                OutboxQueue.SyncResult.Retryable("5xx")
        }
        val done = runBlocking { queue.drain("u1", handler) }
        assertEquals(0, done)
        assertEquals(1, runBlocking { queue.pendingCount("u1") })
        val row = runBlocking { dao.listByStatus("u1", OutboxEntry.STATUS_PENDING).first() }
        assertEquals(1, row.retryCount)
        assertEquals("5xx", row.lastError)
    }

    @Test
    fun drainPermanentMarksFailed() {
        enqueueOne()
        val handler = object : OutboxQueue.SyncHandler {
            override suspend fun sync(entry: OutboxEntry): OutboxQueue.SyncResult =
                OutboxQueue.SyncResult.Permanent("400")
        }
        val done = runBlocking { queue.drain("u1", handler) }
        assertEquals(0, done)
        assertEquals(0, runBlocking { queue.pendingCount("u1") })
        assertEquals(1, runBlocking { queue.failedCount("u1") })
    }

    @Test
    fun drainOrdersByCreatedAt() {
        val order = mutableListOf<String>()
        runBlocking {
            queue.enqueue("u1", "workspace", "first", OutboxEntry.OP_UPDATE, "{}")
            Thread.sleep(2)
            queue.enqueue("u1", "workspace", "second", OutboxEntry.OP_UPDATE, "{}")
        }
        val handler = object : OutboxQueue.SyncHandler {
            override suspend fun sync(entry: OutboxEntry): OutboxQueue.SyncResult {
                order.add(entry.entityId)
                return OutboxQueue.SyncResult.Success
            }
        }
        runBlocking { queue.drain("u1", handler) }
        assertEquals(listOf("first", "second"), order)
    }

    @Test
    fun retryFailedResetsToPending() {
        enqueueOne()
        val handler = object : OutboxQueue.SyncHandler {
            override suspend fun sync(entry: OutboxEntry): OutboxQueue.SyncResult =
                OutboxQueue.SyncResult.Permanent("400")
        }
        runBlocking { queue.drain("u1", handler) }
        assertEquals(1, runBlocking { queue.failedCount("u1") })
        runBlocking { queue.retryFailed("u1") }
        assertEquals(0, runBlocking { queue.failedCount("u1") })
        assertEquals(1, runBlocking { queue.pendingCount("u1") })
    }

    @Test
    fun clearForUserRemovesAll() {
        enqueueOne(entityId = "a")
        enqueueOne(entityId = "b")
        runBlocking { queue.clearForUser("u1") }
        assertEquals(0, runBlocking { queue.pendingCount("u1") })
    }

    @Test
    fun isDrainingFlag() {
        assertTrue(!queue.isDraining)
    }
}
