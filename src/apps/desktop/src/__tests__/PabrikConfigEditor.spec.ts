import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import * as api from '../api'
import PabrikConfigEditor from '../components/pabrik/PabrikConfigEditor.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getPabrikConfig: vi.fn(),
  savePabrikConfig: vi.fn(),
  deleteProfile: vi.fn(),
  // Plan 2026-09-10-web-launch-toggle: browser-mode status for the
  // General tab URL pill. Resolves null by default (pill waiting hint).
  getWebStatus: vi.fn(),
  // Tools tab catalog — consumed by the agentTools store inside
  // ToolsSection; only fetched when the Tools tab mounts.
  getAgentToolsRegistry: vi.fn(),
}))

const mockGet = api.getPabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.savePabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>
const mockRegistry = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>

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

  it('never mounts the global SubAgentsSection (per-profile lists are the only editor)', async () => {
    // Plan 2026-09-04-subagents-per-profile regression: the global
    // `subAgentsList` + `SubAgentsSection` mount are gone. Even with a
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

  it('loads the config on mount and shows the Profiles section', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'gpt-4o-mini', base_url: 'https://x' } },
    })
    const wrapper = await mountAt('profiles')
    expect(mockGet).toHaveBeenCalled()
    // The profile name is visible. (This used to assert `toContain('work')`
    // while landing on GENERAL, so it passed on the word "worktree" in an
    // unrelated registry blurb - a green test that proved nothing.)
    expect(wrapper.find('[data-testid="profile-list"]').text()).toContain('work')
  })

  it('does not send top-level LLM defaults in the PUT body (config-simplify)', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm1' } },
      notify_on_complete: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    // Make a real edit so the save bar appears. Switching tabs used to be enough BY ACCIDENT - the
    // Profiles section emitted an update while hydrating, which happened to mark the config dirty.
    // This test failed for exactly that reason (reproduced on the unmodified component), so it now
    // makes the edit its assertion is actually about.
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    await flushPromises()
    expect(wrapper.find('[data-testid="save-btn"]').exists()).toBe(true)
    // Save the profile-only config.
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
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
  it('routes a sub-agent add through a profile scope to the right profile', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: {
        work: {
          model: 'm',
          base_url: '',
          thinking: 'auto',
          temperature: 'auto',
          url_style: 'openai',
          api_key: '',
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
    const wrapper = await mountAt('profiles')

    // 'work' is expanded by default, so open + Add sub-agent directly.
    await wrapper.find('[data-testid="add-sub-agent-btn-work"]').trigger('click')
    await flushPromises()

    // The sub-agent modal should be open. Fill in name + save.
    const nameInput = wrapper.find('[data-testid="name-input"]')
    expect(nameInput.exists()).toBe(true)
    await nameInput.setValue('coder')
    await wrapper.find('[data-testid="model-input"]').setValue('claude-haiku-4-5')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    // After save, click Save changes and verify the sub-agent landed
    // on 'work' (not 'home' or the top-level list).
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    const profiles = savedConfig.profiles as Record<string, Record<string, unknown>>
    expect(profiles.work).toBeDefined()
    expect(profiles.home).toBeDefined()
    expect((profiles.work!.sub_agents as Array<{ name: string }>)[0]!.name).toBe('coder')
    // The 'home' profile never received a sub-agent, so its
    // sub_agents should be an empty array (or undefined).
    expect((profiles.home!.sub_agents as unknown[] | undefined)?.length ?? 0).toBe(0)
    // No top-level sub_agents list is ever sent (per-profile only).
    const topLevel = (savedConfig as Record<string, unknown>).sub_agents as
      Array<{ name: string }> | undefined
    expect(topLevel ?? []).not.toContainEqual(expect.objectContaining({ name: 'coder' }))
  })

  // ─── Clear active profile (plan 2026-08-06-reset-active-profile) ──
  // Plan: Settings → Profiles → Reset button next to the active pill
  // emits `clearActive` → orchestrator calls savePabrikConfig with
  // `active_profile: ""` (empty string) → the backend handler at
  // `pabrik_config_put.zig:246-252` interprets empty as "clear" and
  // sets `config_json.active_profile = null` on disk → the cascade
  // falls through to top-level config for every chat / task. The
  // button is gated on `activeProfile !== null` (a no-op when no
  // active is set).
  //
  // Why empty string (not `undefined`)?
  // Pre-fix the frontend sent `active_profile: undefined`, which JSON
  // serialisation strips to no key in the PUT body. The backend's
  // `?[]const u8` type couldn't distinguish "key absent" from
  // "key: null" — both yielded `None` and the handler skipped the
  // field. Using `undefined` left the user's "Set active" default
  // in place (the Reset button silently failed). The empty-string
  // sentinel works within the existing wire contract — the handler
  // already maps `ap.len == 0` to "clear" exactly for this purpose.
  it('saves active_profile: "" when the Reset button is clicked', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' }, home: { model: 'm2' } },
      active_profile: 'work',
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('profiles')

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
    const wrapper = await mountAt('profiles')
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
    const wrapper = await mountAt('profiles')
    await flushPromises()
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')

    // After the failed save, the local activeProfile should still
    // reflect the original value (rolled back from the optimistic null).
    expect(wrapper.text()).toContain('work')
    // And an error notification should fire.
    expect(wrapper.emitted('notification')?.some((e) => e[1] === 'error')).toBe(true)
  })

  // ─── General tab (plan 2026-08-25-notify-on-error-and-retry-ms-in-settings) ──
  //
  // Three operational settings live in the General tab:
  //   - `notify_on_complete` (existing config.json field)
  //   - `notify_on_error` (new field added by this plan)
  //   - `retry_delay_ms` (existing config.json field)
  //
  // Each one must (a) hydrate from the API response, (b) flip the
  // dirty pill when the user changes it, (c) round-trip through the
  // PUT body on save.
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

  it('toggling notify_on_error in the General tab flips dirty=true and round-trips through save', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // The save bar should be hidden (dirty=false on first load).
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)

    // Toggle notify_on_error ON.
    const toggle = wrapper.find('[data-testid="toggle-notify-on-error"]')
    await toggle.setValue(true)
    await flushPromises()

    // Now the dirty pill should appear.
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)

    // Click Save — the PUT body must carry notify_on_error: true.
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.notify_on_error).toBe(true)
    // The other operational settings should also be in the body
    // (syncToConfig writes them through unconditionally — now four).
    expect(savedConfig.notify_on_complete).toBe(false)
    expect(savedConfig.retry_delay_ms).toBe(0)
    expect(savedConfig.web_launch_enabled).toBe(false)
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
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
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
    // Toggling ONLY `notify_on_error` must still surface the other unchanged fields in the PUT
    // body.
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

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
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
      await wrapper.find('[data-testid="save-btn"]').trigger('click')
      await flushPromises()

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

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
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

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
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

  it('checking a tool flips dirty and round-trips tools through the PUT body', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = await mountAt('tools')

    // Untouched checklist (null) → nothing to write, save bar hidden.
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)

    // set_git_worktree is not in the built-in defaults — checking it
    // writes the full explicit list (defaults ∩ registry + it).
    await wrapper.find('[data-testid="row-set_git_worktree"] input').setValue(true)
    await flushPromises()
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.tools).toEqual(['command', 'glob', 'set_git_worktree'])
  })

  it('mounts the save bar ABOVE the scrollable content, not below it', async () => {
    // The bar used to be the last child of the editor, so the only save/reset controls sat below a
    // section the user has to scroll through. It is now the first thing after the Form/JSON toggle,
    // which is what keeps the actions reachable from any scroll position.
    // Asserted on DOM ORDER, not on a class: the bar is a `shrink-0` flex item OUTSIDE the `flex-1
    // overflow-y-auto` region, so `sticky` is a no-op there and the placement is decided purely by
    // where it is mounted. A class assertion would pass on a bar still at the bottom.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Make a real edit so the bar renders at all.
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await flushPromises()

    const bar = wrapper.find('[data-testid="save-bar"]')
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
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig).not.toHaveProperty('tools')
    expect(savedConfig.notify_on_error).toBe(true)
  })
})
