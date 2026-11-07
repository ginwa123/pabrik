package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitCommitsHelperTest {

    @Test
    fun shortSha() {
        assertEquals("abc1234", GitCommitsHelper.shortSha("abc1234567890"))
        assertEquals("abc", GitCommitsHelper.shortSha("abc"))
    }

    @Test
    fun firstLine() {
        assertEquals("feat: add thing", GitCommitsHelper.firstLine("feat: add thing\n\nbody here"))
        assertEquals("single line", GitCommitsHelper.firstLine("single line"))
    }

    @Test
    fun firstLineEmpty() {
        assertEquals("", GitCommitsHelper.firstLine(""))
        assertEquals("", GitCommitsHelper.firstLine("   "))
    }

    @Test
    fun isEmptyMessage() {
        assertTrue(GitCommitsHelper.isEmptyMessage(""))
        assertTrue(GitCommitsHelper.isEmptyMessage("   "))
        assertFalse(GitCommitsHelper.isEmptyMessage("hello"))
    }
}
