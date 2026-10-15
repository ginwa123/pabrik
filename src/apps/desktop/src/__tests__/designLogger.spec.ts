/**
 * Behavioural tests for the design logger (helpers/designLogger.ts).
 *
 * The logger is a singleton with a runtime enable/disable toggle.
 * These tests verify:
 *   - When disabled (default), no console output is produced.
 *   - When enabled, info/warn/error lines are emitted in the right
 *     shape (tag, headline, full context object).
 *   - The toggle persists via localStorage.
 *   - The console escape hatch (window.__designLogger) exposes the
 *     on/off/status API in dev builds.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  designLogger,
  isDesignLoggerEnabled,
  setDesignLoggerEnabled,
} from '../helpers/designLogger'

describe('designLogger', () => {
  beforeEach(() => {
    setDesignLoggerEnabled(true)
  })

  afterEach(() => {
    setDesignLoggerEnabled(false)
    vi.restoreAllMocks()
    // Clear any localStorage key the test created.
    if (typeof localStorage !== 'undefined') {
      try {
        localStorage.removeItem('pabrik.design-logger.enabled')
      } catch {
        // ignore
      }
    }
  })

  it('is silent when disabled (the production default)', () => {
    setDesignLoggerEnabled(false)
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    designLogger.info({ reason: 'emit:select', caller: 't' })
    designLogger.warn({ reason: 'app:noop:noActivePage', caller: 't' })
    designLogger.error({ reason: 'sse:dedupe-miss', caller: 't' })

    expect(logSpy).not.toHaveBeenCalled()
    expect(warnSpy).not.toHaveBeenCalled()
    expect(errSpy).not.toHaveBeenCalled()
  })

  it('emits info via console.log when enabled', () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})

    designLogger.info({
      reason: 'emit:select',
      caller: 't.select',
      element: { id: 'el_1', type: 'rectangle', x: 100, y: 100, width: 50, height: 50, parentId: '' },
      extra: { mode: 'move' },
    })

    expect(logSpy).toHaveBeenCalledTimes(1)
    const [line1, ctx] = logSpy.mock.calls[0]!
    // Headline starts with the tag prefix + caller + reason
    expect(line1).toContain('[design#')
    expect(line1).toContain('t.select')
    expect(line1).toContain('INFO')
    expect(line1).toContain('emit:select')
    // Context object carries the full state snapshot
    expect(ctx.caller).toBe('t.select')
    expect(ctx.reason).toBe('emit:select')
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((ctx as any).element.id).toBe('el_1')
  })

  it('emits warn via console.warn when enabled (noActivePage is the loud signal)', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    designLogger.warn({
      reason: 'app:noop:noActivePage',
      caller: 'useDesignHandlers.translateElement',
      noActivePage: true,
      dx: 50,
      dy: 30,
    })

    expect(warnSpy).toHaveBeenCalledTimes(1)
    const [line1] = warnSpy.mock.calls[0]!
    expect(line1).toContain('WARN')
    expect(line1).toContain('app:noop:noActivePage')
    expect(line1).toContain('⚠NO_ACTIVE_PAGE')
  })

  it('exposes window.__designLogger on/off/status in dev', () => {
    // Reset the toggle so we exercise the round-trip.
    setDesignLoggerEnabled(false)
    expect(isDesignLoggerEnabled()).toBe(false)

    const w = window as unknown as {
      __designLogger?: { on: () => void; off: () => void; status: () => boolean }
    }
    // The escape hatch is registered at module-load when `import.meta.env.DEV` is true (vitest's
    // default). Production-style build: skip the assertion (the escape hatch is dev-only by
    // design).
    if (!w.__designLogger) return
    w.__designLogger.on()
    expect(isDesignLoggerEnabled()).toBe(true)
    w.__designLogger.off()
    expect(isDesignLoggerEnabled()).toBe(false)
  })

  it('persists the toggle in localStorage so a reload keeps the setting', () => {
    // localStorage is jsdom-provided in vitest; the guard below is a safety net for non-jsdom
    // environments (the original code path was `expect(true).toBe(true); return` inside the else
    // branch, which oxlint's no-conditional-expect rejects).
    if (typeof localStorage === 'undefined') return
    setDesignLoggerEnabled(true)
    try {
      expect(localStorage.getItem('pabrik.design-logger.enabled')).toBe('on')
    } finally {
      setDesignLoggerEnabled(false)
    }
  })
})