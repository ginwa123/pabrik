package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolsHelperTest {

    @Test
    fun validName() {
        assertTrue(ToolsHelper.isValidName("my-tool"))
        assertFalse(ToolsHelper.isValidName(""))
        assertFalse(ToolsHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(ToolsHelper.isDuplicate("tool", listOf("TOOL", "other")))
        assertFalse(ToolsHelper.isDuplicate("new", listOf("TOOL", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, ToolsHelper.validateNew("NEW_TOOL", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", ToolsHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", ToolsHelper.validateNew("tool", listOf("TOOL")))
    }
}
