import { describe, expect, it, vi } from 'vitest'

import {
  applyTabCommand,
  isTabShortcutBlocked,
  resolveTabShortcut,
  useTabShortcuts,
  type TabShortcutHandlers,
} from '../composables/useTabShortcuts'

/** Task 6 of the tab-mode plan. The map is asserted on the pure resolver,
 * and the listener is asserted on a fake target so the test never depends
 * on (or pollutes) the real document. */

function mods(overrides: Partial<{ shiftKey: boolean; altKey: boolean; ctrlKey: boolean; metaKey: boolean }> = {}) {
  return { shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, ...overrides }
}

function handlers(): TabShortcutHandlers & Record<string, ReturnType<typeof vi.fn>> {
  return {
    newTab: vi.fn(),
    closeTab: vi.fn(),
    reopenTab: vi.fn(),
    nextTab: vi.fn(),
    previousTab: vi.fn(),
    selectTab: vi.fn(),
  }
}

function fakeTarget() {
  const listeners = new Set<(event: KeyboardEvent) => void>()
  return {
    addEventListener: (_type: string, listener: (event: KeyboardEvent) => void) => {
      listeners.add(listener)
    },
    removeEventListener: (_type: string, listener: (event: KeyboardEvent) => void) => {
      listeners.delete(listener)
    },
    dispatch(event: KeyboardEvent) {
      for (const listener of listeners) listener(event)
      return event
    },
    get listenerCount() {
      return listeners.size
    },
  }
}

describe('resolveTabShortcut', () => {
  it('maps the documented Shift+Alt namespace', () => {
    const primary = { shiftKey: true, altKey: true }
    expect(resolveTabShortcut({ key: 't', ...mods(primary) })).toBe('new')
    expect(resolveTabShortcut({ key: 'T', ...mods(primary) })).toBe('new')
    expect(resolveTabShortcut({ key: 'w', ...mods(primary) })).toBe('close')
    expect(resolveTabShortcut({ key: 'z', ...mods(primary) })).toBe('reopen')
    expect(resolveTabShortcut({ key: 'ArrowRight', ...mods(primary) })).toBe('next')
    expect(resolveTabShortcut({ key: 'ArrowLeft', ...mods(primary) })).toBe('previous')
    expect(resolveTabShortcut({ key: '1', ...mods(primary) })).toBe('select:1')
    expect(resolveTabShortcut({ key: '9', ...mods(primary) })).toBe('select:9')
  })

  it('maps the browser-reserved chords best-effort', () => {
    expect(resolveTabShortcut({ key: 'w', ...mods({ ctrlKey: true }) })).toBe('close')
    expect(resolveTabShortcut({ key: 'w', ...mods({ metaKey: true }) })).toBe('close')
    expect(resolveTabShortcut({ key: 't', ...mods({ ctrlKey: true }) })).toBe('new')
    expect(resolveTabShortcut({ key: 'Tab', ...mods({ ctrlKey: true }) })).toBe('next')
    expect(resolveTabShortcut({ key: 'Tab', ...mods({ ctrlKey: true, shiftKey: true }) })).toBe('previous')
    expect(resolveTabShortcut({ key: '3', ...mods({ metaKey: true }) })).toBe('select:3')
  })

  it('ignores everything else', () => {
    expect(resolveTabShortcut({ key: 'a', ...mods() })).toBeNull()
    expect(resolveTabShortcut({ key: 't', ...mods({ shiftKey: true }) })).toBeNull()
    expect(resolveTabShortcut({ key: 't', ...mods({ altKey: true }) })).toBeNull()
    expect(resolveTabShortcut({ key: 'q', ...mods({ shiftKey: true, altKey: true }) })).toBeNull()
    expect(resolveTabShortcut({ key: '0', ...mods({ shiftKey: true, altKey: true }) })).toBeNull()
    expect(resolveTabShortcut({ key: 'Tab', ...mods({ shiftKey: true, altKey: true }) })).toBeNull()
    // Ctrl+Shift+T is the browser's "reopen closed tab" — leave it alone.
    expect(resolveTabShortcut({ key: 'T', ...mods({ ctrlKey: true, shiftKey: true }) })).toBeNull()
    // Ctrl+Alt+… belongs to the OS on several platforms.
    expect(resolveTabShortcut({ key: 'w', ...mods({ ctrlKey: true, altKey: true }) })).toBeNull()
  })
})

