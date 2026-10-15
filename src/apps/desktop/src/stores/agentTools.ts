// Pinia store for the Agent Mode tool registry. Holds the canonical tool list (fetched once from
// `/api/agent-tools/registry` and cached for the session). The Tools panel in AgentView reads
// `registry` to render checkboxes.
// Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 14) Spec:
// docs/superpowers/specs/2026-08-15-agent-mode-design.md (D9)
import { defineStore } from 'pinia'
import { ref } from 'vue'
import * as api from '../api'

export interface AgentRegistryEntry {
  name: string
  description: string
  /** The tool's full parameter list. The panel does not render it yet; it is
   * declared so the wire shape lives in one place, and so a future path/file
   * affordance (or a `cwd`-required badge) has the data it needs. */
  parameters?: Array<{ name: string; type: string; required: boolean }>
}

export const useAgentToolsStore = defineStore('agentTools', () => {
  const registry = ref<AgentRegistryEntry[]>([])
  const error = ref<string | null>(null)
  const loading = ref(false)
  let fetched = false

  async function fetchRegistry(force = false): Promise<void> {
    if (fetched && !force) return
    loading.value = true
    error.value = null
    try {
      const data = await api.getAgentToolsRegistry()
      registry.value = data.tools
      fetched = true
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  /** Helper: is a tool_name present in the agent's enabled list? */
  function isToolEnabled(enabledList: string[], name: string): boolean {
    return enabledList.includes(name)
  }

  return { registry, error, loading, fetchRegistry, isToolEnabled }
})
