import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import * as api from '../api'
import PabrikConfigEditor from '../components/pabrik/PabrikConfigEditor.vue'
import { makeLocalStorageStub } from './helpers'

// The autosave window is a wall-clock wait in the app; mount it at 0 so a spec settles the PUT
// with a microtask drain instead of sleeping.
vi.mock('../composables/autosaveDelay', () => ({ AUTOSAVE_DELAY_MS: 0 }))

vi.mock('../api', () => ({
  getPabrikConfig: vi.fn(),
  savePabrikConfig: vi.fn(),
  deleteAgent: vi.fn(),
  // Plan 2026-09-10-web-launch-toggle: browser-mode status for the
  // General tab URL pill. Resolves null by default (pill waiting hint).
  getWebStatus: vi.fn(),
  // Tools tab catalog — consumed by the agentTools store inside
  // ToolsSection; only fetched when the Tools tab mounts.
  getAgentToolsRegistry: vi.fn(),
  // The agent modal mounts LlmConfigForm, which resolves the typed model on
  // mount and on every debounced edit. Without these the form throws.
  resolveModelOutcome: vi.fn(),
  getModelCatalog: vi.fn(),
  // The rename guard: how many running sessions are pinned to the profile.
  getAgentProfileInUse: vi.fn(),
}))

const mockGet = api.getPabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.savePabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>
const mockRegistry = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>
const mockDeleteAgent = api.deleteAgent as unknown as ReturnType<typeof vi.fn>
const mockProfileInUse = api.getAgentProfileInUse as unknown as ReturnType<typeof vi.fn>
const mockResolveModel = api.resolveModelOutcome as unknown as ReturnType<typeof vi.fn>
const mockModelCatalog = api.getModelCatalog as unknown as ReturnType<typeof vi.fn>

/** With a 0 ms autosave window the PUT starts inside the edit handler, so a few microtask turns
 * settle it: the save, the re-snapshot, and the follow-up agent-key cleanup. */
async function settleAutosave() {
  await flushPromises()
  await flushPromises()
  await flushPromises()
}

// Catalog fixture for the Tools tab. `set_git_worktree` is NOT part
// of the built-in defaults, so checking it is a visible edit.
const TOOLS_REGISTRY = [
  { name: 'command', description: 'Run a shell command' },
  { name: 'glob', description: 'Find files by glob pattern' },
  { name: 'set_git_worktree', description: 'Create a git worktree and bind it' },
]

