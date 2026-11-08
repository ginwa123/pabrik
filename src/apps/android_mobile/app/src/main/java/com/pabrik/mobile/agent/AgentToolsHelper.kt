package com.pabrik.mobile.agent

data class AgentToolEntry(
    val name: String,
    val description: String,
    val kind: String = "builtin",
)

object AgentToolsHelper {

    fun isToolEnabled(enabled: List<String>, name: String): Boolean = enabled.contains(name)

    fun nextLocal(current: List<String>, name: String, enabled: Boolean): List<String> =
        if (enabled) (current + name).distinct() else current.filter { it != name }

    fun enabledCount(enabled: List<String>): Int = enabled.distinct().size

    fun filter(registry: List<AgentToolEntry>, query: String): List<AgentToolEntry> {
        val q = query.trim()
        if (q.isEmpty()) return registry
        return registry.filter {
            it.name.contains(q, ignoreCase = true) || it.description.contains(q, ignoreCase = true)
        }
    }

    fun groupByKind(registry: List<AgentToolEntry>): Map<String, List<AgentToolEntry>> =
        registry.groupBy { it.kind }
}
