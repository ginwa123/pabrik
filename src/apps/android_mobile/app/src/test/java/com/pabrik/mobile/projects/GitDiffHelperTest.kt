package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GitDiffHelperTest {

    @Test
    fun isAdded() {
        assertTrue(GitDiffHelper.isAdded("+hello"))
        assertFalse(GitDiffHelper.isAdded("+++ b/file"))
        assertFalse(GitDiffHelper.isAdded("-hello"))
    }

    @Test
    fun isDeleted() {
        assertTrue(GitDiffHelper.isDeleted("-hello"))
        assertFalse(GitDiffHelper.isDeleted("--- a/file"))
        assertFalse(GitDiffHelper.isDeleted("+hello"))
    }

    @Test
    fun isHunkHeader() {
        assertTrue(GitDiffHelper.isHunkHeader("@@ -1,3 +1,4 @@"))
        assertFalse(GitDiffHelper.isHunkHeader("+hello"))
    }

    @Test
    fun countChanges() {
        val diff = """
            @@ -1,2 +1,3 @@
            -old line
            +new line
            +another new
            context
        """.trimIndent()
        val (added, deleted) = GitDiffHelper.countChanges(diff)
        assertEquals(2, added)
        assertEquals(1, deleted)
    }

    @Test
    fun countChangesEmpty() {
        val (added, deleted) = GitDiffHelper.countChanges("")
        assertEquals(0, added)
        assertEquals(0, deleted)
    }
}
