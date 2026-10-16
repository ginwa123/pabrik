/** Keyboard shortcuts for the tab strip. Shortcut namespace: browsers own `Ctrl/Cmd+T`,
 * `Ctrl/Cmd+W`, `Ctrl/Cmd+1..9`, and Chromium also swallows `Ctrl+Tab`, so those can never be the
 * documented map for a page. */
export type TabCommand = 'new' | 'close' | 'reopen' | 'next' | 'previous' | `select:${number}`

export interface TabShortcutHandlers {
  newTab: () => void
  closeTab: () => void
  reopenTab: () => void
  nextTab: () => void
  previousTab: () => void
  selectTab: (index: number) => void
}

export interface TabShortcutOptions {
  handlers: TabShortcutHandlers
  /** Tab mode off → every shortcut is inert. */
  isEnabled: () => boolean
  /** Used to ignore `select:<n>` beyond the last tab. */
  tabCount: () => number
  /** Defaults to `document`; injected in tests. */
  target?: {
    addEventListener: (type: string, listener: (event: KeyboardEvent) => void) => void
    removeEventListener: (type: string, listener: (event: KeyboardEvent) => void) => void
  }
}

function digitOf(key: string): number {
  return /^[1-9]$/.test(key) ? Number(key) : 0
}

/** `null` = not a tab shortcut, so the event must keep its default meaning. */
export function resolveTabShortcut(event: {
  key: string
  shiftKey: boolean
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
}): TabCommand | null {
  const key = event.key
  const digit = digitOf(key)

  const primary = event.shiftKey && event.altKey && !event.ctrlKey && !event.metaKey
  if (primary) {
    if (key === 't' || key === 'T') return 'new'
    if (key === 'w' || key === 'W') return 'close'
    if (key === 'z' || key === 'Z') return 'reopen'
    if (key === 'ArrowRight') return 'next'
    if (key === 'ArrowLeft') return 'previous'
    if (digit) return `select:${digit}`
    return null
  }

  // Browser-reserved chords, best effort: the engine may never deliver them.
  const reserved = (event.ctrlKey || event.metaKey) && !event.altKey
  if (reserved) {
    if (key === 'Tab') return event.shiftKey ? 'previous' : 'next'
    if (event.shiftKey) return null
    if (key === 't' || key === 'T') return 'new'
    if (key === 'w' || key === 'W') return 'close'
    if (digit) return `select:${digit}`
    return null
  }

  return null
}

/** A modal owns the keyboard while it is open — never steal its keys.
 * (`EventTarget` from a window-level dispatch has no `closest`.) */
export function isTabShortcutBlocked(target: EventTarget | null | undefined): boolean {
  const element = target as (HTMLElement & { closest?: (selector: string) => Element | null }) | null
  if (!element || typeof element.closest !== 'function') return false
  return element.closest('[role="dialog"]') !== null
}

/** Apply one resolved command. Returns false when it was a no-op. */
export function applyTabCommand(
  command: TabCommand,
  handlers: TabShortcutHandlers,
  tabCount: number,
): boolean {
  if (command === 'new') {
    handlers.newTab()
    return true
  }
  if (command === 'close') {
    handlers.closeTab()
    return true
  }
  if (command === 'reopen') {
    handlers.reopenTab()
    return true
  }
  if (command === 'next') {
    handlers.nextTab()
    return true
  }
  if (command === 'previous') {
    handlers.previousTab()
    return true
  }
  if (command.startsWith('select:')) {
    const index = Number(command.slice('select:'.length))
    if (!Number.isFinite(index) || index < 1 || index > tabCount) return false
    handlers.selectTab(index)
    return true
  }
  return false
}

/**
 * Register the listener. Returns the teardown — call it from `onUnmounted`.
 */
export function useTabShortcuts(options: TabShortcutOptions): () => void {
  const target =
    options.target ??
    (globalThis as unknown as TabShortcutOptions['target'] & {
      addEventListener: (type: string, listener: (event: KeyboardEvent) => void) => void
      removeEventListener: (type: string, listener: (event: KeyboardEvent) => void) => void
    })

  const onKeydown = (event: KeyboardEvent) => {
    if (!options.isEnabled()) return
    if (isTabShortcutBlocked(event.target)) return
    const command = resolveTabShortcut(event)
    if (!command) return
    if (!applyTabCommand(command, options.handlers, options.tabCount())) return
    // Only swallow the keystroke once we know we acted on it.
    event.preventDefault()
  }

  target.addEventListener('keydown', onKeydown)
  return () => target.removeEventListener('keydown', onKeydown)
}
