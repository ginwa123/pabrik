import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { defineComponent, nextTick } from 'vue'
import { useContextMenu } from '../composables/useContextMenu'

/**
 * Root-cause reproduction for "the right-click context menu sometimes
 * suddenly closes".
 *
 * `useContextMenu` used to attach a capture-phase `wheel` listener and a
 * capture-phase `scroll` listener that BOTH called `close()`
 * unconditionally. Neither checked whether the event came from the user,
 * from the menu's own subtree, or from a programmatic scroll the app
 * performs on its own.
 *
 * The consequence: any scroll anywhere in the document — including one the
 * app itself performs — dismissed an open menu with no user intent.
 *
 * The fix scopes the scroll dismiss to the anchor the menu was opened
 * from, and drops the `wheel` dismiss entirely. These tests pin both the
 * bug (as a regression guard) and the fix.
 */

const Host = defineComponent({
  setup() {
    const { menuPos, openAt, openAtPoint, close } = useContextMenu()
    return { menuPos, openAt, openAtPoint, close }
  },
  template: '<div />',
})

function mountHost() {
  return mount(Host, { attachTo: document.body })
}

/**  * Open the menu the way a real `@contextmenu.prevent` handler does: the event's `currentTarget` is
 * the row the handler is bound to, and that is what the scoped scroll dismiss keys off. */
function openMenuFrom(wrapper: ReturnType<typeof mountHost>, anchor: HTMLElement) {
  const event = new MouseEvent('contextmenu', { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'currentTarget', { value: anchor, configurable: true })
  wrapper.vm.openAt(event)
}

describe('useContextMenu — dismiss paths', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
  })

  // ─── The bug, pinned as a regression guard ───────────────────────────

  it('REGRESSION: a wheel event anywhere in the document no longer closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // A trackpad nudge, a two-finger scroll, or an inertial scroll tail
    // over an unrelated pane. The user never touched the menu.
    window.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).not.toBeNull()
    wrapper.unmount()
  })

  it('REGRESSION: a scroll in an unrelated container no longer closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // A scroll inside the chat transcript, the file tree, or the right
    // sidebar. The menu is still exactly where the user put it.
    const unrelated = document.createElement('div')
    unrelated.style.overflow = 'auto'
    document.body.appendChild(unrelated)
    unrelated.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).not.toBeNull()
    wrapper.unmount()
  })

  it('REGRESSION: a scroll the APP performs on its own container no longer closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // VirtualScroller's measureItems compensation, endPreserve's restore,
    // ChatView's scrollToBottom re-stick — all write scrollTop themselves
    // and fire a native scroll event. None of them invalidate the menu.
    const appContainer = document.createElement('div')
    appContainer.style.overflowY = 'auto'
    document.body.appendChild(appContainer)
    appContainer.scrollTop = 400
    appContainer.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).not.toBeNull()
    wrapper.unmount()
  })

  it('REGRESSION: a scroll inside the menu itself no longer closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()

    // The kanban "Move to column" submenu is `max-h-[320px] overflow-y-auto`
    // (KanbanTaskContextMenu.vue:452). Scrolling a long column list inside
    // the menu is a deliberate act that must keep the menu open.
    const menu = document.createElement('div')
    menu.setAttribute('data-context-menu', '')
    menu.style.overflowY = 'auto'
    document.body.appendChild(menu)
    menu.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).not.toBeNull()
    wrapper.unmount()
  })

  // ─── The dismissals that must survive ────────────────────────────────

  it('a scroll of the anchor itself closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    anchor.style.overflowY = 'auto'
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // The row moved under a `fixed` menu, so the menu now points at
    // nothing.
    anchor.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })

  it('a scroll inside the anchor closes the menu', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    const child = document.createElement('div')
    child.style.overflowY = 'auto'
    anchor.appendChild(child)
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    child.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })

  it('the anchor being unmounted closes the menu (the VirtualScroller case)', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // A VirtualScroller unmounts rows outside its window. The menu is
    // teleported to body, so it survives the unmount — but it is now
    // orphaned over unrelated content and must close.
    anchor.remove()
    document.body.dispatchEvent(new Event('scroll', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })

  it('Escape closes the menu (intended)', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })

  it('a mousedown outside the menu closes the menu (intended)', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()

    const outside = document.createElement('div')
    document.body.appendChild(outside)
    outside.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })

  it('a mousedown inside the menu does NOT close it (the data-context-menu opt-out)', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)
    openMenuFrom(wrapper, anchor)
    await nextTick()

    const menu = document.createElement('div')
    menu.setAttribute('data-context-menu', '')
    document.body.appendChild(menu)
    menu.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await nextTick()

    expect(wrapper.vm.menuPos).not.toBeNull()
    wrapper.unmount()
  })

  // ─── The keyboard path ───────────────────────────────────────────────

  it('openAtPoint attaches the same dismiss wiring as openAt', async () => {
    const wrapper = mountHost()
    const anchor = document.createElement('div')
    document.body.appendChild(anchor)

    // The ContextMenu / Shift+F10 path on a kanban card.
    wrapper.vm.openAtPoint(100, 200, anchor)
    await nextTick()
    expect(wrapper.vm.menuPos).not.toBeNull()

    // Before the fix this path assigned menuPos directly and attached no
    // listener at all, so Escape did nothing.
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()

    expect(wrapper.vm.menuPos).toBeNull()
    wrapper.unmount()
  })
})
