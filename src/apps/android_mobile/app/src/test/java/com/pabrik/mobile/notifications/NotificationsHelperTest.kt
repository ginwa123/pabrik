package com.pabrik.mobile.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationsHelperTest {

    private fun note(id: String, createdAt: Long = 0) =
        NotificationItem(id, "message", null, createdAt)

    @Test
    fun addingANotificationAppendsIt() {
        val list = NotificationsHelper.add(emptyList(), "n1", "boom", "details", 100)
        assertEquals(listOf("n1"), list.map { it.id })
        assertEquals("boom", list.single().message)
        assertEquals("details", list.single().details)
        assertEquals(100, list.single().createdAtEpochMillis)
    }

    @Test
    fun addingKeepsTheExistingNotifications() {
        val list = NotificationsHelper.add(listOf(note("n1")), "n2", "boom", null, 100)
        assertEquals(listOf("n1", "n2"), list.map { it.id })
    }

    @Test
    fun dismissingRemovesOnlyTheNamedNotification() {
        val list = NotificationsHelper.dismiss(listOf(note("n1"), note("n2")), "n1")
        assertEquals(listOf("n2"), list.map { it.id })
    }

    @Test
    fun dismissingAnUnknownIdChangesNothing() {
        val list = listOf(note("n1"))
        assertEquals(list, NotificationsHelper.dismiss(list, "ghost"))
    }

    @Test
    fun dismissAllEmptiesTheList() {
        assertTrue(NotificationsHelper.dismissAll().isEmpty())
    }

    @Test
    fun aNotificationIsNotDueBeforeTheAutoDismissWindow() {
        val list = listOf(note("n1", createdAt = 1_000))
        assertTrue(NotificationsHelper.dueForDismissal(list, nowMillis = 5_999).isEmpty())
    }

    @Test
    fun aNotificationIsDueAtTheAutoDismissWindow() {
        val list = listOf(note("n1", createdAt = 1_000))
        assertEquals(listOf("n1"), NotificationsHelper.dueForDismissal(list, nowMillis = 6_000))
    }

    @Test
    fun onlyExpiredNotificationsAreDue() {
        val list = listOf(note("old", createdAt = 0), note("fresh", createdAt = 9_000))
        assertEquals(listOf("old"), NotificationsHelper.dueForDismissal(list, nowMillis = 9_000))
    }
}
