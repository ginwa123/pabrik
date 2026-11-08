package com.pabrik.mobile.settings

data class VerdictCount(val verdict: String, val n: Int)

data class EvalSummary(val total: Int, val byVerdict: Map<String, Int>)

object SkillEvalsHelper {

    fun isPassing(verdict: String): Boolean = verdict == "keep"

    fun isDestructive(verdict: String): Boolean = verdict == "delete"

    fun severity(verdict: String): Int = when (verdict) {
        "keep" -> 0
        "update", "rewrite" -> 1
        "delete" -> 2
        else -> 3
    }

    fun applyAction(verdict: String): String = if (verdict == "delete") "delete" else "edit"

    fun summarize(counts: List<VerdictCount>): EvalSummary =
        EvalSummary(
            total = counts.sumOf { it.n },
            byVerdict = counts.associate { it.verdict to it.n },
        )
}
