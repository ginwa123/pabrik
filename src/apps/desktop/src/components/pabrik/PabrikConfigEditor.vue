<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import {
  getWebStatus,
  savePabrikConfig,
  type McpServer,
  type PabrikConfig,
  type PabrikAgent,
} from '../../api'
import { usePabrikConfig } from '../../composables/usePabrikConfig'
import { useRoute, useRouter } from 'vue-router'
import { useTabsStore } from '../../stores/tabs'
import { useChatViewStore } from '../../stores/chatView'

import PabrikSaveBar from './PabrikSaveBar.vue'
import PabrikGeneralSection, { type PabrikGeneralSettings } from './PabrikGeneralSection.vue'
import AgentsSection, { type AgentRow } from './AgentsSection.vue'
import McpServersSection from './McpServersSection.vue'
import WebSearchSection from './WebSearchSection.vue'
import ToolsSection from './ToolsSection.vue'
import SettingsSkeleton from './SettingsSkeleton.vue'
import SkillEvalsSection, { type SkillEvalsSettings } from './SkillEvalsSection.vue'
import { parseMcpServers, serializeMcpServers } from './mcpServers'
import {
  createWebSearchProviderRow,
  parseWebSearchProviders,
  serializeWebSearchProviders,
  validateWebSearchRows,
  webSearchRowErrorsFromMessage,
  type WebSearchProviderRow,
} from './webSearchProviders'
// The models.dev catalog: its status for the block below, and the manual
// refresh. Both live in the General tab because the catalog is machine-wide —
// it is not a per-workspace or per-agent fact.
import { getModelCatalog, refreshModelCatalog } from '../../api'
import AgentModal, { type AgentModalValue } from './AgentModal.vue'
import McpServerModal, { type McpServerModalValue } from './McpServerModal.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import UiIcon from '../ui/UiIcon.vue'
import { userConfigSource, type PabrikConfigSource } from '../../helpers/configSource'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

// ─── Scope ──────────────────────────────────────────────────────────────── Navigation lives in
// `SettingsShell` (flat sidebar items + `?section=`), so this component renders ONE section at a
// time and owns no tab strip. One editor, two scopes.
type Tab = 'general' | 'agents' | 'mcp' | 'tools' | 'evals'

const props = withDefaults(
  defineProps<{
    /** Where the config is read from and written to. */
    source?: PabrikConfigSource
    /**      * Which sections this editor offers. The settings shell renders the nav, so this is the
     * editor's ACCEPT list: a `?section=` outside it falls back to the first entry instead of
     * rendering an empty pane. */
    sections?: readonly Tab[]
  }>(),
  {
    source: undefined,
    // Inline, not a module constant: `defineProps` is hoisted above the
    // setup body, so its default factories may not reference a local
    // declaration. The type annotation is erased and therefore fine.
    sections: () => ['general', 'agents', 'mcp', 'tools', 'evals'] as Tab[],
  },
)

const source = props.source ?? userConfigSource()

// Expose saveSettings / resetSettings so the parent can trigger them
// (preserves the previous defineExpose surface).
defineExpose({
  saveSettings: () => handleSave(),
  resetSettings: () => handleReset(),
})

// ─── Tab state ──────────────────────────────────────────────────────────── Plan
// 2026-08-24-config-simplify-remove-defaults: 'defaults' tab removed.
const TAB_STORAGE_KEY = 'pabrik-settings-active-tab'

/**  * The section ids this editor accepts. Derived from the `sections` prop, so a URL or a stored value
 * pointing at a section this editor does not offer falls back instead of rendering nothing. */
const TAB_IDS = computed<readonly string[]>(() => props.sections)
// ─── Edit mode: the form, or the raw JSON ──────────────────────────────── Some edits are far
// easier to express as JSON - pasting a whole agent map from another machine, or reading the
// exact keys the backend will store - and a workspace's config IS a JSON document on the wire.
type EditorMode = 'form' | 'json'
const MODE_PARAM = 'mode'

const jsonText = ref('')
/** Has the textarea's content been folded into the in-memory config? */
const jsonApplied = ref(false)

/** What is wrong with the textarea, or null when it is applicable. Live, not on-submit: the Apply
 * button is disabled and the reason is on screen while the user types, so an invalid paste never
 * looks like it worked. */
const jsonProblem = computed<string | null>(() => {
  const text = jsonText.value.trim()
  if (text.length === 0) return 'Nothing to apply — the JSON is empty.'
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return e instanceof Error ? e.message : String(e)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return 'The config must be a JSON object.'
  }
  return null
})

// ─── Central config (usePabrikConfig composable) ──────────────────────────
const { config, loaded, dirty, unsavedCount, saving, setConfig, save, reset } =
  usePabrikConfig(source)

// ─── Tab mode ──────────────────────────────────────────────────────────── This one is an app
// preference, not part of the server config: the tab set is client-side state, so it is
// deliberately NOT a field in the config v-model.
const tabsStore = useTabsStore()
const router = useRouter()
const route = useRoute()

// ─── Active tab: URL (?section=) → localStorage → general ──────────────── D5 of plan
// 2026-09-22-tools-menu-config-default-tools: every tab switch lands in the URL so refresh /
// Back-Forward / shared links keep the open section.
function readStoredTab(): Tab | null {
  try {
    const saved = localStorage.getItem(TAB_STORAGE_KEY)
    return saved && TAB_IDS.value.includes(saved) ? (saved as Tab) : null
  } catch {
    return null // storage unavailable (private mode / no stub)
  }
}

// Falls back to the FIRST section this editor offers, not to `general`:
// an editor mounted with `sections: ['agents', ...]` has no General to show,
// and defaulting to it renders an empty pane.
const firstTab = computed<Tab>(() => props.sections[0] ?? 'general')
const activeTabLocal = ref<Tab>(readStoredTab() ?? props.sections[0] ?? 'general')

