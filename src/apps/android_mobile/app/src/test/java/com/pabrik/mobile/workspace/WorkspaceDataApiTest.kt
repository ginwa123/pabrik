package com.pabrik.mobile.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceDataApiTest {

    @Test
    fun parseSecretsReadsTheRealWireShape() {
        val body = """
            {"secrets":[
              {"id":"sec_1","name":"DEMO_API_KEY","description":"Example credential",
               "created_at":"2026-11-17 16:46:15","updated_at":"2026-11-17 16:46:15"}
            ],"count":1}
        """.trimIndent()

        val secrets = WorkspaceDataApi.parseSecrets(body)

        assertEquals(1, secrets.size)
        assertEquals("sec_1", secrets[0].id)
        assertEquals("DEMO_API_KEY", secrets[0].name)
        assertEquals("Example credential", secrets[0].description)
    }

    @Test
    fun parseSecretsSkipsRowsWithoutAnId() {
        val body = """{"secrets":[{"id":"","name":"Ghost"},{"id":"sec_2","name":"Real"}]}"""

        assertEquals(listOf("sec_2"), WorkspaceDataApi.parseSecrets(body).map { it.id })
    }

    @Test
    fun parseMembersReadsRoleAndEmail() {
        val body = """
            {"members":[
              {"workspace_id":"ws_1","user_id":"user_system","email":"system@local",
               "name":"System","role":"owner","joined_at":"2026-11-17 16:45:56","invited_by":""}
            ],"count":1}
        """.trimIndent()

        val members = WorkspaceDataApi.parseMembers(body)

        assertEquals(1, members.size)
        assertEquals("user_system", members[0].userId)
        assertEquals("system@local", members[0].email)
        assertEquals("owner", members[0].role)
    }

    @Test
    fun parseSkillsReadsAutoImproveFlag() {
        val body = """{"skills":[{"name":"mobile-demo-skill","description":"A sample skill","is_can_auto_improve":true}]}"""

        val skills = WorkspaceDataApi.parseSkills(body)

        assertEquals(1, skills.size)
        assertEquals("mobile-demo-skill", skills[0].name)
        assertTrue(skills[0].isCanAutoImprove)
    }

    @Test
    fun parseMemoriesReadsTags() {
        val body = """
            {"memories":[
              {"id":"mem_1","content":"Web and mobile show the same memories",
               "tags":["parity","demo"],"created_at":"2026-11-17 16:46:27","updated_at":"2026-11-17 16:46:27"}
            ],"total_count":1}
        """.trimIndent()

        val memories = WorkspaceDataApi.parseMemories(body)

        assertEquals(1, memories.size)
        assertEquals("Web and mobile show the same memories", memories[0].content)
        assertEquals(listOf("parity", "demo"), memories[0].tags)
    }

    @Test
    fun parseUsageReadsTotalsAndKeepsNullCacheRate() {
        val body = """
            {"totals":{"calls":12,"sessions":3,"input_tokens":1000,"output_tokens":500,
             "tool_calls":4,"cache_hit_rate":null},"daily":[],"models":[],"tools":[]}
        """.trimIndent()

        val usage = WorkspaceDataApi.parseUsage(body)

        assertEquals(12, usage.totals.calls)
        assertEquals(3, usage.totals.sessions)
        assertEquals(1000L, usage.totals.inputTokens)
        assertEquals(500L, usage.totals.outputTokens)
        assertEquals(4, usage.totals.toolCalls)
        assertNull(usage.totals.cacheHitRate)
    }

    @Test
    fun parseUsageReadsDailyBuckets() {
        val body = """
            {"totals":{},"daily":[
              {"date":"2026-11-17","calls":5,"input_tokens":100,"output_tokens":50}
            ],"models":[],"tools":[]}
        """.trimIndent()

        val usage = WorkspaceDataApi.parseUsage(body)

        assertEquals(1, usage.daily.size)
        assertEquals("2026-11-17", usage.daily[0].label)
        assertEquals(5, usage.daily[0].calls)
        assertEquals(150L, usage.daily[0].tokens)
    }

    @Test
    fun parseConfigReadsProfilesAndMcpServers() {
        val body = """
            {"profiles":[{"name":"demo-profile","base_url":"https://api.example.com/v1",
             "model":"demo-model","api_key":"demo-key"}],"active_profile":"demo-profile",
             "mcp_servers":[{"name":"demo-mcp","url":"http://localhost:9000/mcp","headers":[]}],
             "chat_view":"dev","notify_on_complete":false,"notify_on_error":true}
        """.trimIndent()

        val config = WorkspaceDataApi.parseConfig(body)

        assertEquals(1, config.profiles.size)
        assertEquals("demo-profile", config.profiles[0].name)
        assertTrue(config.profiles[0].hasApiKey)
        assertEquals("demo-profile", config.activeProfile)
        assertEquals(1, config.mcpServers.size)
        assertEquals("demo-mcp", config.mcpServers[0].name)
        assertTrue(config.notifyOnError)
        assertFalse(config.notifyOnComplete)
    }

    @Test
    fun parseConfigDoesNotExposeTheApiKeyValue() {
        val body = """{"profiles":[{"name":"p","api_key":"super-secret-value"}],"mcp_servers":[]}"""

        val config = WorkspaceDataApi.parseConfig(body)

        assertTrue(config.profiles[0].hasApiKey)
        assertFalse(config.toString().contains("super-secret-value"))
    }

    @Test
    fun parseDocumentsReadsItems() {
        val body = """
            {"items":[
              {"id":"item_1","item_type":"design","name":"Parity Design","path":"/tmp/design",
               "created_at":"2026-11-17 16:49:34","updated_at":"2026-11-17 16:49:34"}
            ]}
        """.trimIndent()

        val documents = WorkspaceDataApi.parseDocuments(body)

        assertEquals(1, documents.size)
        assertEquals("item_1", documents[0].id)
        assertEquals("design", documents[0].itemType)
        assertEquals("Parity Design", documents[0].name)
    }

    @Test
    fun parsersReturnEmptyOnMissingArrays() {
        assertTrue(WorkspaceDataApi.parseSecrets("{}").isEmpty())
        assertTrue(WorkspaceDataApi.parseMembers("{}").isEmpty())
        assertTrue(WorkspaceDataApi.parseSkills("{}").isEmpty())
        assertTrue(WorkspaceDataApi.parseMemories("{}").isEmpty())
        assertTrue(WorkspaceDataApi.parseDocuments("{}").isEmpty())
    }
}
