package com.pabrik.mobile.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncRegistryTest {

    @Test
    fun everyFeatureUsesLastWriteWins() {
        assertTrue(SyncRegistry.FEATURES.all { it.mergePolicy == SyncRegistry.POLICY_LWW })
    }

    @Test
    fun everyFeatureHasAUniqueEntityType() {
        val types = SyncRegistry.FEATURES.map { it.entityType }
        assertEquals(types.size, types.distinct().size)
    }

    @Test
    fun aKnownEntityTypeResolvesToItsFeature() {
        assertEquals("kanban", SyncRegistry.forEntityType("kanban_task")?.id)
    }

    @Test
    fun anUnknownEntityTypeResolvesToNothing() {
        assertNull(SyncRegistry.forEntityType("ghost"))
    }

    @Test
    fun aKnownEntityTypeIsSyncable() {
        assertTrue(SyncRegistry.isSyncable("document"))
    }

    @Test
    fun anUnknownEntityTypeIsNotSyncable() {
        assertFalse(SyncRegistry.isSyncable("ghost"))
    }

    @Test
    fun theMergePolicyDefaultsToLastWriteWins() {
        assertEquals(SyncRegistry.POLICY_LWW, SyncRegistry.mergePolicyFor("ghost"))
    }

    @Test
    fun settingsDoNotSupportDelete() {
        assertFalse(SyncRegistry.supportsDelete("setting"))
    }

    @Test
    fun documentsSupportDelete() {
        assertTrue(SyncRegistry.supportsDelete("document"))
    }

    @Test
    fun anUnknownEntityTypeDoesNotSupportDelete() {
        assertFalse(SyncRegistry.supportsDelete("ghost"))
    }

    @Test
    fun aDeleteMapsToTheDeleteOperation() {
        assertEquals("delete", SyncRegistry.outboxOperation(isDelete = true, exists = true))
    }

    @Test
    fun AnExistingEntityMapsToUpdate() {
        assertEquals("update", SyncRegistry.outboxOperation(isDelete = false, exists = true))
    }

    @Test
    fun aNewEntityMapsToCreate() {
        assertEquals("create", SyncRegistry.outboxOperation(isDelete = false, exists = false))
    }

    @Test
    fun theSyncKeyCombinesTypeAndId() {
        assertEquals("kanban_task:t1", SyncRegistry.syncKey("kanban_task", "t1"))
    }
}
