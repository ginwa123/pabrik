package com.pabrik.mobile.workspace

import org.json.JSONObject

data class SecretEntry(
    val id: String,
    val name: String,
    val description: String,
    val createdAt: String,
    val updatedAt: String,
)

data class MemberEntry(
    val workspaceId: String,
    val userId: String,
    val email: String,
    val name: String,
    val role: String,
    val joinedAt: String,
    val invitedBy: String,
)

data class SkillEntry(
    val name: String,
    val description: String,
    val isCanAutoImprove: Boolean,
)

data class MemoryEntry(
    val id: String,
    val content: String,
    val tags: List<String>,
    val createdAt: String,
    val updatedAt: String,
)

data class UsageTotals(
    val calls: Int,
    val sessions: Int,
    val inputTokens: Long,
    val outputTokens: Long,
    val toolCalls: Int,
    val cacheHitRate: Double?,
)

data class UsageBucket(
    val label: String,
    val calls: Int,
    val tokens: Long,
)

data class UsageData(
    val totals: UsageTotals,
    val daily: List<UsageBucket>,
    val models: List<UsageBucket>,
    val tools: List<UsageBucket>,
)

data class ProfileEntry(
    val name: String,
    val baseUrl: String,
    val model: String,
    val hasApiKey: Boolean,
)

data class McpServerEntry(
    val name: String,
    val url: String,
    val headerCount: Int,
)

data class ConfigData(
    val profiles: List<ProfileEntry>,
    val activeProfile: String,
    val mcpServers: List<McpServerEntry>,
    val chatView: String,
    val notifyOnComplete: Boolean,
    val notifyOnError: Boolean,
)

data class DocumentEntry(
    val id: String,
    val name: String,
    val itemType: String,
    val path: String,
    val createdAt: String,
    val updatedAt: String,
)

object WorkspaceDataApi {
    fun secretsPath(workspaceId: String): String = "/api/workspaces/$workspaceId/secrets"

    fun membersPath(workspaceId: String): String = "/api/workspaces/$workspaceId/members"

    fun skillsPath(workspaceId: String): String = "/api/workspaces/$workspaceId/skills"

    fun memoriesPath(workspaceId: String): String = "/api/workspaces/$workspaceId/memories"

    fun usagePath(workspaceId: String): String = "/api/workspaces/$workspaceId/usage"

    fun configPath(workspaceId: String): String = "/api/workspaces/$workspaceId/config"

    fun itemsPath(workspaceId: String): String = "/api/workspaces/$workspaceId/items"

