// Pure helper for the AgentView Tools panel toggle.
export interface ToggleCallbacks {
  enableAgentTool: (agentId: string, toolName: string) => Promise<unknown>
  disableAgentTool: (agentId: string, toolName: string) => Promise<unknown>
  refetchAgentTools: (agentId: string) => Promise<string[]>
}

export interface ToggleResult {
  /** The new local list to show in the UI immediately (optimistic). */
  nextLocal: string[]
  /** Resolves to the canonical server list (post-mutation). On
   * failure, resolves to `{ error }` and the caller reverts `nextLocal`.
   * Never throws. */
  serverPromise: Promise<{ canonical: string[] } | { error: unknown }>
}

export function buildToggle(
  currentLocal: string[],
  toolName: string,
  enabled: boolean,
  agentId: string,
  cbs: ToggleCallbacks,
): ToggleResult {
  const nextLocal = enabled
    ? [...new Set([...currentLocal, toolName])]
    : currentLocal.filter((n) => n !== toolName)

  const serverPromise = (async () => {
    try {
      if (enabled) {
        await cbs.enableAgentTool(agentId, toolName)
      } else {
        await cbs.disableAgentTool(agentId, toolName)
      }
      const canonical = await cbs.refetchAgentTools(agentId)
      return { canonical }
    } catch (error) {
      return { error }
    }
  })()

  return { nextLocal, serverPromise }
}