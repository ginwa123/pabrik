package com.pabrik.mobile.sync

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class UtcTimeTest {

    private val utc: ZoneId = ZoneId.of("UTC")
    private val jakarta: ZoneId = ZoneId.of("Asia/Jakarta")
    private val berlin: ZoneId = ZoneId.of("Europe/Berlin")

    private fun epoch(iso: String): Long = Instant.parse(iso).toEpochMilli()

    @Test
    fun zeroEpochRendersAsEmptyString() {
        assertEquals("", UtcTime.format(0, utc))
    }

    @Test
    fun negativeEpochRendersAsEmptyString() {
        assertEquals("", UtcTime.format(-1, utc))
    }

    @Test
    fun utcInstantRendersInTheRequestedZone() {
        assertEquals("2026-01-01 07:00", UtcTime.format(epoch("2026-01-01T00:00:00Z"), jakarta))
    }

    @Test
    fun utcInstantRendersInUtcWhenUtcIsRequested() {
        assertEquals("2026-01-01 00:00", UtcTime.format(epoch("2026-01-01T00:00:00Z"), utc))
    }

    @Test
    fun localWallClockConvertsToUtcEpoch() {
        val local = LocalDateTime.of(2026, 1, 1, 7, 0)
        assertEquals(epoch("2026-01-01T00:00:00Z"), UtcTime.toUtcMillis(local, jakarta))
    }

    @Test
    fun utcWallClockConvertsToItself() {
        val local = LocalDateTime.of(2026, 1, 1, 0, 0)
        assertEquals(epoch("2026-01-01T00:00:00Z"), UtcTime.toUtcMillis(local, utc))
    }

    @Test
    fun summerTimeOffsetIsAppliedForBerlin() {
        val local = LocalDateTime.of(2026, 7, 1, 12, 0)
        assertEquals(epoch("2026-07-01T10:00:00Z"), UtcTime.toUtcMillis(local, berlin))
    }

    @Test
    fun winterTimeOffsetIsAppliedForBerlin() {
        val local = LocalDateTime.of(2026, 1, 1, 12, 0)
        assertEquals(epoch("2026-01-01T11:00:00Z"), UtcTime.toUtcMillis(local, berlin))
    }

    @Test
    fun utcEpochRendersBackToTheLocalWallClock() {
        val local = LocalDateTime.of(2026, 1, 1, 7, 0)
        assertEquals(local, UtcTime.toLocalDateTime(UtcTime.toUtcMillis(local, jakarta), jakarta))
    }

    @Test
    fun convertingLocalToUtcAndBackPreservesTheInstant() {
        val instant = epoch("2026-03-15T08:30:00Z")
        val local = UtcTime.toLocalDateTime(instant, jakarta)
        assertEquals(instant, UtcTime.toUtcMillis(local, jakarta))
    }
}
