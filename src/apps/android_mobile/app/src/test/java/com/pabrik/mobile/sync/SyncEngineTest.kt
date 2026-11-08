package com.pabrik.mobile.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

data class TestItem(
    override val syncId: String,
    override val updatedAtEpochMillis: Long,
    override val isDeleted: Boolean = false,
    val title: String = "",
) : Syncable<TestItem> {
    override fun asDeleted(updatedAtEpochMillis: Long): TestItem =
        copy(updatedAtEpochMillis = updatedAtEpochMillis, isDeleted = true)
}

class SyncEngineTest {

    private fun ids(items: List<TestItem>): List<String> = items.map { it.syncId }.sorted()

    @Test
    fun mergingTwoEmptyListsYieldsNothing() {
        assertTrue(SyncEngine.merge(emptyList<TestItem>(), emptyList()).isEmpty())
    }

    @Test
    fun remoteOnlyEntityIsPulledIntoTheMergedResult() {
        val merged = SyncEngine.merge(emptyList(), listOf(TestItem("a", 100)))
        assertEquals(listOf("a"), ids(merged))
    }

    @Test
    fun localOnlyEntityIsKeptInTheMergedResult() {
        val merged = SyncEngine.merge(listOf(TestItem("a", 100)), emptyList())
        assertEquals(listOf("a"), ids(merged))
    }

    @Test
    fun newerRemoteCopyWinsOverOlderLocalCopy() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 100, title = "local")),
            listOf(TestItem("a", 200, title = "remote")),
        )
        assertEquals("remote", merged.single().title)
    }

    @Test
    fun newerLocalCopyWinsOverOlderRemoteCopy() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 200, title = "local")),
            listOf(TestItem("a", 100, title = "remote")),
        )
        assertEquals("local", merged.single().title)
    }

    @Test
    fun equalTimestampsResolveToTheRemoteCopy() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 100, title = "local")),
            listOf(TestItem("a", 100, title = "remote")),
        )
        assertEquals("remote", merged.single().title)
    }

    @Test
    fun newerRemoteTombstoneRemovesTheEntity() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 100)),
            listOf(TestItem("a", 200, isDeleted = true)),
        )
        assertTrue(merged.isEmpty())
    }

    @Test
    fun newerLocalTombstoneRemovesTheEntity() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 200, isDeleted = true)),
            listOf(TestItem("a", 100)),
        )
        assertTrue(merged.isEmpty())
    }

    @Test
    fun olderRemoteTombstoneLosesToNewerLocalCopy() {
        val merged = SyncEngine.merge(
            listOf(TestItem("a", 200, title = "local")),
            listOf(TestItem("a", 100, isDeleted = true)),
        )
        assertEquals("local", merged.single().title)
    }

    @Test
    fun localOnlyListsIdsMissingFromRemote() {
        val local = listOf(TestItem("a", 100), TestItem("b", 100))
        val remote = listOf(TestItem("a", 100))
        assertEquals(listOf("b"), SyncEngine.localOnly(local, remote))
    }

    @Test
    fun remoteOnlyListsIdsMissingFromLocal() {
        val local = listOf(TestItem("a", 100))
        val remote = listOf(TestItem("a", 100), TestItem("c", 100))
        assertEquals(listOf("c"), SyncEngine.remoteOnly(local, remote))
    }

    @Test
    fun localOnlySkipsTombstones() {
        val local = listOf(TestItem("a", 100, isDeleted = true))
        assertTrue(SyncEngine.localOnly(local, emptyList()).isEmpty())
    }

    @Test
    fun remoteOnlySkipsTombstones() {
        val remote = listOf(TestItem("a", 100, isDeleted = true))
        assertTrue(SyncEngine.remoteOnly(emptyList(), remote).isEmpty())
    }

    @Test
    fun writeAgainstEmptyStateIsStored() {
        val incoming = TestItem("a", 100, title = "new")
        assertSame(incoming, SyncEngine.applyWrite(null, incoming))
    }

    @Test
    fun newerWriteReplacesTheStoredEntity() {
        val current = TestItem("a", 100, title = "old")
        val incoming = TestItem("a", 200, title = "new")
        assertEquals("new", SyncEngine.applyWrite(current, incoming).title)
    }

    @Test
    fun olderWriteIsIgnored() {
        val current = TestItem("a", 200, title = "current")
        val incoming = TestItem("a", 100, title = "stale")
        assertEquals("current", SyncEngine.applyWrite(current, incoming).title)
    }

    @Test
    fun equalTimestampWriteKeepsTheStoredEntity() {
        val current = TestItem("a", 100, title = "current")
        val incoming = TestItem("a", 100, title = "duplicate")
        assertEquals("current", SyncEngine.applyWrite(current, incoming).title)
    }

    @Test
    fun replayingTheSameWriteTwiceLeavesStateUnchanged() {
        val incoming = TestItem("a", 100, title = "new")
        val once = SyncEngine.applyWrite(null, incoming)
        val twice = SyncEngine.applyWrite(once, incoming)
        assertEquals(once, twice)
    }

    @Test
    fun tombstoneWriteIsStoredSoItCanPropagate() {
        val current = TestItem("a", 100)
        val tombstone = TestItem("a", 200, isDeleted = true)
        val stored = SyncEngine.applyWrite(current, tombstone)
        assertTrue(stored.isDeleted)
        assertEquals(200, stored.updatedAtEpochMillis)
    }

    @Test
    fun deletingAnEntityProducesATombstoneWithTheGivenTimestamp() {
        val tombstone = SyncEngine.delete(TestItem("a", 100), 300)
        assertTrue(tombstone.isDeleted)
        assertEquals(300, tombstone.updatedAtEpochMillis)
        assertEquals("a", tombstone.syncId)
    }

    @Test
    fun aDeletedEntityDisappearsFromTheMergedView() {
        val tombstone = SyncEngine.delete(TestItem("a", 100), 300)
        val merged = SyncEngine.merge(listOf(tombstone), listOf(TestItem("a", 200)))
        assertTrue(merged.isEmpty())
    }

    @Test
    fun visibleDropsTombstonesAndKeepsLiveEntities() {
        val entities = listOf(
            TestItem("a", 100),
            TestItem("b", 100, isDeleted = true),
        )
        assertEquals(listOf("a"), ids(SyncEngine.visible(entities)))
    }

    @Test
    fun visibleKeepsEveryLiveEntity() {
        val entities = listOf(TestItem("a", 100), TestItem("b", 100))
        assertEquals(listOf("a", "b"), ids(SyncEngine.visible(entities)))
    }
}
