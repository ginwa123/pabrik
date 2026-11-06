package com.pabrik.mobile.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

data class TestItem(
    override val syncId: String,
    override val updatedAtEpochMillis: Long,
    override val isDeleted: Boolean = false,
) : Syncable

class SyncEngineTest {

    @Test
    fun emptyMergeIsEmpty() {
        assertEquals(emptyList<TestItem>(), SyncEngine.merge(emptyList(), emptyList()))
    }

    @Test
    fun remoteOnlyItemsArePulled() {
        val remote = listOf(TestItem("a", 100))
        val merged = SyncEngine.merge(emptyList(), remote)
        assertEquals(listOf("a"), merged.map { it.syncId })
    }

    @Test
    fun localOnlyItemsAreKept() {
        val local = listOf(TestItem("a", 100))
        val merged = SyncEngine.merge(local, emptyList())
        assertEquals(listOf("a"), merged.map { it.syncId })
    }

    @Test
    fun remoteWinsWhenNewer() {
        val local = listOf(TestItem("a", 100))
        val remote = listOf(TestItem("a", 200))
        val merged = SyncEngine.merge(local, remote)
        assertEquals(200, merged.first().updatedAtEpochMillis)
    }

    @Test
    fun localWinsWhenNewer() {
        val local = listOf(TestItem("a", 200))
        val remote = listOf(TestItem("a", 100))
        val merged = SyncEngine.merge(local, remote)
        assertEquals(200, merged.first().updatedAtEpochMillis)
    }

    @Test
    fun tieGoesToRemote() {
        val local = listOf(TestItem("a", 100))
        val remote = listOf(TestItem("a", 100, isDeleted = false))
        // remote wins tie; both same content, result has one
        assertEquals(1, SyncEngine.merge(local, remote).size)
    }

    @Test
    fun deletedRemoteDropsEntity() {
        val local = listOf(TestItem("a", 100))
        val remote = listOf(TestItem("a", 200, isDeleted = true))
        val merged = SyncEngine.merge(local, remote)
        assertTrue(merged.isEmpty())
    }

    @Test
    fun deletedLocalDropsEntity() {
        val local = listOf(TestItem("a", 200, isDeleted = true))
        val remote = listOf(TestItem("a", 100))
        val merged = SyncEngine.merge(local, remote)
        // remote older but local deleted; remote wins? remote updatedAt 100 < 200, local wins but deleted -> dropped
        assertTrue(merged.isEmpty())
    }

    @Test
    fun localOnlyHelper() {
        val local = listOf(TestItem("a", 100), TestItem("b", 100))
        val remote = listOf(TestItem("a", 100))
        assertEquals(listOf("b"), SyncEngine.localOnly(local, remote))
    }

    @Test
    fun remoteOnlyHelper() {
        val local = listOf(TestItem("a", 100))
        val remote = listOf(TestItem("a", 100), TestItem("c", 100))
        assertEquals(listOf("c"), SyncEngine.remoteOnly(local, remote))
    }

    @Test
    fun utcFormatEmptyForZero() {
        assertEquals("", UtcTime.format(0))
    }

    @Test
    fun utcFormatNonEmpty() {
        assertTrue(UtcTime.format(1_700_000_000_000L).isNotEmpty())
    }
}
