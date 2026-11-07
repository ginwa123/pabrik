package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitChangesHelperTest {

    @Test
    fun statusLabel() {
        assertEquals("Modified", GitChangesHelper.statusLabel("M"))
        assertEquals("Added", GitChangesHelper.statusLabel("A"))
        assertEquals("Deleted", GitChangesHelper.statusLabel("D"))
        assertEquals("Untracked", GitChangesHelper.statusLabel("??"))
        assertEquals("Unknown", GitChangesHelper.statusLabel("X"))
    }

    @Test
    fun isModified() {
        assertTrue(GitChangesHelper.isModified("M"))
        assertFalse(GitChangesHelper.isModified("A"))
        assertFalse(GitChangesHelper.isModified("??"))
    }

    @Test
    fun countByStatus() {
        val codes = listOf("M", "M", "A", "??")
        val counts = GitChangesHelper.countByStatus(codes)
        assertEquals(2, counts["Modified"])
        assertEquals(1, counts["Added"])
        assertEquals(1, counts["Untracked"])
    }

    @Test
    fun countByStatusEmpty() {
        assertTrue(GitChangesHelper.countByStatus(emptyList()).isEmpty())
    }
}
