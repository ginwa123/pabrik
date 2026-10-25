export interface SubAgentArgs {
  /**    * Required. The name of the pre-configured sub-agent from LlmConfig.sub_agents. Also used as the
   * sub-agent's label in the result XML. */
  agent_name: string
  instruction: string
  /**    * Required since 2026-09-12 (mirrors the backend parse rule in `spawn_sub_agent.zig`): explicit
   * non-empty allowlist, never "all". Entries missing/empty/"all" tools are filtered out so the UI
   * never renders cards for a spawn the backend will reject. */
  tools: string[]
  timeout_seconds?: number
  inherited_context?: string
}

type OpaqueCall = Record<string, unknown>

const callFunction = (call: OpaqueCall): Record<string, unknown> | null => {
  const fn = call['function']
  return typeof fn === 'object' && fn !== null ? (fn as Record<string, unknown>) : null
}

const isSpawnCall = (call: OpaqueCall): boolean =>
  callFunction(call)?.['name'] === 'spawn_sub_agent'

/** null when the call's arguments cannot be read; an empty array when it was read but every
 * sub-agent is invalid. The two are different contracts (see
 * `returns an empty array when a sub-agent is missing the required agent_name`). */
function subAgentArgsFromCall(call: OpaqueCall): SubAgentArgs[] | null {
  const rawArgs = callFunction(call)?.['arguments']
  if (rawArgs == null) return null

  let args: unknown
  if (typeof rawArgs === 'string') {
    try {
      args = JSON.parse(rawArgs)
    } catch {
      return null
    }
  } else if (typeof rawArgs === 'object') {
    args = rawArgs
  } else {
    return null
  }

  if (typeof args !== 'object' || args === null) return null
  const subAgents = (args as Record<string, unknown>)['sub_agents']
  if (!Array.isArray(subAgents)) return null

  return subAgents.map(toSubAgentArgs).filter((sa): sa is SubAgentArgs => sa !== null)
}

// Defensive copy: only include known fields, don't trust the LLM's shape.
function toSubAgentArgs(sa: unknown): SubAgentArgs | null {
  if (typeof sa !== 'object' || sa === null) return null
  const record = sa as Record<string, unknown>
  const agentName = record['agent_name']
  const instruction = record['instruction']
  const tools = record['tools']
  if (typeof agentName !== 'string' || agentName.length === 0) return null
  if (typeof instruction !== 'string') return null
  if (!Array.isArray(tools) || tools.length === 0) return null
  if (!tools.every((tool) => typeof tool === 'string' && tool.length > 0)) return null
  const toolNames = tools.filter((tool): tool is string => typeof tool === 'string')
  if (toolNames.some((tool) => tool.trim() === 'all')) return null

  const result: SubAgentArgs = { agent_name: agentName, instruction, tools: toolNames }
  const timeoutSeconds = record['timeout_seconds']
  if (typeof timeoutSeconds === 'number') result.timeout_seconds = timeoutSeconds
  const inheritedContext = record['inherited_context']
  if (typeof inheritedContext === 'string') result.inherited_context = inheritedContext
  return result
}

function parseToolCalls(toolCallsJson: string | null | undefined): OpaqueCall[] | null {
  if (!toolCallsJson) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(toolCallsJson)
  } catch {
    return null
  }
  return Array.isArray(parsed) ? (parsed as OpaqueCall[]) : null
}

/** Extract the sub_agents array from an assistant message's tool_calls_json, matched by
 * tool_call_id. */
export function parseSpawnSubAgentArgs(
  toolCallsJson: string | null | undefined,
  toolCallId: string | null | undefined,
): SubAgentArgs[] | null {
  if (!toolCallId) return null
  const parsed = parseToolCalls(toolCallsJson)
  if (parsed === null) return null

  const match = parsed.find((tc) => isSpawnCall(tc) && tc['id'] === toolCallId)
  if (!match) return null
  return subAgentArgsFromCall(match)
}

/** Every spawn call of ONE assistant message's tool_calls_json, keyed by tool_call_id. Reads the
 * payload once, so a transcript costs one parse per message instead of one per (call, message)
 * pair. */
export function indexSpawnSubAgentArgs(
  toolCallsJson: string | null | undefined,
): Map<string, SubAgentArgs[]> {
  const index = new Map<string, SubAgentArgs[]>()
  const parsed = parseToolCalls(toolCallsJson)
  if (parsed === null) return index

  for (const call of parsed) {
    if (!isSpawnCall(call)) continue
    const id = call['id']
    if (typeof id !== 'string' || id.length === 0) continue
    const args = subAgentArgsFromCall(call)
    if (args !== null) index.set(id, args)
  }
  return index
}
