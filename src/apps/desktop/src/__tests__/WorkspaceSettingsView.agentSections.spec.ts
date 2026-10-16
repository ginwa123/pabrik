/** The wiring that makes the moved sections reachable at all. */
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import * as api from '../api'
import WorkspaceSettingsView from '../components/views/WorkspaceSettingsView.vue'
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

const mockGetWs = api.getWorkspaceConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>
const mockRegistry = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>

async function mountAt(section: string) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/app/:workspaceId/settings', name: 'workspace-settings', component: { template: '<div />' } },
    ],
  })
  await router.push({ path: '/app/ws_1/settings', query: { section } })
  await router.isReady()
  return mount(WorkspaceSettingsView, {
    global: {
      plugins: [router],
      stubs: {
        Teleport: true,
        SecretsSection: true,
        SkillsSettings: true,
        WorkspaceMemoriesSection: true,
      },
    },
  })
}

describe('WorkspaceSettingsView — the moved config sections', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockGetWs.mockReset()
    mockGetWs.mockResolvedValue({ active_profile: 'work' })
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

  for (const section of ['profiles', 'mcp', 'tools', 'evals'] as const) {
    it(`mounts the config editor for ?section=${section}, pointed at THIS workspace`, async () => {
      const wrapper = await mountAt(section)
      await flushPromises()

      // The editor, not one of the other sections.
      expect(wrapper.find('[data-testid="pabrik-settings"]').exists()).toBe(true)
      expect(wrapper.find(`[data-testid="${section}-section"]`).exists()).toBe(true)
      // ...reading the workspace config for the workspace in the URL. This is
      // the assertion that would fail if the view ever passed the default
      // (user-scope) source.
      expect(mockGetWs).toHaveBeenCalledWith('ws_1')
    })
  }

  it('does not mount the editor for a section that is not one of the four', async () => {
    const wrapper = await mountAt('overview')
    await flushPromises()

    expect(wrapper.find('[data-testid="overview-section"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pabrik-settings"]').exists()).toBe(false)
    // And it must not have gone looking for a workspace config it does not show.
    expect(mockGetWs).not.toHaveBeenCalled()
  })

  it('keeps ONE editor instance across a section switch, so edits survive', async () => {
    const wrapper = await mountAt('profiles')
    await flushPromises()
    const editorBefore = wrapper.findComponent({ name: 'PabrikConfigEditor' })
    expect(editorBefore.exists()).toBe(true)

    // Navigate the way the shell does: a query change on the same route.
    const router = wrapper.vm.$router
    await router.push({ path: '/app/ws_1/settings', query: { section: 'tools' } })
    await flushPromises()

    const editorAfter = wrapper.findComponent({ name: 'PabrikConfigEditor' })
    expect(editorAfter.exists()).toBe(true)
    // Same instance (same uid): a remount would silently discard whatever the
    // user had edited in the previous section.
    expect(editorAfter.vm.$.uid).toBe(editorBefore.vm.$.uid)
    // ...and the load did NOT happen again, which is the observable half of it.
    expect(mockGetWs).toHaveBeenCalledTimes(1)
  })
})
