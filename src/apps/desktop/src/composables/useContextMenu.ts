import { onBeforeUnmount, ref } from 'vue'

/**
 * Position state + dismiss wiring for the right-click context menus
 * (KanbanTaskContextMenu.vue, OpenInNewTabMenu.vue, GitBranchMenu.vue).
 * Hosts keep their own payload (chat, item, task ids); this only owns
 * the nullable screen position and the listeners that dismiss it.
 *
 * Dismissal triggers:
 *   - Escape
 *   - mousedown outside the menu
 *   - a scroll that actually moves the row the menu was opened from
 *
 * Why the scroll dismiss is scoped rather than global: every menu is
 * Teleported to `body` and positioned `fixed`, so it does not move with
 * its row. When the row scrolls away — or the VirtualScroller unmounts
 * it — the menu is orphaned over unrelated content and must close. But
 * a scroll anywhere ELSE in the app (the chat transcript, the file
 * tree, the right sidebar) leaves the menu exactly where the user put
 * it, and closing on that is the "menu suddenly closed" report. So the
 * listener only fires when the scroll target actually contains the
 * anchor, or the anchor has been torn out of the DOM.
 *
 * Edge clamping: menus are placed at the raw clientX/clientY. A card in a
 * 280px-wide column can be right-clicked near the viewport's right edge,
 * which would push the menu (and its "Move to column" submenu) off-screen.
 * `clampToViewport` pulls the coordinates back inside.
 */
export function useContextMenu(options: { width?: number; height?: number } = {}) {
  // Estimated menu footprint, used before the menu is measured. Over- estimating slightly is fine —
  // it only pulls the menu a few px further from the edge than strictly necessary, whereas
  // under-estimating clips it.
  const MENU_W = options.width ?? 220
  const MENU_H = options.height ?? 320

  const menuPos = ref<{ x: number; y: number } | null>(null)

  /**
   * The element the menu was opened from, captured at open time.
   *
   * Read from `event.currentTarget` (the row the `@contextmenu` handler is
   * bound to) or passed explicitly by the keyboard path. It lives here
   * rather than in the host because the host would have to thread it
   * through every call site, and because the anchor is only meaningful
   * to the dismiss logic that consumes it.
   */
  let anchorEl: HTMLElement | null = null

  const openAt = (event: MouseEvent) => {
    event.preventDefault()
    // `currentTarget` is only valid during dispatch, so it must be read
    // synchronously here rather than in an async callback.
    openAtPoint(event.clientX, event.clientY, event.currentTarget as HTMLElement | null)
  }

  /**
   * Open at an explicit point with an explicit anchor.
   *
   * Split out of `openAt` so the keyboard path (ContextMenu / Shift+F10)
   * can open the menu from a bounding-rect centre and still get the same
   * dismiss wiring. Before this, that path assigned `menuPos` directly
   * and never attached a single listener — no Escape, no outside-click,
   * no scroll dismiss.
   */
  const openAtPoint = (x: number, y: number, anchor: HTMLElement | null) => {
    anchorEl = anchor
    menuPos.value = clampToViewport(x, y)
    attachDismissListeners()
  }

  /** Pull a (x, y) inside the viewport, keeping the menu's estimated
   * footprint visible. Exported as a pure function so a host that
   * computes its own position (e.g. the ContextMenu-key path, which
   * anchors at a card's bounding-rect centre) can reuse the same rule. */
  function clampToViewport(x: number, y: number): { x: number; y: number } {
    const maxX = Math.max(8, window.innerWidth - MENU_W - 8)
    const maxY = Math.max(8, window.innerHeight - MENU_H - 8)
    return {
      x: Math.min(Math.max(8, x), maxX),
      y: Math.min(Math.max(8, y), maxY),
    }
  }

  const close = () => {
    menuPos.value = null
    anchorEl = null
    detachDismissListeners()
  }

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
  }

  const onPointerDown = (event: MouseEvent) => {
    if (!menuPos.value) return
    const target = event.target as HTMLElement | null
    if (target && typeof target.closest === 'function') {
      // Our own menus opt out of the outside-click dismiss.
      if (target.closest('[data-context-menu]')) return
      if (target.closest('[data-testid="open-new-tab-menu"]')) return
    }
    close()
  }

  /**
   * Close only when the scroll actually invalidates the menu's anchor.
   *
   * Three cases, in the order they are checked:
   *
   *  1. The anchor is gone from the DOM. A VirtualScroller unmounts rows
   *     outside its window, which is the case the original global
   *     listener was written for. Close.
   *  2. The scroll target is the anchor itself or a descendant of it.
   *     The row moved under a `fixed` menu, so the menu now points at
   *     nothing. Close.
   *  3. Anything else — a scroll in the chat transcript, the file tree,
   *     the right sidebar, or the menu's own submenu. The menu is still
   *     exactly where the user put it, so it stays open.
   *
   * `wheel` is deliberately not dismissed at all: a wheel gesture over an
   * unrelated pane is the same as case 3, and a wheel over the menu's own
   * scrollable submenu ("Move to column") must scroll the submenu, not
   * close it.
   */
  const onScroll = (event: Event) => {
    if (!menuPos.value) return
    if (!anchorEl || !anchorEl.isConnected) {
      close()
      return
    }
    const target = event.target as Node | null
    if (target && (target === anchorEl || anchorEl.contains(target))) {
      close()
    }
  }

  // Dismiss listeners follow the menu state directly: attached on open,
  // removed on close (re-adding an identical listener is a browser no-op,
  // so a second openAt while open is harmless). Unmount always detaches.
  function attachDismissListeners() {
    window.addEventListener('keydown', onKeydown)
    window.addEventListener('mousedown', onPointerDown)
    window.addEventListener('scroll', onScroll, true)
  }

  function detachDismissListeners() {
    window.removeEventListener('keydown', onKeydown)
    window.removeEventListener('mousedown', onPointerDown)
    window.removeEventListener('scroll', onScroll, true)
  }

  onBeforeUnmount(() => {
    detachDismissListeners()
  })

  return { menuPos, openAt, openAtPoint, close, clampToViewport }
}
