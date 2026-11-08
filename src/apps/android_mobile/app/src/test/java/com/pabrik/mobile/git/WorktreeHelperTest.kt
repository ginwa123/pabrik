package com.pabrik.mobile.git

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorktreeHelperTest {

    @Test
    fun aBasenameIsAppendedToTheParent() {
        assertEquals("/home/me/wt/auth", WorktreeHelper.fullPath("/home/me/wt", "auth"))
    }

    @Test
    fun aTrailingSlashOnTheParentIsNotDoubled() {
        assertEquals("/home/me/wt/auth", WorktreeHelper.fullPath("/home/me/wt/", "auth"))
    }

    @Test
    fun theRootParentKeepsASingleSlash() {
        assertEquals("/auth", WorktreeHelper.fullPath("/", "auth"))
    }

    @Test
    fun anEmptyBasenameLeavesATrailingSlash() {
        assertEquals("/home/me/wt/", WorktreeHelper.fullPath("/home/me/wt", "  "))
    }

    @Test
    fun aPlainBasenameIsValid() {
        assertTrue(WorktreeHelper.isValidBasename("auth-fix_2"))
    }

    @Test
    fun aBasenameWithASlashIsInvalid() {
        assertFalse(WorktreeHelper.isValidBasename("a/b"))
    }

    @Test
    fun anEmptyBasenameIsInvalid() {
        assertFalse(WorktreeHelper.isValidBasename("   "))
    }

    @Test
    fun submitIsAllowedWithABasenameAndParent() {
        assertTrue(WorktreeHelper.canSubmit("auth", "/home/me", submitting = false))
    }

    @Test
    fun submitIsBlockedWhileSubmitting() {
        assertFalse(WorktreeHelper.canSubmit("auth", "/home/me", submitting = true))
    }

    @Test
    fun submitIsBlockedWithoutABasename() {
        assertFalse(WorktreeHelper.canSubmit("  ", "/home/me", submitting = false))
    }

    @Test
    fun submitIsBlockedWithoutAParent() {
        assertFalse(WorktreeHelper.canSubmit("auth", "  ", submitting = false))
    }

    @Test
    fun theBranchNameIsDerivedFromTheBasename() {
        assertEquals("worktree/auth", WorktreeHelper.branchName("auth"))
    }
}