const activeTab = computed<Tab>({
  get() {
    if (route) {
      const raw = route.query.section
      const section = Array.isArray(raw) ? raw[0] : raw
      if (typeof section === 'string' && TAB_IDS.value.includes(section)) return section as Tab
      return readStoredTab() ?? firstTab.value
    }
    return activeTabLocal.value
  },
  set(next) {
    activeTabLocal.value = next
    try {
      localStorage.setItem(TAB_STORAGE_KEY, next)
    } catch {
      /* private mode */
    }
    if (!router || !route) return
    const rest = { ...route.query }
    // Default tab is stripped from the URL to keep it clean (mirrors
    // KanbanSettingsView). Other params (e.g. a browser `?tab=` ID)
    // are preserved untouched.
    if (next === 'general') delete rest.section
    else rest.section = next
    void router.replace({ query: rest })
  },
})

/**  * Turning tab mode off must leave no trace: the route funnel stops creating/normalising tabs, and
 * the now-meaningless `?tab=` is dropped from the URL. Guarded because this component also mounts
 * in tests without a router installed. */
function onToggleBrowserTabs(value: boolean) {
  tabsStore.setEnabled(value)
  if (value || !router || !route) return
  const query = { ...(route.query as Record<string, string>) }
  delete query.tab
  void router.replace({ path: route.path, query })
}

// ─── Mode: URL-backed, with a local fallback for router-less mounts ──────
const modeLocal = ref<EditorMode>('form')

const mode = computed<EditorMode>({
  get() {
    if (!route) return modeLocal.value
    const raw = route.query[MODE_PARAM]
    const value = Array.isArray(raw) ? raw[0] : raw
    return value === 'json' ? 'json' : 'form'
  },
  set(next) {
    modeLocal.value = next
    if (!router || !route) return
    const rest = { ...route.query }
    // The default mode is stripped, mirroring `?section=`.
    if (next === 'form') delete rest[MODE_PARAM]
    else rest[MODE_PARAM] = next
    void router.replace({ query: rest })
  },
})

/** Format the config in memory into the textarea. */
function seedJsonText() {
  jsonText.value = JSON.stringify(config.value ?? {}, null, 2)
  jsonApplied.value = false
}

/** Enter JSON mode: format whatever the config holds right now. */
function showJson() {
  seedJsonText()
  mode.value = 'json'
}

/** Leave JSON mode. Refuses to leave when the textarea holds text that has NOT been applied and
 * cannot be - leaving would silently discard an edit the user is mid-way through. */
function showForm() {
  if (mode.value === 'json' && jsonText.value.trim().length > 0 && !applyJson()) return
  mode.value = 'form'
}

function onJsonInput() {
  jsonApplied.value = false
}

/** Fold the textarea into the in-memory config, then re-hydrate the sections. Written straight to
 * `config` rather than through `setConfig`: `setConfig` re-snapshots, which would mark this edit as
 * already-saved and hide the save bar. */
function applyJson(): boolean {
  if (jsonProblem.value !== null) return false
  config.value = JSON.parse(jsonText.value) as PabrikConfig
  syncFromConfig()
  jsonApplied.value = true
  return true
}

onMounted(async () => {
  // Every view switch lands in the URL (?section=) so refresh / Back-Forward / shared links keep
  // the open tab.
  try {
    if (router && route) {
      const actual = activeTab.value
      activeTabLocal.value = actual
      try {
        localStorage.setItem(TAB_STORAGE_KEY, actual)
      } catch {
        /* private mode */
      }
      const raw = route.query.section
      const urlSection = Array.isArray(raw) ? raw[0] : raw
      const urlValid =
        typeof urlSection === 'string' && TAB_IDS.value.includes(urlSection)
          ? (urlSection as Tab)
          : undefined
      if (actual === 'general') {
        if (urlValid !== undefined || raw !== undefined) {
          const rest = { ...route.query }
          delete rest.section
          void router.replace({ query: rest }).catch(() => {})
        }
      } else if (urlValid !== actual) {
        void router.replace({ query: { ...route.query, section: actual } }).catch(() => {})
      }
    }
  } catch {
    /* router absent in tests */
  }
  // Plan 2026-08-24-config-simplify-remove-defaults: the legacy localStorage fallback (which
  // existed solely to seed the removed Defaults form) is gone. The API response is the only source.
  // Read through the SOURCE.
  await reload()
})

// ─── Per-section view state ──────────────────────────────────────────────
const agentsList = ref<AgentRow[]>([])
const activeAgent = ref<string | null>(null)
/**  * Has the agent list been edited this session? An emptied list must still be written through —
 * otherwise deleting the LAST agent would save the pre-delete map back and resurrect it. */
const agentsTouched = ref(false)
const mcpServersList = ref<McpServer[]>([])
// Web search providers (`web_search` in config.json). Edited as rows rather than as the raw map —
// see components/pabrik/webSearchProviders.ts.
const webSearchRows = ref<WebSearchProviderRow[]>([])
const webSearchErrors = ref<Record<string, string>>({})
// Default tool checklist (Tools tab). `null` = config.json has no
// `tools` key → the built-in defaults render and nothing is written
// back until the user changes a checkbox.
const toolsList = ref<string[] | null>(null)

// Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the General tab uses a single
// `defineModel<PabrikGeneralSettings>` v-model surface in PabrikGeneralSection.vue.
const generalSettings = ref<PabrikGeneralSettings>({
  notify_on_complete: false,
  notify_on_error: false,
  retry_delay_ms: 0,
  // Plan 2026-09-10-web-launch-toggle: browser-mode flag (4th key).
  web_launch_enabled: false,
  // How the chat draws tool calls (5th key).
  chat_view: 'dev',
})

