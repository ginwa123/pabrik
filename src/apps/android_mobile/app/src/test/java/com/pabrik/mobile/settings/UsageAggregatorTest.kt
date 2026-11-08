package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UsageAggregatorTest {

    @Test
    fun theFourKnownRangesAreValid() {
        assertTrue(UsageAggregator.isValidRange("1d"))
        assertTrue(UsageAggregator.isValidRange("7d"))
        assertTrue(UsageAggregator.isValidRange("30d"))
        assertTrue(UsageAggregator.isValidRange("90d"))
    }

    @Test
    fun anUnknownRangeIsInvalid() {
        assertFalse(UsageAggregator.isValidRange("365d"))
    }

    @Test
    fun cacheHitRateIsNullWhenNothingWasReported() {
        assertNull(UsageAggregator.cacheHitRate(0, 0))
    }

    @Test
    fun cacheHitRateIsTheShareOfReportedInput() {
        assertEquals(50.0, UsageAggregator.cacheHitRate(500, 1_000)!!, 0.0001)
    }

    @Test
    fun cacheHitRateCanBeFull() {
        assertEquals(100.0, UsageAggregator.cacheHitRate(1_000, 1_000)!!, 0.0001)
    }

    @Test
    fun totalsSumEveryRow() {
        val totals = UsageAggregator.sumTotals(
            listOf(
                UsageRow(calls = 2, inputTokens = 100, cacheReadTokens = 10, reportedInputTokens = 100),
                UsageRow(calls = 3, inputTokens = 200, cacheReadTokens = 20, reportedInputTokens = 200),
            ),
        )
        assertEquals(5, totals.calls)
        assertEquals(300, totals.inputTokens)
        assertEquals(30, totals.cacheReadTokens)
        assertEquals(300, totals.reportedInputTokens)
    }

    @Test
    fun emptyTotalsAreZero() {
        assertEquals(0, UsageAggregator.sumTotals(emptyList()).calls)
    }

    @Test
    fun smallTokenCountsArePrintedAsIs() {
        assertEquals("999", UsageAggregator.formatTokens(999))
    }

    @Test
    fun thousandsArePrintedWithAKSuffix() {
        assertEquals("1.5K", UsageAggregator.formatTokens(1_500))
    }

    @Test
    fun millionsArePrintedWithAnMSuffix() {
        assertEquals("2.0M", UsageAggregator.formatTokens(2_000_000))
    }

    @Test
    fun costIsPrintedWithTwoDecimals() {
        assertEquals("$1.50", UsageAggregator.formatCostCents(150))
    }
}
