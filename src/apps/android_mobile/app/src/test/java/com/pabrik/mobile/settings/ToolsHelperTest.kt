package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolsHelperTest {

    @Test
    fun aListedToolIsEnabled() {
        assertTrue(ToolsHelper.isEnabled(listOf("read", "write"), "read"))
    }

    @Test
    fun anUnlistedToolIsDisabled() {
        assertFalse(ToolsHelper.isEnabled(listOf("read"), "write"))
    }

    @Test
    fun togglingADisabledToolEnablesIt() {
        assertEquals(listOf("read", "write"), ToolsHelper.toggle(listOf("read"), "write"))
    }

    @Test
    fun togglingAnEnabledToolDisablesIt() {
        assertEquals(listOf("write"), ToolsHelper.toggle(listOf("read", "write"), "read"))
    }

    @Test
    fun togglingTwiceRestoresTheOriginalList() {
        val original = listOf("read")
        assertEquals(original, ToolsHelper.toggle(ToolsHelper.toggle(original, "write"), "write"))
    }

    @Test
    fun emptyQueryReturnsEveryTool() {
        val tools = listOf(ToolEntry("read", "Read a file"), ToolEntry("write", "Write a file"))
        assertEquals(tools, ToolsHelper.filter(tools, ""))
    }

    @Test
    fun queryMatchesTheToolName() {
        val tools = listOf(ToolEntry("read", "Read a file"), ToolEntry("write", "Write a file"))
        assertEquals(listOf("read"), ToolsHelper.filter(tools, "rea").map { it.name })
    }

    @Test
    fun queryMatchesTheDescription() {
        val tools = listOf(ToolEntry("read", "Read a file"), ToolEntry("write", "Write a file"))
        assertEquals(listOf("write"), ToolsHelper.filter(tools, "write a").map { it.name })
    }

    @Test
    fun toolsAreGroupedByKind() {
        val tools = listOf(
            ToolEntry("read", "", kind = "builtin"),
            ToolEntry("mcp_search", "", kind = "mcp"),
            ToolEntry("write", "", kind = "builtin"),
        )
        val grouped = ToolsHelper.groupByKind(tools)
        assertEquals(listOf("read", "write"), grouped.getValue("builtin").map { it.name })
        assertEquals(listOf("mcp_search"), grouped.getValue("mcp").map { it.name })
    }
}