    fun parseSecrets(body: String): List<SecretEntry> {
        val rows = JSONObject(body).optJSONArray("secrets") ?: return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.wireString("id")
                if (id.isEmpty()) continue
                add(
                    SecretEntry(
                        id = id,
                        name = row.wireString("name"),
                        description = row.wireString("description"),
                        createdAt = row.wireString("created_at"),
                        updatedAt = row.wireString("updated_at"),
                    ),
                )
            }
        }
    }

    fun parseMembers(body: String): List<MemberEntry> {
        val rows = JSONObject(body).optJSONArray("members") ?: return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val userId = row.wireString("user_id")
                if (userId.isEmpty()) continue
                add(
                    MemberEntry(
                        workspaceId = row.wireString("workspace_id"),
                        userId = userId,
                        email = row.wireString("email"),
                        name = row.wireString("name"),
                        role = row.wireString("role"),
                        joinedAt = row.wireString("joined_at"),
                        invitedBy = row.wireString("invited_by"),
                    ),
                )
            }
        }
    }

    fun parseSkills(body: String): List<SkillEntry> {
        val rows = JSONObject(body).optJSONArray("skills") ?: return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val name = row.wireString("name")
                if (name.isEmpty()) continue
                add(
                    SkillEntry(
                        name = name,
                        description = row.wireString("description"),
                        isCanAutoImprove = row.optBoolean("is_can_auto_improve", false),
                    ),
                )
            }
        }
    }

    fun parseMemories(body: String): List<MemoryEntry> {
        val rows = JSONObject(body).optJSONArray("memories") ?: return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.wireString("id")
                if (id.isEmpty()) continue
                val tags = buildList {
                    val values = row.optJSONArray("tags") ?: return@buildList
                    for (tagIndex in 0 until values.length()) {
                        val tag = values.optString(tagIndex).trim()
                        if (tag.isNotEmpty()) add(tag)
                    }
                }
                add(
                    MemoryEntry(
                        id = id,
                        content = row.wireString("content"),
                        tags = tags,
                        createdAt = row.wireString("created_at"),
                        updatedAt = row.wireString("updated_at"),
                    ),
                )
            }
        }
    }

    fun parseUsage(body: String): UsageData {
        val root = JSONObject(body)
        val totalsJson = root.optJSONObject("totals") ?: JSONObject()
        val totals = UsageTotals(
            calls = totalsJson.optInt("calls", 0),
            sessions = totalsJson.optInt("sessions", 0),
            inputTokens = totalsJson.optLong("input_tokens", 0L),
            outputTokens = totalsJson.optLong("output_tokens", 0L),
            toolCalls = totalsJson.optInt("tool_calls", 0),
            cacheHitRate = if (totalsJson.isNull("cache_hit_rate")) {
                null
            } else {
                totalsJson.optDouble("cache_hit_rate", 0.0)
            },
        )
        return UsageData(
            totals = totals,
            daily = parseUsageBuckets(root.optJSONArray("daily"), "date"),
            models = parseUsageBuckets(root.optJSONArray("models"), "model"),
            tools = parseUsageBuckets(root.optJSONArray("tools"), "tool"),
        )
    }

    fun parseConfig(body: String): ConfigData {
        val root = JSONObject(body)
        val profiles = buildList {
            val rows = root.optJSONArray("profiles") ?: return@buildList
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val name = row.wireString("name")
                if (name.isEmpty()) continue
                add(
                    ProfileEntry(
                        name = name,
                        baseUrl = row.wireString("base_url"),
                        model = row.wireString("model"),
                        hasApiKey = row.wireString("api_key").isNotEmpty(),
                    ),
                )
            }
        }
        val mcpServers = buildList {
            val rows = root.optJSONArray("mcp_servers") ?: return@buildList
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val name = row.wireString("name")
                if (name.isEmpty()) continue
                add(
                    McpServerEntry(
                        name = name,
                        url = row.wireString("url"),
                        headerCount = row.optJSONArray("headers")?.length() ?: 0,
                    ),
                )
            }
        }
        return ConfigData(
            profiles = profiles,
            activeProfile = root.wireString("active_profile"),
            mcpServers = mcpServers,
            chatView = root.wireString("chat_view"),
            notifyOnComplete = root.optBoolean("notify_on_complete", false),
            notifyOnError = root.optBoolean("notify_on_error", false),
        )
    }

    fun parseDocuments(body: String): List<DocumentEntry> {
        val rows = JSONObject(body).optJSONArray("items") ?: return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.wireString("id")
                if (id.isEmpty()) continue
                add(
                    DocumentEntry(
                        id = id,
                        name = row.wireString("name"),
                        itemType = row.wireString("item_type"),
                        path = row.wireString("path"),
                        createdAt = row.wireString("created_at"),
                        updatedAt = row.wireString("updated_at"),
                    ),
                )
            }
        }
    }

    private fun parseUsageBuckets(
        rows: org.json.JSONArray?,
        labelKey: String,
    ): List<UsageBucket> {
        if (rows == null) return emptyList()
        return buildList(rows.length()) {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val label = row.wireString(labelKey)
                if (label.isEmpty()) continue
                add(
                    UsageBucket(
                        label = label,
                        calls = row.optInt("calls", 0),
                        tokens = row.optLong("input_tokens", 0L) + row.optLong("output_tokens", 0L),
                    ),
                )
            }
        }
    }
}

internal fun JSONObject.wireString(name: String): String =
    if (isNull(name)) "" else optString(name).trim()
