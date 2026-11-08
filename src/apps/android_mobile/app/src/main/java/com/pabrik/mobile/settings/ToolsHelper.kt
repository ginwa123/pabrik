package com.pabrik.mobile.settings

data class ToolEntry(
    val name: String,
    val description: String,
    val kind: String = "builtin",
)

object ToolsHelper {

    fun isEnabled(enabled: List<String>, name: String): Boolean = enabled.contains(name)

    fun toggle(enabled: List<String>, name: String): List<String> =
        if (enabled.contains(name)) enabled.filter { it != name } else enabled + name

    fun filter(tools: List<ToolEntry>, query: String): List<ToolEntry> {
        val q = query.trim()
        if (q.isEmpty()) return tools
        return tools.filter {
            it.name.contains(q, ignoreCase = true) || it.description.contains(q, ignoreCase = true)
        }
    }

    fun groupByKind(tools: List<ToolEntry>): Map<String, List<ToolEntry>> = tools.groupBy { it.kind }
}