describe('PabrikConfigEditor (orchestrator)', () => {
  beforeEach(() => {
    // PabrikSettings reads the tabs store for the "Browser-style tabs"
    // preference (Settings → General), so it needs an active pinia.
    setActivePinia(createPinia())
    mockGet.mockReset()
    mockSave.mockReset()
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
    mockRegistry.mockReset()
    mockRegistry.mockResolvedValue({ tools: TOOLS_REGISTRY })
    mockDeleteAgent.mockReset()
    mockDeleteAgent.mockResolvedValue({ success: true })
    mockProfileInUse.mockReset()
    mockProfileInUse.mockResolvedValue({ name: 'work', running: 0, sessions: [] })
    mockResolveModel.mockReset()
    mockResolveModel.mockResolvedValue({ kind: 'error', message: 'unknown model' })
    mockModelCatalog.mockReset()
    mockModelCatalog.mockResolvedValue({ models: [], total: 0, state: 'absent' })
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('deep-links ?section=evals to the Skill Evals toggle', async () => {
    // The Evals sidebar panel links here when it has nothing to show, so
    // the destination must be reachable by URL alone (a refresh or a
    // shared link has to land on the toggle, not the first tab).
    const router = await makeSettingsRouter({ section: 'evals' })
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="skill-evals-section"]').exists()).toBe(true)
  })

  it('never mounts a separate sub-agents section (the agent list is the only editor)', async () => {
    // Plan 2026-09-04-subagents-per-profile regression: the global
    // `subAgentsList` + the sub-agents section mount are gone. Even with a
    // legacy top-level `sub_agents` payload, no global list renders.
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      sub_agents: [{ name: 'legacy', model: 'm' }],
    })
    const wrapper = mount(PabrikConfigEditor, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="subagent-list"]').exists()).toBe(false)
  })

  it('lands on the General tab by default', async () => {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // first-load tab is General — operational settings are the most
    // likely entry point for new users.
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(true)
  })

  it('loads the config on mount and shows the Agents section', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'gpt-4o-mini', base_url: 'https://x' } },
    })
    const wrapper = await mountAt('agents')
    expect(mockGet).toHaveBeenCalled()
    // The agent name is visible. (This used to assert `toContain('work')`
    // while landing on GENERAL, so it passed on the word "worktree" in an
    // unrelated registry blurb - a green test that proved nothing.)
    expect(wrapper.find('[data-testid="agent-list"]').text()).toContain('work')
  })

  it('does not send top-level LLM defaults in the PUT body (config-simplify)', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm1' } },
      notify_on_complete: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    // Make a real edit so the config is written back. Switching tabs used to be enough BY ACCIDENT
    // - the Profiles section emitted an update while hydrating, which happened to mark it dirty.
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    // The change reaches the server on its own — there is no Save button left to press.
    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    for (const key of [
      'api_endpoint',
      'api_key',
      'model',
      'url_style',
      'temperature',
      'max_tokens',
      'system_prompt',
    ]) {
      expect(savedConfig).not.toHaveProperty(key)
    }
    expect(savedConfig.profiles).toBeDefined()
  })

  // ─── Per-profile sub-agents (regression for the inline-expand flow) ──
  it('saves the agent system prompt on the agent it belongs to', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: {
        work: {
          model: 'm',
          base_url: '',
          thinking: 'auto',
          temperature: 'auto',
          url_style: 'openai',
          api_key: '',
          system_prompt: 'you are the work agent',
        },
        home: {
          model: 'm2',
          base_url: '',
          thinking: 'auto',
          temperature: 'auto',
          url_style: 'openai',
          api_key: '',
        },
      },
    })
    const wrapper = await mountAt('agents')

    // Open the Edit modal for the 'work' agent and change its system prompt.
    const rows = wrapper.findAll('[data-testid="agent-list"] > li')
    const workRow = rows.find((r) => r.text().includes('work'))
    expect(workRow).toBeDefined()
    await workRow!.find('[data-testid="edit-btn"]').trigger('click')
    await flushPromises()

    const promptBox = wrapper.find('[data-testid="agent-system-prompt-input"]')
    expect(promptBox.exists()).toBe(true)
    await promptBox.setValue('you are the reviewer now')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    // Save changes and verify the prompt landed on 'work' only.
    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    const agents = savedConfig.profiles as Record<string, Record<string, unknown>>
    expect(agents.work!.system_prompt).toBe('you are the reviewer now')
    expect(agents.home!.system_prompt ?? '').toBe('')
  })

  // ─── Clear active profile (plan 2026-08-06-reset-active-profile) ── Plan: Settings → Profiles →
  // Reset button next to the active pill emits `clearActive` → orchestrator calls savePabrikConfig
  // with `active_profile: ""` (empty string) → the backend handler at.
  it('saves active_profile: "" when the Reset button is clicked', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' }, home: { model: 'm2' } },
      active_profile: 'work',
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    // Switch to Profiles tab. Plan 2026-08-25-notify-on-error moved General to index 0; Profiles is
    // now at index 1. The active pill should show 'work' and the Reset button should be visible.
    expect(wrapper.text()).toContain('work')
    const resetBtn = wrapper.find('[data-testid="reset-active-btn"]')
    expect(resetBtn.exists()).toBe(true)

    // Click Reset → savePabrikConfig receives { ..., active_profile: '' }.
    // The backend interprets empty-string as "clear".
    await resetBtn.trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.active_profile).toBe('')
  })

  it('emits a success notification when the Reset button is clicked', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      active_profile: 'work',
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')
    await flushPromises()
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('notification')?.some((e) => e[1] === 'success')).toBe(true)
  })

  it('restores the previous active profile when savePabrikConfig fails (optimistic rollback)', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      active_profile: 'work',
    })
    mockSave.mockRejectedValueOnce(new Error('network down'))
    const wrapper = await mountAt('agents')
    await flushPromises()
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    await settleAutosave()

    // After the failed save, the local activeProfile should still
    // reflect the original value (rolled back from the optimistic null).
    expect(wrapper.text()).toContain('work')
    // And an error notification should fire.
    expect(wrapper.emitted('notification')?.some((e) => e[1] === 'error')).toBe(true)
  })

  // ─── General tab (plan 2026-08-25-notify-on-error-and-retry-ms-in-settings) ── Three operational
  // settings live in the General tab: - `notify_on_complete` (existing config.json field) -
  // `notify_on_error` (new field added by this plan).
  it('hydrates the General tab from the loaded config (notify_on_complete + notify_on_error + retry_delay_ms)', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: true,
      notify_on_error: true,
      retry_delay_ms: 15000,
      web_launch_enabled: true,
    })
    mockWebStatus.mockResolvedValueOnce({
      enabled: true,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // The General tab is the first tab and lands there by default.
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(true)
    // Both toggles reflect the loaded values.
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-complete"]').element as HTMLInputElement)
        .checked,
    ).toBe(true)
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-error"]').element as HTMLInputElement).checked,
    ).toBe(true)
    // The retry-delay input is in seconds (15000 ms = 15 sec).
    expect(
      Number(
        (wrapper.find('[data-testid="input-retry-delay-seconds"]').element as HTMLInputElement)
          .value,
      ),
    ).toBe(15)
    // Plan 2026-09-10-web-launch-toggle: the web-launch toggle reflects
    // the loaded flag and the pill shows the live status URL.
    expect(
      (wrapper.find('[data-testid="toggle-web-launch"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(wrapper.find('[data-testid="pill-web-url"]').text()).toContain('http://127.0.0.1:51234/')
  })

  it('toggling notify_on_error in the General tab reaches the server on its own', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Nothing has been written yet, so there is nothing to report.
    expect(wrapper.find('[data-testid="save-status"]').exists()).toBe(false)

    // Toggle notify_on_error ON — no button, no confirmation step.
    const toggle = wrapper.find('[data-testid="toggle-notify-on-error"]')
    await toggle.setValue(true)
    await flushPromises()

    // The strip is up while the change is on its way.
    expect(wrapper.find('[data-testid="save-status"]').exists()).toBe(true)

    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.notify_on_error).toBe(true)
    // The other operational settings should also be in the body
    // (syncToConfig writes them through unconditionally — now four).
    expect(savedConfig.notify_on_complete).toBe(false)
    expect(savedConfig.retry_delay_ms).toBe(0)
    expect(savedConfig.web_launch_enabled).toBe(false)
    // And the user is told it landed.
    expect(wrapper.find('[data-testid="save-status-text"]').text()).toBe('Saved')
  })

  it('reports a rejected change in the strip instead of claiming it was saved', async () => {
    mockGet.mockResolvedValueOnce({ notify_on_complete: false, notify_on_error: false })
    mockSave.mockRejectedValueOnce(new Error('HTTP 500'))
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await settleAutosave()

    expect(wrapper.find('[data-testid="save-status-text"]').text()).toContain("Couldn't save")
    expect(wrapper.find('[data-testid="save-status-text"]').text()).toContain('HTTP 500')

    // The edit is still unsaved, so the next one carries BOTH changes to the server.
    mockSave.mockResolvedValueOnce({ success: true })
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    await settleAutosave()

    expect(mockSave.mock.calls.at(-1)![0]).toMatchObject({
      notify_on_error: true,
      notify_on_complete: true,
    })
    expect(wrapper.find('[data-testid="save-status-text"]').text()).toBe('Saved')
  })

  it('offers no Save or Reset control: a change needs no confirmation', async () => {
    mockGet.mockResolvedValueOnce({ notify_on_complete: false })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    await settleAutosave()

    expect(wrapper.text()).not.toContain('Save changes')
    expect(wrapper.find('[data-testid="save-btn"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="reset-btn"]').exists()).toBe(false)
  })

  it('typing into the retry-delay input round-trips to retry_delay_ms in the PUT body', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Set the retry delay to 5 seconds → backend expects 5000 ms.
    const input = wrapper.find('[data-testid="input-retry-delay-seconds"]')
    await input.setValue('5')
    await flushPromises()

    // Save.
    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.retry_delay_ms).toBe(5000)
  })

  it('clamps retry-delay input values to [0, 60] seconds in the General tab', async () => {
    // The backend caps retry_delay_ms at 60_000 (pabrik_config_put.zig).
    // The UI clamps at the same range so the user gets immediate
    // feedback instead of a silent server-side clamp.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    const input = wrapper.find('[data-testid="input-retry-delay-seconds"]')

    // Above-max → clamps to 60 seconds (the underlying value should
    // be 60_000 ms — assert via the ms readout element's text
    // content, which is the source of truth the user sees).
    await input.setValue('999')
    await flushPromises()
    // The input element's `.value` is a string — vitest sometimes
    // formats numbers with locale separators, so check via the
    // dedicated ms-readout element instead.
    const msReadout = wrapper.find('[data-testid="retry-delay-ms-readout"]')
    expect(msReadout.text()).toContain('60000')

    // Below-min (negative) → clamps to 0.
    await input.setValue('-5')
    await flushPromises()
    expect(msReadout.text()).toContain('0')
  })

  it('the PUT body always includes all four operational settings, even when the user only edits one', async () => {
    // The General tab MUST write all four operational settings through (syncToConfig does this
    // unconditionally). This is a regression guard so a future refactor doesn't accidentally drop
    // one of them and silently re-introduce the hidden-field bug.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: true,
      notify_on_error: false,
      retry_delay_ms: 10000,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Toggle ONLY notify_on_error.
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await flushPromises()

    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.notify_on_complete).toBe(true)
    expect(savedConfig.notify_on_error).toBe(true)
    expect(savedConfig.retry_delay_ms).toBe(10000)
    expect(savedConfig.web_launch_enabled).toBe(false)
  })

  // ─── Web launch toggle (plan 2026-09-10-web-launch-toggle) ──
  it('toggling web-launch ON and saving PUTs web_launch_enabled:true and auto-opens the status URL', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    // Two status fetches happen: one on mount (pill), one after save
    // (auto-open). Queue the URL for both.
    mockWebStatus.mockResolvedValueOnce({
      enabled: false,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    mockWebStatus.mockResolvedValueOnce({
      enabled: true,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    const openSpy = vi.fn()
    const prevOpen = window.open
    window.open = openSpy as unknown as typeof window.open
    try {
      const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
      await flushPromises()

      await wrapper.find('[data-testid="toggle-web-launch"]').setValue(true)
      await flushPromises()
      await settleAutosave()

      expect(mockSave).toHaveBeenCalledTimes(1)
      const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
      expect(savedConfig.web_launch_enabled).toBe(true)
      // OFF→ON transition + known URL → one auto-open from the Save
      // gesture (popup-blocker safe).
      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openSpy).toHaveBeenCalledWith('http://127.0.0.1:51234/', '_blank', 'noopener')
    } finally {
      window.open = prevOpen
    }
  })

  // ─── MCP server enabled toggle (orchestrator) ──
  it('toggling a server off writes enabled:false for that server in the PUT body', async () => {
    mockGet.mockResolvedValueOnce({
      mcp_servers: {
        ctx7: { url: 'https://mcp.context7.com/mcp' },
        hello: { command: 'mcp-hello-world' },
      },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('mcp')
    await flushPromises()

    const toggles = wrapper.findAll('[data-testid="toggle-btn"]')
    expect(toggles).toHaveLength(2)
    // Rows sort by name: ctx7 first, hello second. Disable hello.
    await toggles[1]!.trigger('click')
    await flushPromises()

    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, Record<string, unknown>>
    const servers = savedConfig.mcp_servers as Record<string, Record<string, unknown>>
    expect(servers.hello).toMatchObject({ enabled: false })
    // The untouched server stays omit-when-true (no enabled key).
    expect(servers.ctx7).not.toHaveProperty('enabled')
  })

  it('toggling a disabled server back on drops the enabled key (omit-when-true)', async () => {
    mockGet.mockResolvedValueOnce({
      mcp_servers: {
        hello: { command: 'mcp-hello-world', enabled: false },
      },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('mcp')
    await flushPromises()

    await wrapper.find('[data-testid="toggle-btn"]').trigger('click')
    await flushPromises()

    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, Record<string, unknown>>
    const servers = savedConfig.mcp_servers as Record<string, Record<string, unknown>>
    expect(servers.hello).not.toHaveProperty('enabled')
  })

  // ─── Tools tab (plan 2026-09-22-tools-menu-config-default-tools) ────── Memory-history router
  // scoped to the settings path — same real- vue-router pattern as SidebarDiffPanel.tabs.spec (no
  // guards, no window.location, query stays observable via currentRoute).
  async function makeSettingsRouter(query: Record<string, string> = {}) {
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/app/settings', component: { template: '<div/>' } }],
    })
    await router.push({ path: '/app/settings', query })
    await router.isReady()
    return router
  }

  /**    * Mount the editor with a section already open. The editor no longer owns a tab strip - the
   * settings shell navigates and the section lives in `?section=` - so a spec opens a section the
   * way the app does: through the URL. */
  async function mountAt(section: string, query: Record<string, string> = {}) {
    const router = await makeSettingsRouter(section === 'general' ? query : { ...query, section })
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    return wrapper
  }

  it('the URL decides the section, and changing it swaps the rendered section', async () => {
    const router = await makeSettingsRouter()
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()

    // Mounting clean lands on General.
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(true)

    // The section is a URL fact now: the shell writes it, the editor obeys.
    await router.push({ path: '/app/settings', query: { section: 'tools' } })
    await flushPromises()
    expect(wrapper.find('[data-testid="tools-section"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(false)

    // 'general' is the default — back on it, the query is dropped.
    await router.push({ path: '/app/settings', query: {} })
    await flushPromises()
    expect(router.currentRoute.value.query.section).toBeUndefined()
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(true)
  })

  it('mounts with ?section=tools → Tools tab active and ToolsSection rendered (deep link)', async () => {
    const router = await makeSettingsRouter({ section: 'tools' })
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="tools-section"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="tools-section"]').exists()).toBe(true)
    // Config has no `tools` key → built-in defaults + dim note.
    expect(wrapper.find('[data-testid="defaults-note"]').exists()).toBe(true)
  })

  it('mount with clean URL + stored tools → URL gains ?section=tools (mount normalization)', async () => {
    // The reported bug: Tools active at /app/settings with no ?section=tools. The getter falls back
    // to localStorage without touching the URL, and TabStrip skips its emit when saved==prop — so
    // no router.replace ever runs. Mount must normalize the URL to the tab actually shown.
    localStorage.setItem('pabrik-settings-active-tab', 'tools')
    const router = await makeSettingsRouter()
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="tools-section"]').exists()).toBe(true)
    expect(router.currentRoute.value.query.section).toBe('tools')
  })

  it('mount with ?section=tools persists to storage so the next clean load restores it', async () => {
    const router = await makeSettingsRouter({ section: 'tools' })
    mockGet.mockResolvedValueOnce({})
    mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(localStorage.getItem('pabrik-settings-active-tab')).toBe('tools')
  })

  it('mount with ?section=general strips the default from the URL', async () => {
    const router = await makeSettingsRouter({ section: 'general' })
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(PabrikConfigEditor, {
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(true)
    expect(router.currentRoute.value.query.section).toBeUndefined()
  })

  it('hydrates an explicit tools list from config (no defaults note, checkboxes reflect it)', async () => {
    mockGet.mockResolvedValueOnce({ tools: ['command'] })
    const wrapper = await mountAt('tools')
    await flushPromises()

    expect(wrapper.find('[data-testid="defaults-note"]').exists()).toBe(false)
    const isChecked = (name: string) =>
      (wrapper.find(`[data-testid="row-${name}"] input`).element as HTMLInputElement).checked
    expect(isChecked('command')).toBe(true)
    expect(isChecked('glob')).toBe(false)
    expect(wrapper.find('[data-testid="tools-section"]').text()).toContain('1 of 3 tools selected')
  })

  it('checking a tool writes the explicit list to the server', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('tools')

    // Untouched checklist (null) → nothing to write, nothing to report.
    expect(wrapper.find('[data-testid="save-status"]').exists()).toBe(false)

    // set_git_worktree is not in the built-in defaults — checking it
    // writes the full explicit list (defaults ∩ registry + it).
    await wrapper.find('[data-testid="row-set_git_worktree"] input').setValue(true)
    await flushPromises()
    expect(wrapper.find('[data-testid="save-status"]').exists()).toBe(true)

    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.tools).toEqual(['command', 'glob', 'set_git_worktree'])
  })

  it('pins the autosave status ABOVE the scrollable content, not below it', async () => {
    // The strip used to be the last child of the editor, so what it reported sat below a section the
    // user has to scroll through. It is now the first thing after the Form/JSON toggle, which is what
    // keeps it in sight from any scroll position.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Make a real edit so the strip renders at all.
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await flushPromises()

    const bar = wrapper.find('[data-testid="save-status"]')
    expect(bar.exists()).toBe(true)

    const content = wrapper.find('.overflow-y-auto')
    expect(content.exists()).toBe(true)

    // DOCUMENT_POSITION_FOLLOWING (4) on `content` relative to `bar` means
    // the scrolling region comes AFTER the bar in the document.
    const contentVsBar = bar.element.compareDocumentPosition(content.element)
    expect(contentVsBar & 4).toBe(4)

    // And the bar is NOT inside the scrolling region — that is what makes it
    // stay put while the section scrolls under it.
    expect(bar.element.closest('.overflow-y-auto')).toBeNull()
  })

  it('omits tools from the PUT body while the checklist is untouched (null = no change)', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Dirty the form via an unrelated field, then save: the body must
    // not carry a `tools` key at all (backend: null/absent = no change).
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await flushPromises()
    await settleAutosave()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig).not.toHaveProperty('tools')
    expect(savedConfig.notify_on_error).toBe(true)
  })

  // ─── Disable / duplicate / create an agent ──────────────────────────
  it('switching an agent off writes enabled:false for that profile only', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' }, home: { model: 'm2' } },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="agent-enabled-switch-work"]').trigger('click')
    await flushPromises()
    await settleAutosave()

    expect(mockSave).toHaveBeenCalledTimes(1)
    const profiles = (mockSave.mock.calls[0]![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(profiles.work!.enabled).toBe(false)
    expect(profiles.home!.enabled).toBe(true)
  })

  it('a profile stored with enabled:false hydrates a switched-off row that saves unchanged', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { retired: { model: 'm', enabled: false } },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    expect(
      wrapper.find('[data-testid="agent-enabled-switch-retired"]').attributes('aria-checked'),
    ).toBe('false')

    await wrapper.find('[data-testid="duplicate-btn-retired"]').trigger('click')
    await flushPromises()
    await settleAutosave()

    const profiles = (mockSave.mock.calls[0]![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(profiles.retired!.enabled).toBe(false)
    expect(profiles['retired copy']!.enabled).toBe(false)
  })

  it('duplicate copies the whole agent under a "<name> copy" key', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'gpt-4o', system_prompt: 'be strict' } },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="duplicate-btn-work"]').trigger('click')
    await flushPromises()
    await settleAutosave()

    const profiles = (mockSave.mock.calls[0]![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(Object.keys(profiles).sort()).toEqual(['work', 'work copy'])
    expect(profiles['work copy']!.model).toBe('gpt-4o')
    expect(profiles['work copy']!.system_prompt).toBe('be strict')
  })

  it('duplicating the same agent twice never collides on the key', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="duplicate-btn-work"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="duplicate-btn-work"]').trigger('click')
    await settleAutosave()

    const profiles = (mockSave.mock.calls.at(-1)![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(Object.keys(profiles).sort()).toEqual(['work', 'work copy', 'work copy 2'])
  })

  it('refuses to create a second agent with a name that is already taken', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="name-input"]').setValue('work')
    await wrapper.find('[data-testid="model-input"]').setValue('m2')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    // Still one row, and the copy is NOT queued into the PUT body.
    expect(wrapper.findAll('[data-testid="agent-list"] > li').length).toBe(1)
    expect(wrapper.text()).toContain('already exists')
  })

  it('renaming an agent writes the new key and removes the stale one', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="name-input"]').setValue('day job')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await settleAutosave()

    const profiles = (mockSave.mock.calls.at(-1)![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(Object.keys(profiles)).toEqual(['day job'])
    expect(profiles['day job']!.model).toBe('m')
    expect(mockDeleteAgent).toHaveBeenCalledWith('work')
  })

  it('refuses to rename an agent a worker is still running', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    mockProfileInUse.mockResolvedValueOnce({
      name: 'work',
      running: 2,
      sessions: [
        { id: 's1', cwd: '/repo', sub_agent: false },
        { id: 'child', cwd: '/repo', sub_agent: true },
      ],
    })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="name-input"]').setValue('day job')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    // The modal stays open with the reason; the list and the disk are untouched.
    expect(wrapper.find('[data-testid="name-input"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('is running in 2 sessions')
    expect(wrapper.findAll('[data-testid="agent-list"] > li').length).toBe(1)
    expect(wrapper.find('[data-testid="agent-list"]').text()).toContain('work')
    expect(mockSave).not.toHaveBeenCalled()
    expect(mockDeleteAgent).not.toHaveBeenCalled()
  })

  it('allows the rename once nothing is running the agent', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="name-input"]').setValue('day job')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    expect(mockProfileInUse).toHaveBeenCalledWith('work')
    await settleAutosave()

    const profiles = (mockSave.mock.calls[0]![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(Object.keys(profiles)).toEqual(['day job'])
  })

  it('renaming an agent back to its stored name lands on one profile under that name', async () => {
    mockGet.mockResolvedValueOnce({ profiles: { work: { model: 'm' } } })
    mockSave.mockResolvedValue({ success: true })
    const wrapper = await mountAt('agents')

    const renameTo = async (to: string) => {
      await wrapper.find('[data-testid="edit-btn"]').trigger('click')
      await flushPromises()
      await wrapper.find('[data-testid="name-input"]').setValue(to)
      await wrapper.find('[data-testid="modal-save"]').trigger('click')
      await settleAutosave()
    }
    await renameTo('temp')
    await renameTo('work')

    const profiles = (mockSave.mock.calls.at(-1)![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(Object.keys(profiles)).toEqual(['work'])
    expect(profiles.work!.model).toBe('m')
  })

  it('a newly added agent is created enabled', async () => {
    mockGet.mockResolvedValueOnce({ profiles: {} })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('agents')

    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="name-input"]').setValue('fresh')
    await wrapper.find('[data-testid="model-input"]').setValue('m3')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()
    await settleAutosave()

    const profiles = (mockSave.mock.calls[0]![0] as Record<string, unknown>).profiles as Record<
      string,
      Record<string, unknown>
    >
    expect(profiles.fresh!.model).toBe('m3')
    expect(profiles.fresh!.enabled).toBe(true)
  })
})
