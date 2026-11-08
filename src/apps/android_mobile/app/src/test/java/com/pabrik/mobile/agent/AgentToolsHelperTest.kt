package com.pabrik.mobile.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentToolsHelperTest {

    @Test
    fun aListedToolIsEnabled() {
        assertTrue(AgentToolsHelper.isToolEnabled(listOf("read"), "read"))
    }

    @Test
    fun anUnlistedToolIsDisabled() {
        assertFalse(AgentToolsHelper.isToolEnabled(listOf("read"), "write"))
    }

    @Test
    fun enablingAddsTheTool() {
        assertEquals(listOf("read", "write"), AgentToolsHelper.nextLocal(listOf("read"), "write", enabled = true))
    }

    @Test
    fun enablingAnAlreadyEnabledToolDoesNotDuplicateIt() {
        assertEquals(listOf("read"), AgentToolsHelper.nextLocal(listOf("read"), "read", enabled = true))
    }

    @Test
    fun disablingRemovesTheTool() {
        assertEquals(listOf("write"), AgentToolsHelper.nextLocal(listOf("read", "write"), "read", enabled = false))
    }

    @Test
    fun disablingAnAbsentToolChangesNothing() {
        assertEquals(listOf("read"), AgentToolsHelper.nextLocal(listOf("read"), "ghost", enabled = false))
    }

    @Test
    fun enabledCountIgnoresDuplicates() {
        assertEquals(2, AgentToolsHelper.enabledCount(listOf("a", "b", "a")))
    }

    @Test
    fun emptyQueryReturnsTheWholeRegistry() {
        val registry = listOf(AgentToolEntry("read", "Read a file"))
        assertEquals(registry, AgentToolsHelper.filter(registry, ""))
    }

    @Test
    fun queryMatchesTheName() {
        val registry = listOf(AgentToolEntry("read", "Read a file"), AgentToolEntry("write", "Write a file"))
        assertEquals(listOf("read"), AgentToolsHelper.filter(registry, "rea").map { it.name })
    }

    @Test
    fun queryMatchesTheDescription() {
        val registry = listOf(AgentToolEntry("read", "Read a file"), AgentToolEntry("write", "Write a file"))
        assertEquals(listOf("write"), AgentToolsHelper.filter(registry, "write a").map { it.name })
    }

    @Test
    fun theRegistryGroupsByKind() {
        val registry = listOf(
            AgentToolEntry("read", "", kind = "builtin"),
            AgentToolEntry("mcp_search", "", kind = "mcp"),
        )
        val grouped = AgentToolsHelper.groupByKind(registry)
        assertEquals(listOf("read"), grouped.getValue("builtin").map { it.name })
        assertEquals(listOf("mcp_search"), grouped.getValue("mcp").map { it.name })
    }
}
