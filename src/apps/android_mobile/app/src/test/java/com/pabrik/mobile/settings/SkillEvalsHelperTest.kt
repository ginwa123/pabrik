package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillEvalsHelperTest {

    @Test
    fun keepIsTheOnlyPassingVerdict() {
        assertTrue(SkillEvalsHelper.isPassing("keep"))
        assertFalse(SkillEvalsHelper.isPassing("update"))
        assertFalse(SkillEvalsHelper.isPassing("delete"))
    }

    @Test
    fun deleteIsTheOnlyDestructiveVerdict() {
        assertTrue(SkillEvalsHelper.isDestructive("delete"))
        assertFalse(SkillEvalsHelper.isDestructive("rewrite"))
    }

    @Test
    fun severityOrdersKeepBelowUpdateBelowDelete() {
        assertTrue(SkillEvalsHelper.severity("keep") < SkillEvalsHelper.severity("update"))
        assertTrue(SkillEvalsHelper.severity("update") < SkillEvalsHelper.severity("delete"))
    }

    @Test
    fun rewriteSharesTheUpdateSeverity() {
        assertEquals(SkillEvalsHelper.severity("update"), SkillEvalsHelper.severity("rewrite"))
    }

    @Test
    fun anUnknownVerdictIsTheMostSevere() {
        assertTrue(SkillEvalsHelper.severity("mystery") > SkillEvalsHelper.severity("delete"))
    }

    @Test
    fun deleteVerdictAppliesAsDelete() {
        assertEquals("delete", SkillEvalsHelper.applyAction("delete"))
    }

    @Test
    fun everyOtherVerdictAppliesAsEdit() {
        assertEquals("edit", SkillEvalsHelper.applyAction("keep"))
        assertEquals("edit", SkillEvalsHelper.applyAction("update"))
        assertEquals("edit", SkillEvalsHelper.applyAction("rewrite"))
    }

    @Test
    fun summaryTotalsEveryCount() {
        val summary = SkillEvalsHelper.summarize(
            listOf(VerdictCount("keep", 3), VerdictCount("delete", 2)),
        )
        assertEquals(5, summary.total)
    }

    @Test
    fun summaryKeepsTheCountPerVerdict() {
        val summary = SkillEvalsHelper.summarize(
            listOf(VerdictCount("keep", 3), VerdictCount("delete", 2)),
        )
        assertEquals(3, summary.byVerdict.getValue("keep"))
        assertEquals(2, summary.byVerdict.getValue("delete"))
    }

    @Test
    fun emptySummaryHasZeroTotal() {
        assertEquals(0, SkillEvalsHelper.summarize(emptyList()).total)
    }
}
