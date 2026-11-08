package com.pabrik.mobile.workspace

data class McpHeader(val key: String, val value: String)

data class McpServer(
    val name: String,
    val transport: String,
    val url: String = "",
    val command: String = "",
    val args: List<String> = emptyList(),
    val env: List<String> = emptyList(),
    val cwd: String = "",
    val headers: List<McpHeader> = emptyList(),
    val enabled: Boolean = true,
)

data class RawMcpEntry(
    val url: String? = null,
    val command: String? = null,
    val args: List<String>? = null,
    val env: List<String>? = null,
    val cwd: String? = null,
    val headers: Map<String, String>? = null,
    val enabled: Boolean? = null,
)

object McpServersHelper {

    fun parseServers(raw: Map<String, RawMcpEntry>?): List<McpServer> {
        if (raw == null) return emptyList()
        val out = mutableListOf<McpServer>()
        for ((name, entry) in raw) {
            val command = entry.command
            val url = entry.url
            when {
                !command.isNullOrEmpty() -> out.add(
                    McpServer(
                        name = name,
                        transport = "stdio",
                        command = command,
                        args = entry.args ?: emptyList(),
                        env = entry.env ?: emptyList(),
                        cwd = entry.cwd ?: "",
                        enabled = entry.enabled ?: true,
                    ),
                )
                !url.isNullOrEmpty() -> out.add(
                    McpServer(
                        name = name,
                        transport = "http",
                        url = url,
                        headers = entry.headers?.map { McpHeader(it.key, it.value) } ?: emptyList(),
                        enabled = entry.enabled ?: true,
                    ),
                )
            }
        }
        return out.sortedBy { it.name }
    }

    fun serializeServers(list: List<McpServer>): Map<String, RawMcpEntry> {
        val out = mutableMapOf<String, RawMcpEntry>()
        for (server in list) {
            if (server.name.isEmpty()) continue
            if (server.transport == "stdio") {
                if (server.command.isEmpty()) continue
                out[server.name] = RawMcpEntry(
                    command = server.command,
                    args = server.args.ifEmpty { null },
                    env = server.env.ifEmpty { null },
                    cwd = server.cwd.ifEmpty { null },
                    enabled = if (server.enabled) null else false,
                )
            } else {
                if (server.url.isEmpty()) continue
                val headers = server.headers.filter { it.key.isNotEmpty() }.associate { it.key to it.value }
                out[server.name] = RawMcpEntry(
                    url = server.url,
                    headers = headers.ifEmpty { null },
                    enabled = if (server.enabled) null else false,
                )
            }
        }
        return out
    }

    fun isValidHeaderKey(key: String): Boolean {
        val k = key.trim()
        return k.isNotEmpty() && k.none { it == ' ' || it == ':' || it == '\t' }
    }

    fun duplicateHeaderKeys(headers: List<McpHeader>): List<String> =
        headers.map { it.key.trim() }
            .filter { it.isNotEmpty() }
            .groupingBy { it }
            .eachCount()
            .filterValues { it > 1 }
            .keys
            .sorted()

    fun isValidUrl(url: String): Boolean {
        val u = url.trim()
        return u.startsWith("http://") || u.startsWith("https://")
    }
}
