package com.pabrik.mobile.projects

// Usage chart helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object UsageChartHelper {

    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format("%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format("%.1f MB", mb)
        val gb = mb / 1024.0
        return String.format("%.2f GB", gb)
    }

    fun formatPercent(value: Double, total: Double): String {
        if (total <= 0) return "0%"
        val pct = (value / total * 100).coerceIn(0.0, 100.0)
        return String.format("%.1f%%", pct)
    }
}