// Skill Evals tab. Only `enabled` is editable in the UI; the budget
// knobs ride along untouched (see skillEvalsRaw below) so flipping the
// switch can never reset a hand-edited value in config.json.
const skillEvalsSettings = ref<SkillEvalsSettings>({ enabled: false })
/** The block exactly as the GET returned it. Replayed verbatim on save. */
const skillEvalsRaw = ref<PabrikConfig['skill_evals']>(undefined)
/** What `enabled` was at hydrate time, so we can tell "untouched" from
 * "the user flipped it" — see the guard in syncToConfig. */
const skillEvalsHydrated = ref(false)

function syncFromConfig() {
  if (!config.value) return
  const c = config.value
  agentsList.value = Object.entries(c.profiles ?? {}).map(([name, p]) => ({
    name,
    model: p.model ?? '',
    base_url: p.base_url ?? '',
    thinking: p.thinking ?? 'auto',
    temperature: p.temperature ?? 'auto',
    url_style: p.url_style ?? 'openai',
    api_key: p.api_key ?? '',
    system_prompt: p.system_prompt ?? '',
    // Transport + its Claude Code knobs. Absent `backend` reads as "http",
    // matching the backend's default so nothing migrates.
    backend: p.backend ?? 'http',
    config_dir: p.config_dir ?? null,
    max_turns: p.max_turns ?? null,
    // Compaction overrides — both top-level and per-agent coexist. Each layer cascades over the
    // next; the agent's own wins over the top-level.
    max_capacity_tokens: p.max_capacity_tokens ?? null,
    compaction_threshold_percent: p.compaction_threshold_percent ?? null,
    // Model-thinking knobs (plan 2026-08-23-model-thinking). Anthropic budget + OpenAI effort. Both
    // default to null when missing from the persisted agent, so the form can decide whether to
    // render the row (it does for thinking !== "off").
    thinking_budget_tokens: p.thinking_budget_tokens ?? null,
    reasoning_effort: p.reasoning_effort ?? null,
  }))
  activeAgent.value = c.active_profile ?? null
  agentsTouched.value = false
  mcpServersList.value = parseMcpServers(c.mcp_servers)
  // Web search providers hydrate with whatever `key` the backend sent, which may be a MASK rather
  // than the secret. It is kept verbatim so a save that does not touch the key field cannot blank
  // the stored credential — see webSearchProviders.ts.
  webSearchRows.value = parseWebSearchProviders(c.web_search)
  webSearchErrors.value = {}
  // Tools checklist — `null`/absent stays null (built-in defaults);
  // an array hydrates the checklist as an explicit selection.
  toolsList.value = c.tools ?? null

  // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: hydrate the General tab from the
  // loaded config.
  generalSettings.value = {
    notify_on_complete: c.notify_on_complete ?? false,
    notify_on_error: c.notify_on_error ?? false,
    // Treat `undefined` (missing key) and explicit 0 the same way so
    // the dirty pill doesn't flash on first load when the field is
    // absent from config.json.
    retry_delay_ms: c.retry_delay_ms ?? 0,
    // Plan 2026-09-10-web-launch-toggle: browser-mode flag, same
    // `?? false` hydration as the notify toggles.
    web_launch_enabled: c.web_launch_enabled ?? false,
    chat_view: c.chat_view === 'compact' ? 'compact' : 'dev',
  }
  // Remember the persisted flag so handleSave can detect the OFF→ON
  // transition for the one-time browser auto-open.
  prevWebLaunch.value = generalSettings.value.web_launch_enabled

  // Skill Evals: keep the raw block for the save, and project just the switch for the checkbox. A
  // config with no `skill_evals` key hydrates as OFF — the same default the runtime uses, so the
  // toggle never shows a phantom ON.
  skillEvalsRaw.value = c.skill_evals
  skillEvalsHydrated.value = c.skill_evals?.enabled ?? false
  skillEvalsSettings.value = { enabled: skillEvalsHydrated.value }
}

// ─── Models & compaction ────────────────────────────────────────────── THE TWO FIELDS THAT HAD NO
// UI.
const catalogFreshness = ref<'fresh' | 'stale' | 'absent'>('absent')
const catalogModelTotal = ref<number | null>(null)
const catalogError = ref<string | null>(null)
const refreshingCatalog = ref(false)

const catalogFreshnessLabel = computed<string>(() => {
  if (catalogError.value !== null) return 'catalog unavailable'
  switch (catalogFreshness.value) {
    case 'fresh':
      return catalogModelTotal.value === null
        ? 'catalog ready'
        : `catalog ready · ${catalogModelTotal.value} models`
    case 'stale':
      return 'catalog stale'
    default:
      return 'catalog not synced yet'
  }
})

function setGlobalThreshold(raw: string): void {
  if (!config.value) return
  const trimmed = raw.trim()
  const parsed = Math.floor(Number(trimmed))
  config.value.compaction_threshold_percent =
    trimmed === '' || !Number.isFinite(parsed) ? null : Math.max(0, Math.min(100, parsed))
  syncToConfig()
}

function setGlobalWindow(raw: string): void {
  if (!config.value) return
  const trimmed = raw.trim()
  const parsed = Math.floor(Number(trimmed))
  config.value.max_capacity_token_model =
    trimmed === '' || !Number.isFinite(parsed) || parsed <= 0 ? null : parsed
  syncToConfig()
}

async function loadCatalogStatus(): Promise<void> {
  try {
    // `limit=1` because only the STATUS is wanted here; the picker asks for rows.
    const res = await getModelCatalog(undefined, undefined, 1)
    catalogFreshness.value = res.catalog
    catalogModelTotal.value = res.total
    catalogError.value = null
  } catch (err) {
    // Surface it: "not synced yet" and "the server is down" are different
    // states and the label must not collapse them.
    catalogFreshness.value = 'absent'
    catalogModelTotal.value = null
    catalogError.value = err instanceof Error ? err.message : String(err)
  }
}

