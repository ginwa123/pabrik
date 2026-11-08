package com.pabrik.mobile.git

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PullRequestHelperTest {

    @Test
    fun onlyTheOpenStateIsOpen() {
        assertTrue(PullRequestHelper.isOpen("open"))
        assertFalse(PullRequestHelper.isOpen("closed"))
        assertFalse(PullRequestHelper.isOpen("merged"))
    }

    @Test
    fun statesAreLabelled() {
        assertEquals("Open", PullRequestHelper.stateLabel("open"))
        assertEquals("Closed", PullRequestHelper.stateLabel("closed"))
        assertEquals("Merged", PullRequestHelper.stateLabel("merged"))
        assertEquals("Draft", PullRequestHelper.stateLabel("draft"))
    }

    @Test
    fun anUnknownStateIsLabelledUnknown() {
        assertEquals("Unknown", PullRequestHelper.stateLabel("weird"))
    }

    @Test
    fun aNumberIsPrefixedWithAHash() {
        assertEquals("#42", PullRequestHelper.numberLabel(42))
    }

    @Test
    fun anUnknownOpenCountRendersNoBadge() {
        assertEquals("", PullRequestHelper.openCountBadge(null))
    }

    @Test
    fun aKnownOpenCountRendersTheNumber() {
        assertEquals("3", PullRequestHelper.openCountBadge(3))
    }

    @Test
    fun aPlainBranchNameIsValid() {
        assertTrue(PullRequestHelper.isValidBranchName("feat/login"))
    }

    @Test
    fun anEmptyBranchNameIsInvalid() {
        assertFalse(PullRequestHelper.isValidBranchName("  "))
    }

    @Test
    fun aBranchNameWithSpacesIsInvalid() {
        assertFalse(PullRequestHelper.isValidBranchName("feat login"))
    }

    @Test
    fun aBranchNameWithADoubleDotIsInvalid() {
        assertFalse(PullRequestHelper.isValidBranchName("feat..login"))
    }

    @Test
    fun aBranchNameStartingWithADashIsInvalid() {
        assertFalse(PullRequestHelper.isValidBranchName("-feat"))
    }

    @Test
    fun aBranchNameWithATildeIsInvalid() {
        assertFalse(PullRequestHelper.isValidBranchName("feat~1"))
    }

    @Test
    fun aTitleIsDerivedFromTheBranchTail() {
        assertEquals("Fix login", PullRequestHelper.titleFromBranch("feat/fix-login"))
    }

    @Test
    fun underscoresBecomeSpacesInTheTitle() {
        assertEquals("Fix login", PullRequestHelper.titleFromBranch("fix_login"))
    }
}
