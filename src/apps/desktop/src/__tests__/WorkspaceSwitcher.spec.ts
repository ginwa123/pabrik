/** Behavioural tests for the header WorkspaceSwitcher dropdown (plan:
 * docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md). Props-driven component — no
 * store/router needed. */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'

import WorkspaceSwitcher from '../components/workspace/WorkspaceSwitcher.vue'
import type { Workspace } from '../stores/workspaces'

const makeWs = (id: string, name: string, itemCount = 0): Workspace =>
  ({
    id,
    name,
    icon: '📁',
    expanded: false,
    items: Array.from({ length: itemCount }, (_, i) => ({ id: `${id}_item_${i}` })),
  }) as unknown as Workspace

const WSS = [makeWs('ws_a', 'agentic coding', 3), makeWs('ws_b', 'kabelweb', 1)]

const mountSwitcher = (props: Partial<InstanceType<typeof WorkspaceSwitcher>['$props']> = {}) =>
  mount(WorkspaceSwitcher, {
    props: { workspaces: WSS, activeWorkspaceId: 'ws_a', ...props },
  })

describe('WorkspaceSwitcher', () => {
  it('shows the active workspace name on the trigger', () => {
    const wrapper = mountSwitcher()
    expect(wrapper.find('[data-testid="workspace-switcher-trigger"]').text()).toContain(
      'agentic coding',
    )
  })

  it('falls back to "Select workspace" when nothing is active', () => {
    const wrapper = mountSwitcher({ activeWorkspaceId: null })
    expect(wrapper.find('[data-testid="workspace-switcher-trigger"]').text()).toContain(
      'Select workspace',
    )
  })

  it('shows "Select workspace" for an unknown active id', () => {
    const wrapper = mountSwitcher({ activeWorkspaceId: 'ws_gone' })
    expect(wrapper.find('[data-testid="workspace-switcher-trigger"]').text()).toContain(
      'Select workspace',
    )
  })

  it('opens the panel on trigger click and lists every workspace', async () => {
    const wrapper = mountSwitcher()
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)

    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')

    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="workspace-switcher-option-ws_a"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="workspace-switcher-option-ws_b"]').exists()).toBe(true)
    // Active row carries the check.
    expect(wrapper.find('[data-testid="workspace-switcher-active-check"]').exists()).toBe(true)
  })

  it('clicking an option emits select with its id and closes the panel', async () => {
    const wrapper = mountSwitcher()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-option-ws_b"]').trigger('click')

    expect(wrapper.emitted('select')).toEqual([['ws_b']])
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
  })

  it('rename hover action emits renameWorkspace (id, name) — never select', async () => {
    const wrapper = mountSwitcher()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-rename-ws_b"]').trigger('click')

    expect(wrapper.emitted('renameWorkspace')).toEqual([['ws_b', 'kabelweb']])
    expect(wrapper.emitted('select')).toBeUndefined()
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
  })

  it('delete hover action emits deleteWorkspace — never select', async () => {
    const wrapper = mountSwitcher()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-delete-ws_a"]').trigger('click')

    expect(wrapper.emitted('deleteWorkspace')).toEqual([['ws_a']])
    expect(wrapper.emitted('select')).toBeUndefined()
  })

  it('"+ New workspace" emits addWorkspace and closes', async () => {
    const wrapper = mountSwitcher()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-add-workspace"]').trigger('click')

    expect(wrapper.emitted('addWorkspace')).toHaveLength(1)
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
  })

  it('keyboard: Enter opens, ArrowDown moves the cursor, Enter selects it', async () => {
    const wrapper = mountSwitcher()
    const trigger = wrapper.find('[data-testid="workspace-switcher-trigger"]')

    await trigger.trigger('keydown', { key: 'Enter' })
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(true)

    // Cursor starts on the active workspace (ws_a); move to ws_b.
    await trigger.trigger('keydown', { key: 'ArrowDown' })
    await trigger.trigger('keydown', { key: 'Enter' })

    expect(wrapper.emitted('select')).toEqual([['ws_b']])
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
  })

  it('keyboard: Escape closes the panel', async () => {
    const wrapper = mountSwitcher()
    const trigger = wrapper.find('[data-testid="workspace-switcher-trigger"]')
    await trigger.trigger('keydown', { key: 'Enter' })
    await trigger.trigger('keydown', { key: 'Escape' })
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
  })

  it('mousedown outside the switcher closes the panel', async () => {
    const wrapper = mountSwitcher()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(true)

    document.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await wrapper.vm.$nextTick()

    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('shows an empty message when there are no workspaces', async () => {
    const wrapper = mountSwitcher({ workspaces: [], activeWorkspaceId: null })
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')

    expect(wrapper.find('[data-testid="workspace-switcher-empty"]').exists()).toBe(true)
    // Creation entry stays reachable even when the list is empty.
    expect(wrapper.find('[data-testid="workspace-switcher-add-workspace"]').exists()).toBe(true)
  })
})

describe('WorkspaceSwitcher collapsed mode', () => {
  it('renders the monogram trigger and teleports the panel to <body>', async () => {
    const wrapper = mount(WorkspaceSwitcher, {
      props: { workspaces: WSS, activeWorkspaceId: 'ws_a', collapsed: true },
      attachTo: document.body,
    })
    const monogram = wrapper.find('[data-testid="workspace-switcher-monogram"]')
    expect(monogram.exists()).toBe(true)
    // 'agentic coding' → 'A' (algorithm moved from Sidebar's tiles).
    expect(monogram.text()).toBe('A')

    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.vm.$nextTick()

    // Teleported OUT of the component tree — lives on document.body
    // so the panel escapes the narrow collapsed sidebar's overflow.
    const panel = document.body.querySelector('[data-testid="workspace-switcher-panel"]')
    expect(panel).not.toBeNull()
    expect(wrapper.find('[data-testid="workspace-switcher-panel"]').exists()).toBe(false)

    // Option clicks still land through the teleported panel.
    const option = panel!.querySelector('[data-testid="workspace-switcher-option-ws_b"]')
    option!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('select')).toEqual([['ws_b']])

    wrapper.unmount()
    document.body.innerHTML = ''
  })
})