async function refreshCatalog(): Promise<void> {
  if (refreshingCatalog.value) return
  refreshingCatalog.value = true
  try {
    await refreshModelCatalog()
    await loadCatalogStatus()
  } catch (err) {
    catalogError.value = err instanceof Error ? err.message : String(err)
  } finally {
    refreshingCatalog.value = false
  }
}

onMounted(() => void loadCatalogStatus())

function syncToConfig() {
  if (!config.value) return
  const c = config.value
  // Only write list fields when non-empty, so the structural shape of the config stays close to the
  // original (loaded) snapshot. Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
  // defaults are no longer sent — the agents map + operational settings only.
  const agents = agentsToRecord(agentsList.value)
  const mcpServers = serializeMcpServers(mcpServersList.value)
  const webSearch = serializeWebSearchProviders(webSearchRows.value)
  config.value = {
    ...c,
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the three operational settings are
    // driven by the General tab (`generalSettings`). Always write them through so toggling surfaces
    // in the dirty pill + save bar.
    notify_on_complete: generalSettings.value.notify_on_complete,
    notify_on_error: generalSettings.value.notify_on_error,
    retry_delay_ms: generalSettings.value.retry_delay_ms,
    // Plan 2026-09-10-web-launch-toggle: 4th operational setting,
    // always written through like its siblings.
    web_launch_enabled: generalSettings.value.web_launch_enabled,
    chat_view: generalSettings.value.chat_view,
    // Skill Evals: write the switch on top of the raw block, so the budget knobs the UI doesn't
    // expose survive the save untouched.
    ...(skillEvalsSettings.value.enabled !== skillEvalsHydrated.value
      ? {
          skill_evals: {
            // Spreading a missing block already contributes nothing —
            // an explicit `?? {}` fallback is dead weight here.
            ...skillEvalsRaw.value,
            enabled: skillEvalsSettings.value.enabled,
          },
        }
      : skillEvalsRaw.value !== undefined
        ? { skill_evals: skillEvalsRaw.value }
        : {}),
    // Top-level compaction defaults — plan 2026-07-07-compaction-inline.
    // Unconditional spread so `null` is preserved (cascade wildcard).
    max_capacity_token_model: c.max_capacity_token_model,
    compaction_threshold_percent: c.compaction_threshold_percent,
    // The agents map rides under the wire key `profiles` — the storage
    // contract keeps its old name, the concept is an AGENT.
    ...(agentsTouched.value || Object.keys(agents).length > 0 ? { profiles: agents } : {}),
    ...(activeAgent.value ? { active_profile: activeAgent.value } : {}),
    ...(mcpServers ? { mcp_servers: mcpServers } : {}),
    // Same guard for `web_search`: no providers means the key is left
    // exactly as loaded, so the backend sees "no change" instead of an
    // empty map that would wipe the user's providers.
    ...(webSearch ? { web_search: webSearch } : {}),
    // Tools checklist follows the mcp_servers guard: while nothing was chosen (`null`) the key is
    // left exactly as loaded so the backend sees "no change"; a chosen list — including `[]` — is
    // written through and replaces the whole stored list.
    ...(toolsList.value !== null ? { tools: toolsList.value } : {}),
  }
}

function agentsToRecord(list: AgentRow[]): Record<string, PabrikAgent> {
  const out: Record<string, PabrikAgent> = {}
  for (const a of list) {
    const { name, ...rest } = a
    out[name] = rest
  }
  return out
}

// ─── Modal state ──────────────────────────────────────────────────────────
type AgentModalState = { mode: 'add' | 'edit'; value: AgentModalValue } | null
type McpServerModalState = { mode: 'add' | 'edit'; value: McpServerModalValue } | null

const agentModal = ref<AgentModalState>(null)
const mcpServerModal = ref<McpServerModalState>(null)

const agentErrors = ref<{ name?: string; model?: string; base_url?: string; api_key?: string }>({})
const mcpServerErrors = ref<{ name?: string; url?: string; command?: string }>({})

// ─── Section event handlers ──────────────────────────────────────────────
function startAddAgent() {
  agentModal.value = {
    mode: 'add',
    value: {
      name: '',
      system_prompt: '',
      config: {
        model: '',
        base_url: '',
        thinking: 'auto',
        temperature: 'auto',
        url_style: 'openai',
        api_key: '',
        backend: 'http',
        config_dir: null,
        max_turns: null,
        max_capacity_tokens: null,
        compaction_threshold_percent: null,
        thinking_budget_tokens: null,
        reasoning_effort: null,
      },
    },
  }
}
function startEditAgent(p: AgentRow) {
  agentModal.value = {
    mode: 'edit',
    value: {
      name: p.name,
      system_prompt: p.system_prompt ?? '',
      config: {
        model: p.model ?? '',
        base_url: p.base_url ?? '',
        thinking: p.thinking ?? 'auto',
        temperature: p.temperature ?? 'auto',
        url_style: p.url_style ?? 'openai',
        api_key: p.api_key ?? '',
        backend: p.backend ?? 'http',
        config_dir: p.config_dir ?? null,
        max_turns: p.max_turns ?? null,
        // Compaction overrides — plan 2026-07-07-compaction-inline.
        max_capacity_tokens: p.max_capacity_tokens ?? null,
        compaction_threshold_percent: p.compaction_threshold_percent ?? null,
        // Model-thinking knobs (plan 2026-08-23-model-thinking).
        // Hydrate from the loaded agent so the form re-opens
        // with the previously-saved budget / effort.
        thinking_budget_tokens: p.thinking_budget_tokens ?? null,
        reasoning_effort: p.reasoning_effort ?? null,
      },
    },
  }
}
function closeAgentModal() {
  agentModal.value = null
  agentErrors.value = {}
}
function saveAgent() {
  if (!agentModal.value) return
  const v = agentModal.value.value
  const name = v.name.trim()
  if (!name) {
    agentErrors.value = { name: 'Name is required' }
    return
  }
  if (!v.config.model.trim()) {
    agentErrors.value = { model: 'Model is required' }
    return
  }
  agentsTouched.value = true
  const row = { name, ...v.config, system_prompt: v.system_prompt }
  if (agentModal.value.mode === 'add') {
    agentsList.value = [...agentsList.value, row]
  } else {
    agentsList.value = agentsList.value.map((a) => (a.name === name ? { ...a, ...row } : a))
  }
  syncToConfig()
  closeAgentModal()
}
function deleteAgent(name: string) {
  // Optimistic local removal; the API call is best-effort.
  const previous = agentsList.value
  const previousActive = activeAgent.value
  agentsTouched.value = true
  agentsList.value = agentsList.value.filter((a) => a.name !== name)
  if (activeAgent.value === name) activeAgent.value = null
  syncToConfig()
  source.deleteAgent(name).catch((err) => {
    agentsList.value = previous
    activeAgent.value = previousActive
    syncToConfig()
    emit(
      'notification',
      `Failed to delete agent "${name}": ${err instanceof Error ? err.message : String(err)}`,
      'error',
    )
  })
}

