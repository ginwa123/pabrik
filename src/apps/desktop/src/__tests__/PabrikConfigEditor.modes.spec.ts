/** The editor's two VIEW modes and its two SCOPES. Modes: `Form` (the section forms) and `JSON`
 * (the whole config as raw text). Scopes: the user config and one workspace's overlay, which is
 * what `PabrikConfigSource` abstracts. */

/** Both are pinned here rather than in the orchestrator spec because both are about the editor
 * being the SAME component in two situations, and the failure modes are quiet: an invalid JSON
 * paste that reports success, or a workspace page that writes to the user config. */
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import * as api from '../api'
import PabrikConfigEditor from '../components/pabrik/PabrikConfigEditor.vue'
import { workspaceConfigSource } from '../helpers/configSource'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getPabrikConfig: vi.fn(),
  savePabrikConfig: vi.fn(),
  deleteProfile: vi.fn(),
  getWebStatus: vi.fn(),
  getAgentToolsRegistry: vi.fn(),
  getWorkspaceConfig: vi.fn(),
  saveWorkspaceConfig: vi.fn(),
}))

const mockGet = api.getPabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.savePabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>
const mockRegistry = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>
const mockGetWs = api.getWorkspaceConfig as unknown as ReturnType<typeof vi.fn>
const mockSaveWs = api.saveWorkspaceConfig as unknown as ReturnType<typeof vi.fn>

const WORKSPACE_TABS = ['profiles', 'mcp', 'tools', 'evals'] as const

/** A router already sitting on `/app/settings` (plus any query). */
async function makeRouter(query: Record<string, string> = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/app/settings', component: { template: '<div />' } }],
  })
  await router.push({ path: '/app/settings', query })
  await router.isReady()
  return router
}

function mountEditor(options: Parameters<typeof mount>[1] = {}) {
  return mount(PabrikConfigEditor, {
    ...options,
    // `...options?.global` with no `?? {}`: spreading a falsy value adds
    // nothing, so the fallback is dead weight (unicorn/no-useless-fallback-in-spread).
    global: { stubs: { Teleport: true }, ...options?.global },
  })
}

describe('PabrikConfigEditor — JSON mode', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockGet.mockReset()
    mockSave.mockReset()
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
    mockRegistry.mockReset()
    mockRegistry.mockResolvedValue({ tools: [] })
    mockGetWs.mockReset()
    mockSaveWs.mockReset()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('opens on the form and shows the config as pretty-printed JSON when asked', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work', tools: ['read_file'] })
    const wrapper = mountEditor()
    await flushPromises()

    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(false)

    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(true)
    const textarea = wrapper.find('[data-testid="config-json-textarea"]')
    expect(textarea.exists()).toBe(true)
    // Pretty-printed and complete: what the user reads is what the config holds.
    expect((textarea.element as HTMLTextAreaElement).value).toContain('"active_profile": "work"')
    expect((textarea.element as HTMLTextAreaElement).value).toContain('"read_file"')

    // And back.
    await wrapper.find('[data-testid="mode-form"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(false)
  })

  it('blocks an invalid paste: Apply disabled, reason shown, nothing applied', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    const wrapper = mountEditor()
    await flushPromises()
    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()

    const textarea = wrapper.find('[data-testid="config-json-textarea"]')
    await textarea.setValue('{ "active_profile": ')
    await flushPromises()

    expect(wrapper.find('[data-testid="config-json-error"]').exists()).toBe(true)
    const apply = wrapper.find('[data-testid="config-json-apply"]')
    expect((apply.element as HTMLButtonElement).disabled).toBe(true)

    // Clicking Form must NOT leave the mode with unusable text on screen -
    // leaving would silently discard the edit the user is mid-way through.
    await wrapper.find('[data-testid="mode-form"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(true)

    // A JSON array is not a config either.
    await textarea.setValue('[1, 2, 3]')
    await flushPromises()
    expect(wrapper.find('[data-testid="config-json-error"]').exists()).toBe(true)
    expect((wrapper.find('[data-testid="config-json-apply"]').element as HTMLButtonElement).disabled).toBe(true)
  })

  it('applies valid JSON to the config, which marks it dirty and reaches the save body', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work', tools: ['read_file'] })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mountEditor()
    await flushPromises()
    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="config-json-textarea"]').setValue(
      JSON.stringify({ active_profile: 'work', tools: ['read_file', 'bash'] }),
    )
    await flushPromises()
    await wrapper.find('[data-testid="config-json-apply"]').trigger('click')
    await flushPromises()

    // Applying is an EDIT, not a save: the bar must appear so the user can
    // still choose to discard it. (A `setConfig` here would have re-snapshotted
    // and hidden the bar - that is the trap this pins.)
    expect(wrapper.find('[data-testid="save-btn"]').exists()).toBe(true)

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const body = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(body.tools).toEqual(['read_file', 'bash'])
  })

  it('refuses to SAVE with unapplied, invalid JSON on screen', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    const wrapper = mountEditor()
    await flushPromises()
    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="config-json-textarea"]').setValue('{ oops')
    await flushPromises()

    // Make the config dirty through the JSON path's Apply... which is blocked, so dirty must come
    // from somewhere else to expose the trap: apply valid text, then break it again. The bar is up,
    // the text is unusable, and a naive Save would report success while dropping the text.
    await wrapper.find('[data-testid="config-json-textarea"]').setValue('{"active_profile":"work","tools":[]}')
    await flushPromises()
    await wrapper.find('[data-testid="config-json-apply"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="config-json-textarea"]').setValue('{ oops')
    await flushPromises()

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()

    expect(mockSave).not.toHaveBeenCalled()
    expect(wrapper.emitted('notification')?.at(-1)).toEqual(['Fix the JSON before saving', 'error'])
  })

  it('deep-links ?mode=json and writes the param on a mode switch', async () => {
    const router = await makeRouter({ mode: 'json' })
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    const wrapper = mountEditor({ global: { plugins: [router], stubs: { Teleport: true } } })
    await flushPromises()

    // Mount restores the view from the URL alone.
    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(true)

    await wrapper.find('[data-testid="mode-form"]').trigger('click')
    await flushPromises()
    // The default mode is stripped, so the URL stays clean.
    expect(router.currentRoute.value.query.mode).toBeUndefined()
    expect(wrapper.find('[data-testid="config-json-panel"]').exists()).toBe(false)

    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.mode).toBe('json')
  })
})

