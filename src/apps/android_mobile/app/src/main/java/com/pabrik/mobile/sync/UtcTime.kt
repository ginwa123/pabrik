package com.pabrik.mobile.sync

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// Renders a UTC epoch-millis value in the device's local zone. Storage stays
// UTC; only display converts.
object UtcTime {
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
        .withZone(ZoneId.systemDefault())

    fun format(epochMillis: Long): String =
        if (epochMillis <= 0) "" else formatter.format(Instant.ofEpochMilli(epochMillis))

    fun toUtcMillis(localEpochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        localEpochMillis // placeholder: callers pass UTC millis already
}
