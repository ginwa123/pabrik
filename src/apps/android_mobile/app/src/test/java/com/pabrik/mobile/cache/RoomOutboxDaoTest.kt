package com.pabrik.mobile.cache

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomOutboxDaoTest {

    private lateinit var database: PabrikCacheDatabase
    private lateinit var dao: OutboxDao

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            PabrikCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        dao = database.outboxDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun entry(
        userId: String = "u1",
        entityType: String = "workspace",
        entityId: String = "w1",
        operation: String = OutboxEntry.OP_UPDATE,
        payload: String = "{}",
        createdAt: Long = 1_000L,
        status: String = OutboxEntry.STATUS_PENDING,
    ) = OutboxEntry(
        userId = userId,
        entityType = entityType,
        entityId = entityId,
        operation = operation,
        payload = payload,
        idempotencyKey = "key-$entityId-$createdAt",
        createdAtEpochMillis = createdAt,
        status = status,
    )

    @Test
    fun insertAndReadBack() {
        val id = kotlinx.coroutines.runBlocking { dao.insert(entry()) }
        val read = kotlinx.coroutines.runBlocking { dao.getById(id) }
        assertEquals("workspace", read?.entityType)
        assertEquals(OutboxEntry.STATUS_PENDING, read?.status)
    }

    @Test
    fun listByStatusOrdersByCreatedAt() {
        kotlinx.coroutines.runBlocking {
            dao.insert(entry(entityId = "a", createdAt = 3_000L))
            dao.insert(entry(entityId = "b", createdAt = 1_000L))
            dao.insert(entry(entityId = "c", createdAt = 2_000L))
        }
        val list = kotlinx.coroutines.runBlocking {
            dao.listByStatus("u1", OutboxEntry.STATUS_PENDING)
        }
        assertEquals(listOf("b", "c", "a"), list.map { it.entityId })
    }

    @Test
    fun countByStatus() {
        kotlinx.coroutines.runBlocking {
            dao.insert(entry(entityId = "a", status = OutboxEntry.STATUS_PENDING))
            dao.insert(entry(entityId = "b", status = OutboxEntry.STATUS_FAILED))
        }
        assertEquals(1, kotlinx.coroutines.runBlocking { dao.countByStatus("u1", OutboxEntry.STATUS_PENDING) })
        assertEquals(1, kotlinx.coroutines.runBlocking { dao.countByStatus("u1", OutboxEntry.STATUS_FAILED) })
        assertEquals(2, kotlinx.coroutines.runBlocking { dao.countAll("u1") })
    }

    @Test
    fun deleteByIdRemovesRow() {
        val id = kotlinx.coroutines.runBlocking { dao.insert(entry()) }
        kotlinx.coroutines.runBlocking { dao.deleteById(id) }
        assertNull(kotlinx.coroutines.runBlocking { dao.getById(id) })
    }

    @Test
    fun deleteAllForUserRemovesOnlyThatUser() {
        kotlinx.coroutines.runBlocking {
            dao.insert(entry(userId = "u1", entityId = "a"))
            dao.insert(entry(userId = "u2", entityId = "b"))
        }
        kotlinx.coroutines.runBlocking { dao.deleteAllForUser("u1") }
        assertEquals(0, kotlinx.coroutines.runBlocking { dao.countAll("u1") })
        assertEquals(1, kotlinx.coroutines.runBlocking { dao.countAll("u2") })
    }

    @Test
    fun updateChangesStatus() {
        val id = kotlinx.coroutines.runBlocking { dao.insert(entry()) }
        val row = kotlinx.coroutines.runBlocking { dao.getById(id)!! }
        kotlinx.coroutines.runBlocking { dao.update(row.copy(status = OutboxEntry.STATUS_FAILED, lastError = "boom")) }
        val updated = kotlinx.coroutines.runBlocking { dao.getById(id)!! }
        assertEquals(OutboxEntry.STATUS_FAILED, updated.status)
        assertEquals("boom", updated.lastError)
    }
}
