package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class McpHelperTest {

    @Test
    fun validName() {
        assertTrue(McpHelper.isValidName("my-mcp"))
        assertFalse(McpHelper.isValidName(""))
        assertFalse(McpHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(McpHelper.isDuplicate("mcp", listOf("MCP", "other")))
        assertFalse(McpHelper.isDuplicate("new", listOf("MCP", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, McpHelper.validateNew("NEW_MCP", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", McpHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", McpHelper.validateNew("mcp", listOf("MCP")))
    }
}
