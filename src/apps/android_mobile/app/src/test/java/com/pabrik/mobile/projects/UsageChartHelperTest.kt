package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Test

class UsageChartHelperTest {

    @Test
    fun formatBytesBytes() {
        assertEquals("512 B", UsageChartHelper.formatBytes(512))
    }

    @Test
    fun formatBytesKb() {
        assertEquals("1.0 KB", UsageChartHelper.formatBytes(1024))
    }

    @Test
    fun formatBytesMb() {
        assertEquals("1.0 MB", UsageChartHelper.formatBytes(1024 * 1024))
    }

    @Test
    fun formatPercent() {
        assertEquals("50.0%", UsageChartHelper.formatPercent(50.0, 100.0))
    }

    @Test
    fun formatPercentZeroTotal() {
        assertEquals("0%", UsageChartHelper.formatPercent(5.0, 0.0))
    }

    @Test
    fun formatPercentClamped() {
        assertEquals("100.0%", UsageChartHelper.formatPercent(200.0, 100.0))
    }
}
