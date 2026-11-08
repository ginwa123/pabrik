package com.pabrik.mobile.settings

import java.util.Locale

data class UsageRow(
    val calls: Long,
    val inputTokens: Long,
    val cacheReadTokens: Long,
    val reportedInputTokens: Long,
)

data class UsageTotals(
    val calls: Long,
    val inputTokens: Long,
    val cacheReadTokens: Long,
    val reportedInputTokens: Long,
)

object UsageAggregator {
    val RANGES = listOf("1d", "7d", "30d", "90d")

    fun isValidRange(range: String): Boolean = range in RANGES

    fun cacheHitRate(cacheReadTokens: Long, reportedInputTokens: Long): Double? =
        if (reportedInputTokens <= 0) null else cacheReadTokens.toDouble() / reportedInputTokens * 100.0

    fun sumTotals(rows: List<UsageRow>): UsageTotals =
        UsageTotals(
            calls = rows.sumOf { it.calls },
            inputTokens = rows.sumOf { it.inputTokens },
            cacheReadTokens = rows.sumOf { it.cacheReadTokens },
            reportedInputTokens = rows.sumOf { it.reportedInputTokens },
        )

    fun formatTokens(tokens: Long): String = when {
        tokens >= 1_000_000 -> String.format(Locale.ROOT, "%.1fM", tokens / 1_000_000.0)
        tokens >= 1_000 -> String.format(Locale.ROOT, "%.1fK", tokens / 1_000.0)
        else -> tokens.toString()
    }

    fun formatCostCents(cents: Long): String = String.format(Locale.ROOT, "\$%.2f", cents / 100.0)
}
