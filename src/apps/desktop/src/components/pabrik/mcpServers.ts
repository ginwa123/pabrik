import type { McpServer } from '../../api'

/** Raw wire shape of a single MCP server entry as it appears in config.json's `mcp_servers` map. */
export type RawMcpServerEntry =
  | { url: string; headers?: Record<string, string>; enabled?: boolean }
  | { command: string; args?: string[]; env?: string[]; cwd?: string; enabled?: boolean }

export function parseMcpServers(
  raw: Record<string, RawMcpServerEntry> | undefined,
): McpServer[] {
  if (!raw) return []
  const out: McpServer[] = []
  for (const [name, server] of Object.entries(raw)) {
    if (!server) continue
    // Transport discriminator: presence of `command` ⇒ stdio,
    // presence of `url` ⇒ http. Legacy entries (url-only) hydrate as
    // http. Entries with neither are silently dropped.
    if ('command' in server && typeof server.command === 'string' && server.command.length > 0) {
      out.push({
        name,
        transport: 'stdio',
        command: server.command,
        args: Array.isArray(server.args) ? server.args.map((a: string) => a) : [],
        env: Array.isArray(server.env) ? server.env.map((e: string) => e) : [],
        cwd: typeof server.cwd === 'string' ? server.cwd : '',
        url: '',
        headers: [],
        ...(typeof server.enabled === 'boolean' ? { enabled: server.enabled } : {}),
      })
    } else if ('url' in server && typeof server.url === 'string' && server.url.length > 0) {
      const headers = server.headers
        ? Object.entries(server.headers).map(([key, value]) => ({ key, value: String(value ?? '') }))
        : []
      out.push({
        name,
        transport: 'http',
        url: server.url,
        headers,
        command: '',
        args: [],
        env: [],
        cwd: '',
        ...(typeof server.enabled === 'boolean' ? { enabled: server.enabled } : {}),
      })
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name))
  return out
}

export function serializeMcpServers(
  list: McpServer[],
): Record<string, RawMcpServerEntry> | undefined {
  if (list.length === 0) return undefined
  const out: Record<string, RawMcpServerEntry> = {}
  for (const server of list) {
    if (!server.name) continue
    if (server.transport === 'stdio') {
      if (!server.command) continue
      const entry: RawMcpServerEntry = { command: server.command }
      if (server.args && server.args.length) entry.args = server.args
      if (server.env && server.env.length) entry.env = server.env
      if (server.cwd && server.cwd.length) entry.cwd = server.cwd
      if (server.enabled === false) (entry as { enabled?: boolean }).enabled = false
      out[server.name] = entry
    } else {
      // Default to http for legacy entries that lack an explicit
      // transport field.
      const url = server.url ?? ''
      if (!url) continue
      const headers: Record<string, string> = {}
      for (const h of (server.headers ?? [])) if (h.key) headers[h.key] = h.value
      out[server.name] = {
        url,
        ...(Object.keys(headers).length ? { headers } : {}),
        ...(server.enabled === false ? { enabled: false as const } : {}),
      }
    }
  }
  return Object.keys(out).length ? out : undefined
}
