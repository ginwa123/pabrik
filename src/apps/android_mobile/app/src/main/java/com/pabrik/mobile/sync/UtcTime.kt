package com.pabrik.mobile.sync

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

object UtcTime {
    private val displayFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    fun format(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        if (epochMillis <= 0) {
            ""
        } else {
            displayFormatter.withZone(zone).format(Instant.ofEpochMilli(epochMillis))
        }

    fun toUtcMillis(localDateTime: LocalDateTime, zone: ZoneId): Long =
        localDateTime.atZone(zone).toInstant().toEpochMilli()

    fun toLocalDateTime(epochMillis: Long, zone: ZoneId): LocalDateTime =
        Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDateTime()
}
