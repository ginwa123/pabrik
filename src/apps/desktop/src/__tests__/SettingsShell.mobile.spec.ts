import { h } from 'vue'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { beforeEach, describe, expect, it } from 'vitest'

import SettingsShell from '../components/settings/SettingsShell.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_1 = { id: 'ws_1', name: 'Acme', icon: '', items: [], expanded: false }

async function makeRouter(path: string): Promise<Router> {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/app/settings', component: { template: '<div />' } },
      { path: '/app/:workspaceId/settings', component: { template: '<div />' } },
    ],
  })
  await router.push({ path })
  await router.isReady()
  return router
}

async function renderShell(mobile: boolean): Promise<VueWrapper> {
  const router = await makeRouter('/app/ws_1/settings')
  return mount(SettingsShell, {
    props: { scope: 'workspace' as const, workspaceId: 'ws_1', mobile },
    global: { plugins: [router] },
    slots: {
      default: ({ section }: { section: string }) =>
        h('div', { 'data-testid': 'slot-section' }, section),
    },
  })
}

describe('SettingsShell on a phone', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    useWorkspacesStore().workspaces = [WS_1]
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('reports the phone layout so the rail can become a scrolling row of tabs', async () => {
    const wrapper = await renderShell(true)
    expect(wrapper.get('[data-testid="settings-shell"]').attributes('data-layout')).toBe('mobile')
    wrapper.unmount()
  })

  it('keeps every section reachable — nothing is dropped to save width', async () => {
    const wrapper = await renderShell(true)
    const nav = wrapper.get('nav')
    expect(nav.findAll('button').map((b) => b.attributes('data-testid'))).toContain(
      'settings-nav-overview',
    )
    expect(nav.findAll('button')).toHaveLength(11)
    wrapper.unmount()
  })

  it('still switches the panel when a section tab is picked', async () => {
    const wrapper = await renderShell(true)
    expect(wrapper.get('[data-testid="slot-section"]').text()).toBe('overview')
    await wrapper.get('[data-testid="settings-nav-secrets"]').trigger('click')
    await flushPromises()
    expect(wrapper.get('[data-testid="slot-section"]').text()).toBe('secrets')
    wrapper.unmount()
  })

  it('keeps the scope switch, because it is the only way between user and workspace settings', async () => {
    const wrapper = await renderShell(true)
    expect(wrapper.find('[data-testid="settings-scope-user"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="settings-scope-workspace"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('keeps the back affordance, which is the way out of a full-screen surface', async () => {
    const wrapper = await renderShell(true)
    expect(wrapper.find('[data-testid="settings-back"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

describe('SettingsShell on a desktop', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    useWorkspacesStore().workspaces = [WS_1]
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('reports the desktop layout', async () => {
    const wrapper = await renderShell(false)
    expect(wrapper.get('[data-testid="settings-shell"]').attributes('data-layout')).toBe('desktop')
    wrapper.unmount()
  })
})
