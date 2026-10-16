/** Regression tests for the WorktreeMenu dropdown component. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import WorktreeMenu from '../components/workspace/WorktreeMenu.vue'

// Helper: mount the menu with the right props for each test. Centralizing
// the prop shape keeps the tests focused on the behavior under test, not
// on Vue's prop-validation ceremony.
function mountMenu(hasWorktree: boolean) {
  return mount(WorktreeMenu, {
    props: { hasWorktree, branch: 'main', status: 'clean' },
  })
}

describe('WorktreeMenu — worktree-bound (hasWorktree=true)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the three worktree-bound menu items with the correct data-testids', () => {
    wrapper = mountMenu(true)
    // The component uses the `data-testid` attribute as the contract for
    // ChatView's click handlers — if any of these IDs change, the
    // parent wiring silently breaks.
    expect(wrapper.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-clear"]').exists()).toBe(true)
    // The no-worktree-only items must NOT be present.
    expect(wrapper.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(false)
  })

  it('"Create a PR" is disabled and emits nothing on click', async () => {
    wrapper = mountMenu(true)
    const btn = wrapper.find('[data-testid="worktree-menu-create-pr"]')
    expect(btn.attributes('disabled')).toBeDefined()
    await btn.trigger('click')
    expect(wrapper.emitted('create-pr')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('"View in folder" is disabled and emits nothing on click', async () => {
    wrapper = mountMenu(true)
    const btn = wrapper.find('[data-testid="worktree-menu-view-folder"]')
    expect(btn.attributes('disabled')).toBeDefined()
    await btn.trigger('click')
    expect(wrapper.emitted('view-folder')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('"Clear worktree" is disabled and emits nothing on click', async () => {
    wrapper = mountMenu(true)
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true)
    const btn = wrapper.find('[data-testid="worktree-menu-clear"]')
    expect(btn.attributes('disabled')).toBeDefined()
    await btn.trigger('click')
    // Disabled button must not reach the confirm dialog nor emit.
    expect(confirmSpy).not.toHaveBeenCalled()
    expect(wrapper.emitted('clear')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('clicking outside the menu emits close', async () => {
    wrapper = mountMenu(true)
    // The component registers a document-level `click` listener in onMounted (with a 0ms setTimeout
    // so the click that OPENED the menu doesn't immediately close it). After that tick, dispatching
    // a click on a target OUTSIDE the menu must emit `close`.
    await new Promise((r) => setTimeout(r, 5))

    // Build a target node that is NOT inside `menuRef`. The menu's
    // root <div> contains the 3 buttons, so clicking on the body
    // element works as an "outside" target.
    const outsideEl = document.body
    document.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))

    // The component checks `menuRef.value.contains(e.target as Node)`.
    // `document.body` is the dispatch target of the document-level
    // listener; if the listener is registered correctly, this fires.
    expect(wrapper.emitted('close')).toBeTruthy()
    // Reference `outsideEl` so TS/lint don't complain about an unused
    // variable (the dispatch goes through document, not the element,
    // because of how bubbling lands on the document).
    void outsideEl
  })
})

describe('WorktreeMenu — no-worktree (hasWorktree=false)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the two no-worktree menu items with the correct data-testids', () => {
    wrapper = mountMenu(false)
    expect(wrapper.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(true)
    // The worktree-bound-only items must NOT be present.
    expect(wrapper.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="worktree-menu-clear"]').exists()).toBe(false)
  })

  it('"Open in folder" is disabled and emits nothing on click', async () => {
    wrapper = mountMenu(false)
    const btn = wrapper.find('[data-testid="worktree-menu-view-folder"]')
    expect(btn.attributes('disabled')).toBeDefined()
    await btn.trigger('click')
    expect(wrapper.emitted('view-folder')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('clicking "Refresh status" emits refresh and close', async () => {
    wrapper = mountMenu(false)
    await wrapper.find('[data-testid="worktree-menu-refresh"]').trigger('click')
    expect(wrapper.emitted('refresh')).toBeTruthy()
    expect(wrapper.emitted('refresh')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })
})

describe('WorktreeMenu — header', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('shows the branch name in the header', () => {
    wrapper = mountMenu(true)
    expect(wrapper.text()).toContain('main')
  })

  it('falls back to "detached" when branch is empty', () => {
    wrapper = mount(WorktreeMenu, {
      props: { hasWorktree: false, branch: '', status: 'clean' },
    })
    expect(wrapper.text()).toContain('detached')
  })
})