function startAddMcpServer() {
  mcpServerModal.value = {
    mode: 'add',
    value: {
      name: '',
      transport: 'stdio', // default for new entries — stdio is the
      // canonical MCP transport and the user added it specifically for
      // that. Legacy callers can pass `initialTransport='http'` if
      // they need the old behaviour.
      url: '',
      headers: [],
      command: '',
      args: [],
      env: [],
      cwd: '',
      enabled: true,
    },
  }
}
function startEditMcpServer(server: McpServer) {
  mcpServerModal.value = {
    mode: 'edit',
    value: {
      name: server.name,
      transport: server.transport ?? 'http',
      url: server.url ?? '',
      headers: (server.headers ?? []).map((h) => ({ ...h })),
      command: server.command ?? '',
      args: (server.args ?? []).slice(),
      env: (server.env ?? []).slice(),
      cwd: server.cwd ?? '',
      enabled: server.enabled ?? true,
    },
  }
}
function closeMcpServerModal() {
  mcpServerModal.value = null
  mcpServerErrors.value = {}
}
function saveMcpServer() {
  if (!mcpServerModal.value) return
  const v = mcpServerModal.value.value
  const name = v.name.trim()
  if (!name) {
    mcpServerErrors.value = { name: 'Name is required' }
    return
  }
  const isStdio = v.transport === 'stdio'
  if (isStdio) {
    if (!v.command.trim()) {
      mcpServerErrors.value = { command: 'Command is required' }
      return
    }
    const next: McpServer = {
      name,
      transport: 'stdio',
      command: v.command.trim(),
      args: v.args,
      env: v.env,
      cwd: v.cwd.trim(),
      headers: [],
      enabled: v.enabled,
    }
    if (mcpServerModal.value.mode === 'add') {
      mcpServersList.value = [...mcpServersList.value, next]
    } else {
      mcpServersList.value = mcpServersList.value.map((s) => (s.name === name ? next : s))
    }
  } else {
    const url = v.url.trim()
    if (!url) {
      mcpServerErrors.value = { url: 'URL is required' }
      return
    }
    const next: McpServer = {
      name,
      transport: 'http',
      url,
      headers: v.headers.filter((h) => h.key.length > 0),
      enabled: v.enabled,
    }
    if (mcpServerModal.value.mode === 'add') {
      mcpServersList.value = [...mcpServersList.value, next]
    } else {
      mcpServersList.value = mcpServersList.value.map((s) => (s.name === name ? next : s))
    }
  }
  syncToConfig()
  closeMcpServerModal()
}
function deleteMcpServer(name: string) {
  mcpServersList.value = mcpServersList.value.filter((s) => s.name !== name)
  syncToConfig()
}
function toggleMcpServer(name: string) {
  mcpServersList.value = mcpServersList.value.map((s) =>
    s.name === name ? { ...s, enabled: (s.enabled ?? true) ? false : true } : s,
  )
  syncToConfig()
}

// ToolsSection always emits the FULL explicit array — write it to
// the section ref and re-serialize so the save bar sees the change
// immediately.
function handleToolsChange(list: string[]) {
  toolsList.value = list
  syncToConfig()
}

// ─── Web search providers ───────────────────────────────────────────────── The section edits rows
// in place; every mutation clears the row errors, because an error describes the row as it was when
// the save failed and would otherwise outlive the edit that fixed it.
function updateWebSearchRows(rows: WebSearchProviderRow[]) {
  webSearchRows.value = rows
  webSearchErrors.value = {}
  syncToConfig()
}

function addWebSearchRow() {
  webSearchRows.value = [...webSearchRows.value, createWebSearchProviderRow()]
  syncToConfig()
}

// ─── Set active (instant — no dirty pill, immediate save) ───────────────
const isSettingActive = ref(false)
async function setActiveAgent(name: string) {
  activeAgent.value = name
  syncToConfig()
  isSettingActive.value = true
  try {
    await savePabrikConfig({ ...config.value, active_profile: name } as PabrikConfig)
    emit('notification', `Active agent set to "${name}"`, 'success')
  } catch (err) {
    emit(
      'notification',
      `Failed to set active: ${err instanceof Error ? err.message : String(err)}`,
      'error',
    )
  } finally {
    isSettingActive.value = false
  }
}

