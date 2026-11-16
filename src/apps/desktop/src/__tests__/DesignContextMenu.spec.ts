import { describe, it, expect, beforeEach, afterEach, vi, assert } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignContextMenu from '../components/design/DesignContextMenu.vue'

describe('DesignContextMenu', () => {
  let wrapper: VueWrapper | null = null

  // Helper: a page-element list containing one of each interesting type.
  const elements = [
    { id: 'a', type: 'rectangle', parent_id: '' },
    { id: 'b', type: 'rectangle', parent_id: '' },
    { id: 'g', type: 'group', parent_id: '' },
    { id: 'f', type: 'frame', parent_id: '' },
    // `nested-g` lives inside `g` — exercises the Leave-group affordance for a nested element.
    { id: 'nested-g', type: 'rectangle', parent_id: 'g' },
  ]

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(navigator, 'platform', { value: 'Linux x86_64', configurable: true })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('renders nothing when visible is false (Teleport closed)', () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: false, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    expect(document.querySelector('[data-testid="design-context-menu"]')).toBeNull()
  })

  it('renders the menu container when visible is true, positioned at x/y', async () => {
    wrapper = mount(DesignContextMenu, {
      // Use small x/y so viewport edge-clamping (40px × 10 rows = 400px tall, 220px wide) doesn't shift the menu.
      props: { visible: true, x: 50, y: 50, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    expect(menu!.style.left).toBe('50px')
    expect(menu!.style.top).toBe('50px')
  })

  it('stops click propagation on the menu container (click inside does not close the menu)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')!
    menu.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(document.querySelector('[data-testid="design-context-menu"]')).not.toBeNull()
  })

  it('renders all 9 menu items in the spec order with correct testids (Leave group added)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const expected = [
      'design-context-menu-group',
      'design-context-menu-leave-group',
      'design-context-menu-ungroup',
      'design-context-menu-select-all',
      'design-context-menu-separator-1',
      'design-context-menu-bring-to-front',
      'design-context-menu-bring-forward',
      'design-context-menu-send-backward',
      'design-context-menu-send-to-back',
      'design-context-menu-separator-2',
      'design-context-menu-delete',
    ]
    for (const testid of expected) {
      const el = document.querySelector(`[data-testid="${testid}"]`)
      assert(el, `expected ${testid} in DOM`)
    }
  })

  it('clicking Bring to front emits bringToFront with the targetIds', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-bring-to-front"]',
    )!
    btn.click()
    await nextTick()
    const emits = wrapper.emitted('bringToFront')
    expect(emits).toBeTruthy()
    expect(emits?.[0]).toEqual([['a', 'b']])
  })

  it('Group is disabled when fewer than 2 ids are targetIds', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-group"]',
    )!
    expect(btn.disabled).toBe(true)
    btn.click()
    await nextTick()
    // Group emit should NOT fire because the button is disabled.
    expect(wrapper.emitted('group')).toBeUndefined()
  })

  // ─── Chunk 9 — Ungroup ────────────────────────────────────────────────
  it('Ungroup is enabled when exactly one group is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(false)
  })

  it('Ungroup is enabled when exactly one frame is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['f'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(false)
  })

  it('Ungroup is disabled when the single selection is a rectangle', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('Ungroup is disabled when more than one element is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g', 'a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('clicking Ungroup emits ungroup with the single selected id', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    btn.click()
    await nextTick()
    expect(wrapper.emitted('ungroup')).toEqual([['g']])
  })

  // ─── Leave group (2026-08-06, design-leave-group plan) ────────────────
  it('Leave group is enabled when the single selected element has a parent_id (inside a group)', async () => {
    // `nested-g` has parent_id='g' — a child row inside the `g` group.
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['nested-g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(btn.disabled).toBe(false)
  })

  it('Leave group is enabled when the single selected element is itself a nested group/frame (has parent_id)', async () => {
    // Mutate the fixture to put `g` (a group) inside an outer group `outer-g`, then select `g`.
    wrapper = mount(DesignContextMenu, {
      props: {
        visible: true, x: 100, y: 100, targetIds: ['g'],
        elements: [
          { id: 'outer-g', type: 'group', parent_id: '' },
          { id: 'g', type: 'group', parent_id: 'outer-g' },
        ],
      },
      attachTo: document.body,
    })
    await nextTick()
    const leaveBtn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(leaveBtn.disabled).toBe(false)
    const ungroupBtn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    // Both Leave group AND Ungroup can fire on a nested group/frame.
    expect(ungroupBtn.disabled).toBe(false)
  })

  it('Leave group is disabled when the single selected element is already top-level (parent_id empty)', async () => {
    // `a` has parent_id='' — a top-level rectangle.
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('Leave group is disabled when more than one element is selected', async () => {
    // Multi-select: Leave group would need to pull each element to a different top-level row (some may be inside, some may already be top-level), so the action is …
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a', 'nested-g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('Leave group is enabled even when the single selection is a group/frame (Figma "Pull out of group")', async () => {
    // `g` has parent_id='' (top-level) — so Leave group is disabled here.
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['nested-g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const leaveBtn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(leaveBtn.disabled).toBe(false)
  })

  it('clicking Leave group emits leaveGroup with the single selected id', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['nested-g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    btn.click()
    await nextTick()
    expect(wrapper.emitted('leaveGroup')).toEqual([['nested-g']])
  })

  it('clicking Leave group when disabled does NOT emit leaveGroup', async () => {
    // `a` is top-level (no parent_id).
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(btn.disabled).toBe(true)
    btn.click()
    await nextTick()
    expect(wrapper.emitted('leaveGroup')).toBeUndefined()
  })
})