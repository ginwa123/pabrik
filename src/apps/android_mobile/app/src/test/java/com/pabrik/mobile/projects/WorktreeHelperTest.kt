package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorktreeHelperTest {

    @Test
    fun validBranchName() {
        assertTrue(WorktreeHelper.isValidBranchName("feature/foo"))
        assertTrue(WorktreeHelper.isValidBranchName("main"))
        assertFalse(WorktreeHelper.isValidBranchName(""))
        assertFalse(WorktreeHelper.isValidBranchName("has space"))
        assertFalse(WorktreeHelper.isValidBranchName("a..b"))
    }

    @Test
    fun formatPath() {
        assertEquals("/tmp/wt/feature-foo", WorktreeHelper.formatPath("/tmp/wt", "feature/foo"))
        assertEquals("/tmp/wt/main", WorktreeHelper.formatPath("/tmp/wt", "main"))
    }

    @Test
    fun isMainWorktree() {
        assertTrue(WorktreeHelper.isMainWorktree(null))
        assertTrue(WorktreeHelper.isMainWorktree(""))
        assertFalse(WorktreeHelper.isMainWorktree("feature/foo"))
    }
}
