import { mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import PabrikTabStrip from '../components/pabrik/PabrikTabStrip.vue'
import { makeLocalStorageStub } from './helpers'

/**
 * Test pattern: PabrikTabStrip is a controlled component. Clicking a
 * tab emits `update:modelValue`; the parent (PabrikConfigEditor.vue) is
 * expected to update the bound prop. The component's `watch` on
 * `modelValue` then writes to localStorage. To simulate this in
 * tests, we react to the emit by calling `wrapper.setProps(...)`.
 */

describe('PabrikTabStrip', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('renders all 5 tab labels in order: General / Profiles / MCP Servers / Tools / Skill Evals (no Sub-agents)', () => {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // General tab is FIRST. Tab order matters — operational settings
    // (notification toggles + retry delay) belong at the top. The
    // Tools tab sits after MCP Servers (plan
    // 2026-09-22-tools-menu-config-default-tools). Skill Evals is
    // LAST — it is the switch for the `run_skill_eval` tool.
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    // Plan 2026-09-04-subagents-per-profile: global Sub-agents tab removed.
    expect(buttons.map((b) => b.text().trim())).toEqual([
      'General',
      'Profiles',
      'MCP Servers',
      'Tools',
      'Skill Evals',
    ])
  })

  it('does NOT render the Compaction or Defaults tabs', () => {
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.some((b) => b.text().trim() === 'Compaction')).toBe(false)
    expect(buttons.some((b) => b.text().trim() === 'Defaults')).toBe(false)
  })

  it('emits update:modelValue when a tab is clicked', async () => {
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(5)
    await buttons[2]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['mcp'])
  })

  it('emits "tools" when the Tools tab is clicked', async () => {
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    await buttons[3]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['tools'])
  })

  it('marks the active tab with aria-selected=true', () => {
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'mcp' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(5)
    expect(buttons[0]!.attributes('aria-selected')).toBe('false')
    expect(buttons[2]!.attributes('aria-selected')).toBe('true')
    expect(buttons[3]!.attributes('aria-selected')).toBe('false')
  })

  it('persists the active tab to localStorage when the modelValue prop changes', async () => {
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    // Simulate the parent applying v-model after the click.
    await wrapper.setProps({ modelValue: 'mcp' })
    expect(localStorage.getItem('pabrik-settings-active-tab')).toBe('mcp')
  })

  it('emits update:modelValue on mount to restore the active tab from localStorage', () => {
    localStorage.setItem('pabrik-settings-active-tab', 'mcp')
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'general' },
    })
    // The onMounted hook fires the update so the parent picks up
    // the saved tab — but only when no `?section=` deep link owns
    // the selection (see the next test).
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['mcp'])
  })

  it('does NOT restore from localStorage when the URL carries a valid ?section=', async () => {
    // A deep link like /app/settings?section=tools must survive
    // mount: restoring 'mcp' from localStorage would clobber the
    // linked tab (and, via the parent's setter, rewrite the URL).
    localStorage.setItem('pabrik-settings-active-tab', 'mcp')
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
    })
    await router.push({ path: '/app/settings', query: { section: 'tools' } })
    await router.isReady()
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'tools' },
      global: { plugins: [router] },
    })
    expect(wrapper.emitted('update:modelValue')).toBeUndefined()
    expect(localStorage.getItem('pabrik-settings-active-tab')).toBe('mcp')
  })

  it('emits "general" when the General tab is clicked', async () => {
    // Explicit test for the FIRST tab — lock in the wire value so a
    // future rename doesn't silently break the parent (which uses
    // this exact string in the type Tab = 'general' | ...).
    const wrapper = mount(PabrikTabStrip, {
      props: { modelValue: 'profiles' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(5)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['general'])
  })
})
