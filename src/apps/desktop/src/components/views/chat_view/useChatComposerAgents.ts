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
  // Every profile the config names, disabled ones included: a reply is still credited to its author after that agent is switched off.
  const configuredAgentNames = ref<string[]>([])
  // Only a switched-on profile can be the effective agent — the backend's cascade refuses a disabled one.
  const enabledAgentNames = ref<string[]>([])
  const configLoaded = ref(false)
  const selectedAgent = ref<string | null>(null)
  // User-chosen default agent from Settings → Agents → "Set active".
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
      enabledAgentNames.value = availableAgents.value.map((a) => a.name)
      configLoaded.value = true
      // `active_profile` is the user-chosen default from Settings.
      const raw = (config as { active_profile?: string | null }).active_profile
      activeAgent.value = raw && raw.length > 0 ? raw : null
      // How the chat draws tool calls.
      deps.applyChatViewMode(config)
    } catch (err) {
      console.error('Failed to load agents:', err)
      availableAgents.value = []
      activeAgent.value = null
    }
  }

  // Mirrors `Config.zig::getAgent`: the transcript's vocabulary is every name the config still holds.
  const namesConfiguredAgent = (name: string | null): name is string => {
    if (!name) return false
    const known = configuredAgentNames.value
    if (!configLoaded.value || known.length === 0) return true
    return known.includes(name)
  }

  // Mirrors `Config.zig::resolveEffectiveAgent`: a name only wins a cascade slot when that profile is switched ON.
  const resolvesToAgent = (name: string | null): name is string => {
    if (!name) return false
    if (!configLoaded.value) return true
    return enabledAgentNames.value.includes(name)
  }

  /**
   * The session's pinned agent when that agent is switched off: the chat cannot answer until the user enables it or picks another one.
   */
  const blockedAgent = computed<string | null>(() => {
    const sel = selectedAgent.value
    if (!sel || !configLoaded.value) return null
    if (!configuredAgentNames.value.includes(sel)) return null
    return enabledAgentNames.value.includes(sel) ? null : sel
  })

  const effectiveAgent = computed<string | null>(() => {
    // A chat pinned to a switched-off agent has nothing answering it — the same refusal the turn runner makes, so the chip never promises another agent.
    if (blockedAgent.value) return null
    const sel = selectedAgent.value
    if (resolvesToAgent(sel)) return sel
    const act = activeAgent.value
    if (resolvesToAgent(act)) return act
    return null
  })

  /// The wire style the effective profile uses — it decides which file types the model can read.
  const effectiveProfileUrlStyle = computed<string | undefined>(() => {
    const name = effectiveAgent.value
    if (!name) return undefined
    const style = availableAgents.value.find((p) => p.name === name)?.url_style
    return style && style.length > 0 ? style : undefined
  })

  const agentChipTooltip = computed(() => {
    const blocked = blockedAgent.value
    if (blocked) return `${blocked} is switched off — enable it in Settings → Agents, or pick another agent`
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
    blockedAgent,
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
