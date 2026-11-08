package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PullRequestHelperTest {

    @Test
    fun isOpen() {
        assertTrue(PullRequestHelper.isOpen("open"))
        assertTrue(PullRequestHelper.isOpen("OPEN"))
        assertFalse(PullRequestHelper.isOpen("closed"))
        assertFalse(PullRequestHelper.isOpen("merged"))
    }

    @Test
    fun isMerged() {
        assertTrue(PullRequestHelper.isMerged("merged"))
        assertFalse(PullRequestHelper.isMerged("open"))
    }

    @Test
    fun formatTitle() {
        assertEquals("#42 Fix bug", PullRequestHelper.formatTitle(42, "Fix bug"))
    }

    @Test
    fun isMergeable() {
        assertTrue(PullRequestHelper.isMergeable("open", false))
        assertFalse(PullRequestHelper.isMergeable("open", true))
        assertFalse(PullRequestHelper.isMergeable("closed", false))
    }
}