// Clear the active agent — same instant-save path as setActiveAgent, but writes
// `active_profile: ""` (empty string) to config.json.
async function clearActiveAgent() {
  const previous = activeAgent.value
  activeAgent.value = null
  syncToConfig()
  isSettingActive.value = true
  try {
    await savePabrikConfig({ ...config.value, active_profile: '' } as PabrikConfig)
    emit('notification', `Active agent cleared — using top-level config`, 'success')
  } catch (err) {
    activeAgent.value = previous // optimistic-rollback on failure
    syncToConfig()
    emit(
      'notification',
      `Failed to clear active: ${err instanceof Error ? err.message : String(err)}`,
      'error',
    )
  } finally {
    isSettingActive.value = false
  }
}

// ─── Save / Reset ────────────────────────────────────────────────────────
async function handleSave() {
  // In JSON mode the textarea can hold edits that were never applied, and
  // saving without them would report success while quietly dropping what the
  // user typed. Apply first, and refuse to save if the text is unusable.
  if (mode.value === 'json' && jsonText.value.trim().length > 0 && !applyJson()) {
    emit('notification', 'Fix the JSON before saving', 'error')
    return
  }
  // Capture the OFF→ON transition BEFORE save (prevWebLaunch tracks the
  // last persisted flag; generalSettings holds the pending edit).
  const autoOpen = generalSettings.value.web_launch_enabled && !prevWebLaunch.value
  // Pre-flight the web search rows against the rules the backend enforces. A provider the backend
  // would refuse would otherwise be written to disk and then silently dropped by the runtime's
  // parser — the agent would report "no providers configured" while the user has one on screen.
  const rowErrors = validateWebSearchRows(webSearchRows.value)
  if (Object.keys(rowErrors).length > 0) {
    webSearchErrors.value = rowErrors
    emit('notification', 'Fix the highlighted web search providers before saving', 'error')
    return
  }
  try {
    await save()
    webSearchErrors.value = {}
    prevWebLaunch.value = generalSettings.value.web_launch_enabled
    useChatViewStore().setMode(generalSettings.value.chat_view)
    await refreshWebStatus()
    emit('notification', 'Settings saved', 'success')
    // Plan 2026-09-10-web-launch-toggle: auto-open the browser once on the OFF→ON transition. Fired
    // from the Save click (a user gesture) so popup-blockers let it through; the pill's Open button
    // remains the reliable path if it is ever blocked.
    if (autoOpen && webUrl.value) openWeb()
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    // Pin the message onto the row it names. The toast still fires — the
    // user may be on another tab — but a provider the backend rejected
    // must never reach the user as a generic "Save failed".
    webSearchErrors.value = {
      ...webSearchErrors.value,
      ...webSearchRowErrorsFromMessage(message, webSearchRows.value),
    }
    emit('notification', `Save failed: ${message}`, 'error')
  }
}

function handleReset() {
  reset()
  syncFromConfig()
}

// ─── Web launch (browser mode) ────────────────────────────────────────── Plan
// 2026-09-10-web-launch-toggle: the General tab pill shows the live browser URL from `GET
// /api/web/status`.
const webUrl = ref<string | null>(null)
const prevWebLaunch = ref(false)

async function refreshWebStatus() {
  try {
    const status = await getWebStatus()
    webUrl.value = status?.url ?? null
  } catch {
    webUrl.value = null
  }
}

function openWeb() {
  if (!webUrl.value) return
  window.open(webUrl.value, '_blank', 'noopener')
}

async function copyWeb() {
  if (!webUrl.value) return
  try {
    await navigator.clipboard.writeText(webUrl.value)
    emit('notification', 'Web URL copied', 'success')
  } catch (err) {
    emit(
      'notification',
      `Copy failed: ${err instanceof Error ? err.message : String(err)}`,
      'error',
    )
  }
}

// Fetch the live URL once settings load (best-effort — a null just
// renders the waiting hint until the next save refreshes it).
onMounted(async () => {
  await refreshWebStatus()
})

// ─── Confirm dialog for agent delete ─────────────────────────────────────
const confirmingDeleteAgent = ref<string | null>(null)
function requestDeleteAgent(name: string) {
  confirmingDeleteAgent.value = name
}
function cancelDeleteAgent() {
  confirmingDeleteAgent.value = null
}
function confirmDeleteAgent() {
  const name = confirmingDeleteAgent.value
  if (!name) return
  confirmingDeleteAgent.value = null
  deleteAgent(name)
}

// ─── Loading ─────────────────────────────────────────────────────────────
async function reload() {
  try {
    const data = await source.load()
    setConfig(data ?? {})
    syncFromConfig()
    if (mode.value === 'json') seedJsonText()
  } catch (err) {
    // An unreadable config and a workspace that legitimately has none must not
    // look identical.
    emit(
      'notification',
      `Could not load the settings: ${err instanceof Error ? err.message : String(err)}`,
      'error',
    )
  }
}

// ─── Computed ────────────────────────────────────────────────────────────
const isLoading = computed(() => !loaded.value)
</script>

