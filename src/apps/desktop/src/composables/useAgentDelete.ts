/** useAgentDelete — optimistic-update + rollback for agent deletion. */
import { ref, type Ref } from 'vue'

import { deleteAgent as apiDeleteAgent, type AgentDeleteResponse } from '../api'

export function useAgentDelete<TAgent extends { name: string }>(
  agents: Ref<TAgent[]>,
  activeAgent: Ref<string | null>,
  onSuccess?: (message: string) => void,
  onError?: (message: string) => void,
) {
  const isDeleting = ref(false)

  const deleteAgent = async (name: string): Promise<AgentDeleteResponse> => {
    if (isDeleting.value) {
      // Prevent concurrent deletes from racing the rollback logic.
      return Promise.resolve({
        success: false,
        profile_name: name,
        error_message: 'Another delete is already in progress',
      })
    }

    // Snapshot for rollback.
    const previousAgents = agents.value.slice()
    const previousActive = activeAgent.value

    // Optimistic local update (preserves the user's exact snippet at PabrikConfigEditor.vue:290-295 from the original spec).
    isDeleting.value = true
    agents.value = agents.value.filter((a) => a.name !== name)
    if (activeAgent.value === name) {
      activeAgent.value = null
    }

    try {
      const result = await apiDeleteAgent(name)
      onSuccess?.(`Agent "${name}" deleted`)
      return result
    } catch (err) {
      // Rollback.
      agents.value = previousAgents
      activeAgent.value = previousActive
      onError?.(formatErrorMessage(name, err))
      throw err
    } finally {
      isDeleting.value = false
    }
  }

  return { deleteAgent, isDeleting }
}

function formatErrorMessage(name: string, err: unknown): string {
  if (!(err instanceof Error)) {
    return `Failed to delete agent "${name}"`
  }
  // 404 gets a friendlier message because it's a common case (agent already deleted in another tab, race with another user's delete).
  if (err.message.includes('HTTP 404')) {
    return `Agent "${name}" not found on server (it may have been already deleted)`
  }
  return `Failed to delete agent "${name}": ${err.message}`
}
