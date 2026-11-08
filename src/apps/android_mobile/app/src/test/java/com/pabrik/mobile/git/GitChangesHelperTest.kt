package com.pabrik.mobile.git

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitChangesHelperTest {

    @Test
    fun modifiedStatusIsLabelled() {
        assertEquals("Modified", GitChangesHelper.statusText("M"))
    }

    @Test
    fun addedStatusIsLabelled() {
        assertEquals("Added", GitChangesHelper.statusText("A"))
    }

    @Test
    fun deletedStatusIsLabelled() {
        assertEquals("Deleted", GitChangesHelper.statusText("D"))
    }

    @Test
    fun renamedStatusIsLabelled() {
        assertEquals("Renamed", GitChangesHelper.statusText("R"))
    }

    @Test
    fun copiedStatusIsLabelled() {
        assertEquals("Copied", GitChangesHelper.statusText("C"))
    }

    @Test
    fun untrackedStatusIsLabelled() {
        assertEquals("Untracked", GitChangesHelper.statusText("??"))
    }

    @Test
    fun anUnknownStatusFallsBackToChanged() {
        assertEquals("Changed", GitChangesHelper.statusText("X"))
    }

    @Test
    fun aDoubleQuestionMarkIsUntracked() {
        assertTrue(GitChangesHelper.isUntracked("??"))
    }

    @Test
    fun aBlankIndexStatusIsNotStaged() {
        assertFalse(GitChangesHelper.isStaged(" "))
    }

    @Test
    fun anUntrackedFileIsNotStaged() {
        assertFalse(GitChangesHelper.isStaged("??"))
    }

    @Test
    fun aModifiedIndexStatusIsStaged() {
        assertTrue(GitChangesHelper.isStaged("M"))
    }

    @Test
    fun anUntrackedFileDisplaysAsUntracked() {
        assertEquals("Untracked", GitChangesHelper.displayStatus("??", " "))
    }

    @Test
    fun aStagedChangeWinsOverTheWorktreeStatus() {
        assertEquals("Added", GitChangesHelper.displayStatus("A", "M"))
    }

    @Test
    fun anUnstagedChangeUsesTheWorktreeStatus() {
        assertEquals("Modified", GitChangesHelper.displayStatus(" ", "M"))
    }

    @Test
    fun aFileWithNoStatusDisplaysAsChanged() {
        assertEquals("Changed", GitChangesHelper.displayStatus(" ", " "))
    }

    @Test
    fun aMissingBranchIsLabelled() {
        assertEquals("no branch", GitChangesHelper.branchLabel(null))
        assertEquals("no branch", GitChangesHelper.branchLabel("  "))
    }

    @Test
    fun aPresentBranchIsShownAsIs() {
        assertEquals("main", GitChangesHelper.branchLabel("main"))
    }

    @Test
    fun totalChangesCountsEveryGroup() {
        val staged = listOf(GitFileChange("M", " ", "a"))
        val modified = listOf(GitFileChange(" ", "M", "b"), GitFileChange(" ", "M", "c"))
        val untracked = listOf(GitFileChange("??", " ", "d"))
        assertEquals(4, GitChangesHelper.totalChanges(staged, modified, untracked))
    }
}