<template>
  <div class="flex flex-col h-full" data-testid="pabrik-settings">
    <!-- Loading skeleton — holds the tab strip + a few section cards so
         the surface does not collapse to one line of text and snap open.
         The tab strip stays interactive so the user can pick where they
         were going; the sections below render their own skeletons via
         the `loading` prop. -->
    <template v-if="isLoading">
      <!-- Form / JSON. Not a section: it is a different way of looking at
           the whole config, so it stays reachable from every section. -->
      <div class="shrink-0 flex items-center justify-end gap-1 px-1 pt-1">
        <button
          type="button"
          data-testid="mode-form"
          :data-active="mode === 'form' ? 'true' : 'false'"
          class="px-3 h-7 rounded-md text-dense font-medium transition-colors duration-150"
          :style="
            mode === 'form'
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'
          "
          @click="showForm"
        >
          Form
        </button>
        <button
          type="button"
          data-testid="mode-json"
          :data-active="mode === 'json' ? 'true' : 'false'"
          class="px-3 h-7 rounded-md text-dense font-medium transition-colors duration-150"
          :style="
            mode === 'json'
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'
          "
          @click="showJson"
        >
          JSON
        </button>
      </div>
      <div class="flex-1 overflow-y-auto p-6 space-y-6" data-testid="pabrik-settings-skeleton">
        <SettingsSkeleton :rows="4" test-id="pabrik-settings-loading-skeleton" />
      </div>
    </template>

    <template v-else>
      <!-- Tab strip -->

      <!-- Form / JSON. Not a section: it is a different way of looking at
           the whole config, so it stays reachable from every section. -->
      <div class="shrink-0 flex items-center justify-end gap-1 px-1 pt-1">
        <button
          type="button"
          data-testid="mode-form"
          :data-active="mode === 'form' ? 'true' : 'false'"
          class="px-3 h-7 rounded-md text-dense font-medium transition-colors duration-150"
          :style="
            mode === 'form'
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'
          "
          @click="showForm"
        >
          Form
        </button>
        <button
          type="button"
          data-testid="mode-json"
          :data-active="mode === 'json' ? 'true' : 'false'"
          class="px-3 h-7 rounded-md text-dense font-medium transition-colors duration-150"
          :style="
            mode === 'json'
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'
          "
          @click="showJson"
        >
          JSON
        </button>
      </div>

      <!-- Save bar (only when dirty). Pinned to the TOP of the pane, above
           the scrollable content: the actions stay reachable no matter how
           far down the section the user has scrolled, and the count of
           unsaved changes is the first thing they see when they come back
           to the page. It is a `shrink-0` flex item OUTSIDE the scrolling
           region, so it does not scroll away with the content. -->
      <div class="shrink-0">
        <PabrikSaveBar
          :dirty="dirty"
          :unsaved-count="unsavedCount"
          :saving="saving"
          @reset="handleReset"
          @save="handleSave"
        />
      </div>

      <!-- Raw JSON view. Shows the WHOLE config in memory - which in the
           workspace scope is the effective config (the user's, with this
           workspace's overlay merged over it), so what you read here is what
           a run in this workspace actually uses. -->
      <div
        v-if="mode === 'json'"
        class="flex-1 overflow-y-auto p-6 space-y-3"
        data-testid="config-json-panel"
      >
        <p class="text-dense" style="color: var(--semantic-text-muted)">
          <template v-if="source.scope === 'workspace'">
            Only the settings that live in Workspace settings — agents, MCP servers, tools, skill
            evals and web search — are stored for this workspace. Everything else comes from your
            user settings and is not saved from here.
          </template>
          <template v-else>
            This is the whole config that applies to every workspace, exactly as it is stored.
          </template>
        </p>

        <textarea
          v-model="jsonText"
          data-testid="config-json-textarea"
          spellcheck="false"
          rows="20"
          class="w-full rounded-md p-3 font-mono text-dense"
          style="
            background-color: var(--semantic-content-bg);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
          "
          @input="onJsonInput"
        />

        <p
          v-if="jsonProblem"
          data-testid="config-json-error"
          class="text-dense"
          style="color: var(--color-red)"
        >
          {{ jsonProblem }}
        </p>

        <div class="flex items-center gap-3">
          <button
            type="button"
            data-testid="config-json-apply"
            :disabled="jsonProblem !== null"
            class="px-3 h-8 rounded-md text-dense font-medium"
            :style="
              jsonProblem !== null
                ? 'background-color: var(--semantic-content-bg); color: var(--semantic-text-muted); cursor: not-allowed;'
                : 'background-color: var(--color-violet); color: var(--semantic-active-text);'
            "
            @click="applyJson"
          >
            Apply
          </button>
          <span v-if="jsonApplied" class="text-dense" style="color: var(--semantic-text-muted)">
            Applied — Save writes it.
          </span>
        </div>
      </div>

      <!-- Scrollable tab content -->
      <div v-else class="flex-1 overflow-y-auto p-6 space-y-6">
        <PabrikGeneralSection
          v-if="activeTab === 'general'"
          v-model="generalSettings"
          :web-url="webUrl"
          @update:model-value="syncToConfig"
          @open-web="openWeb"
          @copy-web="copyWeb"
        />

        <!-- Interface preferences — app-local (localStorage), not config.json -->
        <div
          v-if="activeTab === 'general'"
          class="rounded-lg p-5 space-y-3"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
          "
        >
          <div class="flex items-center gap-2">
            <UiIcon name="cards" class="w-4 h-4" />
            <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Interface</h3>
          </div>

          <label class="flex items-start gap-3 cursor-pointer" data-testid="row-browser-tabs">
            <input
              type="checkbox"
              data-testid="toggle-browser-tabs"
              :checked="tabsStore.enabled"
              @change="onToggleBrowserTabs(($event.target as HTMLInputElement).checked)"
              class="mt-1 w-4 h-4 cursor-pointer"
              style="accent-color: var(--color-violet)"
            />
            <div class="flex-1 min-w-0">
              <div class="text-body font-medium" style="color: var(--semantic-text)">
                Browser-style tabs
              </div>
              <div class="text-dense mt-0.5" style="color: var(--semantic-text-dim)">
                Keep several chats, boards and pages open at once in a tab strip above the content
                area. Shortcuts: Shift+Alt+T (new), Shift+Alt+W (close), Shift+Alt+Z (reopen),
                Shift+Alt+←/→ (switch). Off restores the single-view layout.
              </div>
            </div>
          </label>
        </div>

        <!-- Models & compaction — the global knobs over the catalog's window. -->
        <div
          v-if="activeTab === 'general'"
          class="rounded-lg p-5 space-y-3"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
          "
          data-testid="models-compaction-block"
        >
          <div class="flex items-center gap-2">
            <UiIcon name="atom" class="w-4 h-4" />
            <h3 class="text-body font-semibold" style="color: var(--semantic-text)">
              Models &amp; compaction
            </h3>
            <span
              class="ml-auto font-mono text-dense"
              :style="
                catalogFreshness === 'fresh'
                  ? { color: 'var(--color-violet)' }
                  : { color: 'var(--semantic-text-dim)' }
              "
              data-testid="catalog-freshness"
              >{{ catalogFreshnessLabel }}</span
            >
          </div>
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            pabrik reads each model's context window, output cap and reasoning shape from
            <span class="font-mono">models.dev</span>, cached in the database and synced in the
            background every hour. Compaction then fires at the threshold below of that window.
            These two fields override the catalog for every agent that does not set its own.
          </p>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label
                class="block text-dense font-medium mb-1.5"
                style="color: var(--semantic-text-muted)"
              >
                Default compaction threshold (%)
              </label>
              <input
                :value="config?.compaction_threshold_percent ?? ''"
                @input="setGlobalThreshold(($event.target as HTMLInputElement).value)"
                type="number"
                min="0"
                max="100"
                placeholder="built-in 80"
                class="w-full px-3 h-8 rounded-md border text-body"
                style="
                  background-color: var(--semantic-content-bg);
                  color: var(--semantic-text);
                  border-color: var(--color-border);
                "
                data-testid="global-threshold-input"
              />
            </div>
            <div>
              <label
                class="block text-dense font-medium mb-1.5"
                style="color: var(--semantic-text-muted)"
              >
                Force context window (tokens)
              </label>
              <input
                :value="config?.max_capacity_token_model ?? ''"
                @input="setGlobalWindow(($event.target as HTMLInputElement).value)"
                type="number"
                min="0"
                step="1000"
                placeholder="from the model"
                class="w-full px-3 h-8 rounded-md border text-body"
                style="
                  background-color: var(--semantic-content-bg);
                  color: var(--semantic-text);
                  border-color: var(--color-border);
                "
                data-testid="global-window-input"
              />
            </div>
          </div>
          <div class="flex items-center gap-3">
            <button
              type="button"
              @click="refreshCatalog"
              :disabled="refreshingCatalog"
              class="px-3 h-8 rounded-md text-dense border transition-colors duration-150"
              :style="{
                borderColor: 'var(--color-border)',
                color: refreshingCatalog ? 'var(--semantic-text-dim)' : 'var(--semantic-text)',
                backgroundColor: 'transparent',
                cursor: refreshingCatalog ? 'wait' : 'pointer',
              }"
              data-testid="refresh-catalog-btn"
            >
              {{ refreshingCatalog ? 'Refreshing…' : 'Refresh catalog now' }}
            </button>
            <span
              v-if="catalogError"
              class="font-mono text-dense"
              style="color: var(--color-red)"
              data-testid="catalog-error"
              >{{ catalogError }}</span
            >
          </div>
        </div>

        <SkillEvalsSection
          v-if="activeTab === 'evals'"
          v-model="skillEvalsSettings"
          :loaded="loaded"
          @update:model-value="syncToConfig"
        />

        <AgentsSection
          v-if="activeTab === 'agents'"
          v-model="agentsList"
          :active-agent="activeAgent"
          :loading="isLoading"
          @update:model-value="syncToConfig"
          @set-active="setActiveAgent"
          @clear-active="clearActiveAgent"
          @edit="startEditAgent"
          @delete="requestDeleteAgent"
          @add="startAddAgent"
        />

        <McpServersSection
          v-else-if="activeTab === 'mcp'"
          v-model="mcpServersList"
          :loading="isLoading"
          @update:model-value="syncToConfig"
          @edit="startEditMcpServer"
          @delete="deleteMcpServer"
          @toggle="toggleMcpServer"
          @add="startAddMcpServer"
        />
        <!-- Web search providers share the MCP tab: both answer "where
             does the agent reach outside this machine". Its own `v-if`
             (not a bare element) so the `v-else-if` chain below still
             reads as one chain. -->
        <div
          v-if="activeTab === 'mcp'"
          class="mt-6 pt-6"
          style="border-top: 1px solid var(--color-border)"
        >
          <h3 class="text-body font-semibold mb-1" style="color: var(--semantic-text)">
            Web search providers
          </h3>
          <WebSearchSection
            :model-value="webSearchRows"
            :errors="webSearchErrors"
            :loading="isLoading"
            @update:model-value="updateWebSearchRows"
            @add="addWebSearchRow"
          />
        </div>
        <ToolsSection
          v-else-if="activeTab === 'tools'"
          :model-value="toolsList"
          @change="handleToolsChange"
        />
        <!-- Plan 2026-07-07-compaction-inline: the dedicated Compaction
             tab is REMOVED. Compaction settings now live in the Defaults
             tab (top-level defaults) + the Edit-agent modal
             (per-agent overrides). There is no 'compaction' section. -->
      </div>
    </template>

    <!-- Modals -->
    <AgentModal
      v-if="agentModal"
      v-model="agentModal.value"
      :errors="agentErrors"
      :mode="agentModal.mode"
      @cancel="closeAgentModal"
      @save="saveAgent"
    />

    <McpServerModal
      v-if="mcpServerModal"
      v-model="mcpServerModal.value"
      :errors="mcpServerErrors"
      :mode="mcpServerModal.mode"
      @cancel="closeMcpServerModal"
      @save="saveMcpServer"
    />

    <!-- Confirm delete dialog -->
    <ConfirmDialog
      :show="confirmingDeleteAgent !== null"
      title="Delete agent"
      :message="`Are you sure you want to delete the agent \u201c${confirmingDeleteAgent ?? ''}\u201d? This cannot be undone.`"
      confirm-text="Delete"
      cancel-text="Cancel"
      @confirm="confirmDeleteAgent"
      @close="cancelDeleteAgent"
    />
  </div>
</template>
