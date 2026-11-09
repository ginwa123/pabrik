import { computed, ref, type Ref } from 'vue'
import * as api from '../../../api'

export interface ChatComposerAgentsDeps {
  sessionId: Ref<string>
  workspaceId: () => string
  applyChatViewMode: (config: { chat_view?: string | null } | null) => void
}

export function useChatComposerAgents(deps: ChatComposerAgentsDeps) {
  const availableAgents = ref<
    Array<{ name: string; model: string; base_url: string; url_style: string }>
  >([])
  // Every profile the config names, disabled ones included: the backend's
  // `getAgent` does not filter `enabled`, so a disabled profile still resolves.
  const configuredAgentNames = ref<string[]>([])
  const configLoaded = ref(false)
  const selectedAgent = ref<string | null>(null)
  // User-chosen default agent from Settings → Agents → "Set active". `null` when no agent
  // is marked active (or no agents configured).
  const activeAgent = ref<string | null>(null)
  const showAgentPicker = ref(false)
  const isUpdatingAgent = ref(false)
  const agentPickerRef = ref<HTMLElement | null>(null)

  /** The workspace this chat runs in: the route's, else the app's; the Terminal tab shells there. */
  const chatWorkspaceId = computed<string>(() => deps.workspaceId())

  /** The workspace whose agents the picker must list: the merged overlay is what actually runs. */
  const agentPickerWorkspaceId = chatWorkspaceId

  const loadAgents = async () => {
    try {
      const wsId = agentPickerWorkspaceId.value
      const config = wsId ? await api.getWorkspaceConfig(wsId) : await api.getPabrikConfig()
      const agents = (config.profiles ?? {}) as Record<
        string,
        { model?: string; base_url?: string; url_style?: string; enabled?: boolean }
      >
      availableAgents.value = Object.entries(agents)
        .filter(([, p]) => p.enabled !== false)
        .map(([name, p]) => ({
          name,
          model: p.model ?? '',
          base_url: p.base_url ?? '',
          url_style: p.url_style ?? '',
        }))
      configuredAgentNames.value = Object.keys(agents)
      configLoaded.value = true
      // `active_profile` is the user-chosen default from Settings. Empty
      // string → null (matches the backend's PUT coercion in
      // `pabrik_config_put.zig`).
      const raw = (config as { active_profile?: string | null }).active_profile
      activeAgent.value = raw && raw.length > 0 ? raw : null
      // How the chat draws tool calls. The config this chat already fetched
      // is the effective one (the workspace overlay merged over the user
      // config), so the mode is the one that runs here.
      deps.applyChatViewMode(config)
    } catch (err) {
      console.error('Failed to load agents:', err)
      availableAgents.value = []
      activeAgent.value = null
    }
  }

  // Mirrors `Config.zig::resolveEffectiveAgent`: a name only counts when it
  // names a configured profile. A workspace with no profiles cannot contradict
  // a name, so the name stands — the backend falls back to top-level there too.
  const namesConfiguredAgent = (name: string | null): name is string => {
    if (!name) return false
    const known = configuredAgentNames.value
    if (!configLoaded.value || known.length === 0) return true
    return known.includes(name)
  }

  const effectiveAgent = computed<string | null>(() => {
    const sel = selectedAgent.value
    if (namesConfiguredAgent(sel)) return sel
    const act = activeAgent.value
    if (namesConfiguredAgent(act)) return act
    return null
  })

  /// The wire style the effective profile uses — it decides which file types the model can read.
  /// Empty when the profile is unknown; the backend then has the final say.
  const effectiveProfileUrlStyle = computed<string | undefined>(() => {
    const name = effectiveAgent.value
    if (!name) return undefined
    const style = availableAgents.value.find((p) => p.name === name)?.url_style
    return style && style.length > 0 ? style : undefined
  })

  const agentChipTooltip = computed(() => {
    const name = effectiveAgent.value
    if (!name) return 'Using default (top-level config)'
    if (name === selectedAgent.value) return `Using agent: ${name}`
    return `Using active agent: ${name}`
  })

  const selectAgent = async (name: string | null) => {
    if (isUpdatingAgent.value) return
    isUpdatingAgent.value = true
    try {
      const sid = deps.sessionId.value
      if (sid) {
        await api.updateSession(sid, { selectedAgent: name })
      }
      selectedAgent.value = name
    } catch (err) {
      console.error('Failed to update agent:', err)
    } finally {
      isUpdatingAgent.value = false
      showAgentPicker.value = false
    }
  }

  const closeOnOutsideClick = (e: MouseEvent) => {
    if (agentPickerRef.value && !agentPickerRef.value.contains(e.target as Node)) {
      showAgentPicker.value = false
    }
  }

  return {
    availableAgents,
    selectedAgent,
    activeAgent,
    showAgentPicker,
    isUpdatingAgent,
    agentPickerRef,
    chatWorkspaceId,
    loadAgents,
    effectiveAgent,
    namesConfiguredAgent,
    effectiveProfileUrlStyle,
    agentChipTooltip,
    selectAgent,
    closeOnOutsideClick,
  }
}
