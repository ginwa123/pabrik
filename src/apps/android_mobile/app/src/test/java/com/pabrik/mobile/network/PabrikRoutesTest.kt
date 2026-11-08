package com.pabrik.mobile.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PabrikRoutesTest {

    @Test
    fun theSettingsRouteIsStatic() {
        assertEquals("settings", PabrikRoutes.settings())
    }

    @Test
    fun theNotificationsRouteIsStatic() {
        assertEquals("notifications", PabrikRoutes.notifications())
    }

    @Test
    fun workspaceSettingsCarriesTheWorkspaceId() {
        assertEquals("workspace/ws1/settings", PabrikRoutes.workspaceSettings("ws1"))
    }

    @Test
    fun kanbanSettingsCarriesBothIds() {
        assertEquals("kanban/ws1/item1/settings", PabrikRoutes.kanbanSettings("ws1", "item1"))
    }

    @Test
    fun documentsCarriesTheWorkspaceId() {
        assertEquals("documents/ws1", PabrikRoutes.documents("ws1"))
    }

    @Test
    fun aDocumentCarriesBothIds() {
        assertEquals("documents/ws1/doc1", PabrikRoutes.document("ws1", "doc1"))
    }

    @Test
    fun agentCarriesBothIds() {
        assertEquals("agent/ws1/item1", PabrikRoutes.agent("ws1", "item1"))
    }

    @Test
    fun designCarriesBothIds() {
        assertEquals("design/ws1/item1", PabrikRoutes.design("ws1", "item1"))
    }

    @Test
    fun routineCarriesBothIds() {
        assertEquals("routine/ws1/item1", PabrikRoutes.routine("ws1", "item1"))
    }

    @Test
    fun gitCarriesBothIds() {
        assertEquals("git/ws1/item1", PabrikRoutes.git("ws1", "item1"))
    }

    @Test
    fun memoryCarriesTheWorkspaceId() {
        assertEquals("memory/ws1", PabrikRoutes.memory("ws1"))
    }

    @Test
    fun secretsCarriesTheWorkspaceId() {
        assertEquals("secrets/ws1", PabrikRoutes.secrets("ws1"))
    }

    @Test
    fun membersCarriesTheWorkspaceId() {
        assertEquals("members/ws1", PabrikRoutes.members("ws1"))
    }

    @Test
    fun skillsCarriesTheWorkspaceId() {
        assertEquals("skills/ws1", PabrikRoutes.skills("ws1"))
    }

    @Test
    fun mcpCarriesTheWorkspaceId() {
        assertEquals("mcp/ws1", PabrikRoutes.mcp("ws1"))
    }

    @Test
    fun llmConfigCarriesTheWorkspaceId() {
        assertEquals("llm-config/ws1", PabrikRoutes.llmConfig("ws1"))
    }

    @Test
    fun toolsCarriesTheWorkspaceId() {
        assertEquals("tools/ws1", PabrikRoutes.tools("ws1"))
    }

    @Test
    fun idsAreUrlEncoded() {
        assertEquals("workspace/a%2Fb/settings", PabrikRoutes.workspaceSettings("a/b"))
    }

    @Test
    fun everyRoutePatternIsUnique() {
        val patterns = listOf(
            PabrikRoutes.SHELL,
            PabrikRoutes.CHAT,
            PabrikRoutes.NETWORK,
            PabrikRoutes.RECORD_DETAIL,
            PabrikRoutes.PROJECT,
            PabrikRoutes.CHATS,
            PabrikRoutes.SETTINGS,
            PabrikRoutes.WORKSPACE_SETTINGS,
            PabrikRoutes.KANBAN_SETTINGS,
            PabrikRoutes.DOCUMENTS,
            PabrikRoutes.DOCUMENT,
            PabrikRoutes.AGENT,
            PabrikRoutes.DESIGN,
            PabrikRoutes.ROUTINE,
            PabrikRoutes.GIT,
            PabrikRoutes.MEMORY,
            PabrikRoutes.SECRETS,
            PabrikRoutes.MEMBERS,
            PabrikRoutes.SKILLS,
            PabrikRoutes.MCP,
            PabrikRoutes.LLM_CONFIG,
            PabrikRoutes.TOOLS,
            PabrikRoutes.NOTIFICATIONS,
        )
        assertEquals(patterns.size, patterns.distinct().size)
    }

    @Test
    fun everyBuiltPathStartsWithItsPatternPrefix() {
        assertTrue(PabrikRoutes.workspaceSettings("ws1").startsWith("workspace/"))
        assertTrue(PabrikRoutes.documents("ws1").startsWith("documents/"))
        assertTrue(PabrikRoutes.agent("ws1", "i1").startsWith("agent/"))
        assertTrue(PabrikRoutes.git("ws1", "i1").startsWith("git/"))
    }
}
