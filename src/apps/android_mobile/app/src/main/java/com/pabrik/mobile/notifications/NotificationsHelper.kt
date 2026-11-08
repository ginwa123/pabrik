package com.pabrik.mobile.notifications

data class NotificationItem(
    val id: String,
    val message: String,
    val details: String?,
    val createdAtEpochMillis: Long,
)

object NotificationsHelper {
    const val AUTO_DISMISS_MS = 5_000L

    fun add(
        current: List<NotificationItem>,
        id: String,
        message: String,
        details: String?,
        nowMillis: Long,
    ): List<NotificationItem> = current + NotificationItem(id, message, details, nowMillis)

    fun dismiss(current: List<NotificationItem>, id: String): List<NotificationItem> =
        current.filter { it.id != id }

    fun dismissAll(): List<NotificationItem> = emptyList()

    fun dueForDismissal(current: List<NotificationItem>, nowMillis: Long): List<String> =
        current.filter { nowMillis - it.createdAtEpochMillis >= AUTO_DISMISS_MS }.map { it.id }
}