describe('applyTabCommand', () => {
  it('dispatches each command', () => {
    const spy = handlers()
    expect(applyTabCommand('new', spy, 3)).toBe(true)
    expect(applyTabCommand('close', spy, 3)).toBe(true)
    expect(applyTabCommand('reopen', spy, 3)).toBe(true)
    expect(applyTabCommand('next', spy, 3)).toBe(true)
    expect(applyTabCommand('previous', spy, 3)).toBe(true)
    expect(applyTabCommand('select:2', spy, 3)).toBe(true)
    expect(spy.newTab).toHaveBeenCalledTimes(1)
    expect(spy.closeTab).toHaveBeenCalledTimes(1)
    expect(spy.reopenTab).toHaveBeenCalledTimes(1)
    expect(spy.nextTab).toHaveBeenCalledTimes(1)
    expect(spy.previousTab).toHaveBeenCalledTimes(1)
    expect(spy.selectTab).toHaveBeenCalledWith(2)
  })

  it('refuses a tab index beyond the list', () => {
    const spy = handlers()
    expect(applyTabCommand('select:4', spy, 3)).toBe(false)
    expect(applyTabCommand('select:1', spy, 0)).toBe(false)
    expect(spy.selectTab).not.toHaveBeenCalled()
  })
})

describe('isTabShortcutBlocked', () => {
  it('blocks while a modal dialog owns the keyboard', () => {
    document.body.innerHTML = '<div role="dialog"><button id="inside"></button></div><button id="outside"></button>'
    const inside = document.getElementById('inside')
    const outside = document.getElementById('outside')
    expect(isTabShortcutBlocked(inside)).toBe(true)
    expect(isTabShortcutBlocked(outside)).toBe(false)
    // a window-level dispatch has a target without element methods
    expect(isTabShortcutBlocked(window)).toBe(false)
    expect(isTabShortcutBlocked(null)).toBe(false)
    document.body.innerHTML = ''
  })
})

describe('useTabShortcuts', () => {
  it('acts and prevents the default only when it acts', () => {
    const target = fakeTarget()
    const spy = handlers()
    const stop = useTabShortcuts({ handlers: spy, isEnabled: () => true, tabCount: () => 4, target })

    const newTab = target.dispatch(new KeyboardEvent('keydown', { key: 't', shiftKey: true, altKey: true, cancelable: true }))
    expect(spy.newTab).toHaveBeenCalledTimes(1)
    expect(newTab.defaultPrevented).toBe(true)

    const close = target.dispatch(new KeyboardEvent('keydown', { key: 'w', shiftKey: true, altKey: true, cancelable: true }))
    expect(spy.closeTab).toHaveBeenCalledTimes(1)
    expect(close.defaultPrevented).toBe(true)

    // a key we do not own keeps its default meaning
    const other = target.dispatch(new KeyboardEvent('keydown', { key: 'a', cancelable: true }))
    expect(other.defaultPrevented).toBe(false)
    expect(spy.newTab).toHaveBeenCalledTimes(1)
    expect(spy.closeTab).toHaveBeenCalledTimes(1)

    stop()
    expect(target.listenerCount).toBe(0)
  })

  it('routes cycles and direct selection', () => {
    const target = fakeTarget()
    const spy = handlers()
    useTabShortcuts({ handlers: spy, isEnabled: () => true, tabCount: () => 3, target })

    target.dispatch(new KeyboardEvent('keydown', { key: 'Tab', ctrlKey: true, cancelable: true }))
    target.dispatch(new KeyboardEvent('keydown', { key: 'Tab', ctrlKey: true, shiftKey: true, cancelable: true }))
    target.dispatch(new KeyboardEvent('keydown', { key: '2', metaKey: true, cancelable: true }))
    expect(spy.nextTab).toHaveBeenCalledTimes(1)
    expect(spy.previousTab).toHaveBeenCalledTimes(1)
    expect(spy.selectTab).toHaveBeenCalledWith(2)
  })

  it('is inert when tab mode is off', () => {
    const target = fakeTarget()
    const spy = handlers()
    useTabShortcuts({ handlers: spy, isEnabled: () => false, tabCount: () => 3, target })

    const event = target.dispatch(new KeyboardEvent('keydown', { key: 't', shiftKey: true, altKey: true, cancelable: true }))
    expect(spy.newTab).not.toHaveBeenCalled()
    expect(event.defaultPrevented).toBe(false)
  })

  it('ignores shortcuts while a dialog is open', () => {
    document.body.innerHTML = '<div role="dialog"><button id="modal-btn"></button></div>'
    const button = document.getElementById('modal-btn')
    const target = fakeTarget()
    const spy = handlers()
    useTabShortcuts({ handlers: spy, isEnabled: () => true, tabCount: () => 3, target })
    // a modal child that does not handle the key lets it bubble to document
    button?.addEventListener('keydown', (event) => target.dispatch(event as KeyboardEvent))
    button?.dispatchEvent(new KeyboardEvent('keydown', { key: 'w', shiftKey: true, altKey: true, bubbles: true, cancelable: true }))
    expect(spy.closeTab).not.toHaveBeenCalled()
    document.body.innerHTML = ''
  })
})