describe('PabrikConfigEditor — workspace scope', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockGet.mockReset()
    mockSave.mockReset()
    mockGetWs.mockReset()
    mockSaveWs.mockReset()
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
    mockRegistry.mockReset()
    mockRegistry.mockResolvedValue({ tools: [] })
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('accepts only the four moved sections, and General is not one of them', async () => {
    // The editor no longer owns a nav, so "which sections does it offer?" is
    // observable through what it RENDERS for a given `?section=`: the first
    // entry is the fallback, and a section outside the list falls back to it
    // rather than rendering a pane that belongs to the user scope.
    // A profile, so ProfilesSection renders its list rather than its empty
    // state - `profile-list` is the anchor unique to that section.
    mockGetWs.mockResolvedValueOnce({ active_profile: 'work', profiles: { work: { model: 'm' } } })
    const wrapper = mountEditor({
      props: { source: workspaceConfigSource('ws_1'), sections: [...WORKSPACE_TABS] },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="profile-list"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pabrik-general-section"]').exists()).toBe(false)

    // `general` is deliberately NOT in WORKSPACE_AGENT_SECTIONS (decision D4),
    // so asking for it lands back on the first offered section.
    const router = await makeRouter({ section: 'general' })
    mockGetWs.mockResolvedValueOnce({ active_profile: 'work', profiles: { work: { model: 'm' } } })
    const withGeneral = mountEditor({
      props: { source: workspaceConfigSource('ws_1'), sections: [...WORKSPACE_TABS] },
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()

    expect(withGeneral.find('[data-testid="pabrik-general-section"]').exists()).toBe(false)
    expect(withGeneral.find('[data-testid="profile-list"]').exists()).toBe(true)
  })

  it('reads and writes through the workspace endpoints, never the user ones', async () => {
    // Section comes from the URL: that is how the workspace scope actually
    // navigates (the settings shell owns the nav and writes `?section=`).
    const router = await makeRouter({ section: 'tools' })
    mockGetWs.mockResolvedValueOnce({ active_profile: 'work', tools: ['read_file'] })
    mockSaveWs.mockResolvedValueOnce({ success: true })
    // `set_git_worktree` is NOT a built-in default, so checking it is a real
    // edit; checking a default would leave the config clean and hide the bar.
    mockRegistry.mockResolvedValue({
      tools: [{ name: 'set_git_worktree', description: 'Create a git worktree and bind it' }],
    })
    const wrapper = mountEditor({
      props: {
        source: workspaceConfigSource('ws_1'),
        sections: [...WORKSPACE_TABS],
      },
      global: { plugins: [router], stubs: { Teleport: true } },
    })
    await flushPromises()

    // Read: the workspace endpoint, and NOT the user-scope one. This is the
    // assertion that would fail if the extraction ever fell back to the
    // default source - which would edit the wrong config entirely.
    expect(mockGetWs).toHaveBeenCalledWith('ws_1')
    expect(mockGet).not.toHaveBeenCalled()

    await wrapper.find('[data-testid="row-set_git_worktree"] input').setValue(true)
    await flushPromises()

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSaveWs).toHaveBeenCalledTimes(1)
    expect(mockSave).not.toHaveBeenCalled()
    expect(mockSaveWs.mock.calls[0]![0]).toBe('ws_1')
  })

  it('owns no section nav of its own — the settings shell does', async () => {
    mockGetWs.mockResolvedValueOnce({})
    const wrapper = mountEditor({
      props: { source: workspaceConfigSource('ws_1'), sections: [...WORKSPACE_TABS] },
    })
    await flushPromises()

    // A second nav inside the editor would be a control that can disagree with
    // the URL the shell writes.
    expect(wrapper.find('button[role="tab"]').exists()).toBe(false)
    // ...but the mode toggle stays: the raw view is not a section.
    expect(wrapper.find('[data-testid="mode-json"]').exists()).toBe(true)
  })

  it('tells the user that only the workspace-scoped settings are stored here', async () => {
    mockGetWs.mockResolvedValueOnce({ active_profile: 'work' })
    const wrapper = mountEditor({
      props: { source: workspaceConfigSource('ws_1'), sections: [...WORKSPACE_TABS] },
    })
    await flushPromises()
    await wrapper.find('[data-testid="mode-json"]').trigger('click')
    await flushPromises()

    // The JSON shown is the EFFECTIVE config, which includes user-level keys
    // that a save from here cannot change. Saying so is the difference between
    // a helpful editor and one that silently drops what you typed.
    expect(wrapper.find('[data-testid="config-json-panel"]').text()).toContain(
      'Only the settings that live in Workspace settings',
    )
  })
})
