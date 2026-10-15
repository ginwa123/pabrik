import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createScrollLogger } from '../scrollLogger'

// Desktop scroll-perf plan, Task 6: scrollLogger.info fires ~60x/sec during SSE streaming scrolls
// and was prod-on. Contract after the fix: - 'debug' AND 'info' levels are silenced outside DEV -
// 'warn' / 'error' always log (they signal real problems)

function makeCtx() {
  const container = document.createElement('div')
  Object.defineProperty(container, 'scrollTop', { value: 100, writable: true })
  Object.defineProperty(container, 'scrollHeight', { value: 5000, writable: true })
  Object.defineProperty(container, 'clientHeight', { value: 800, writable: true })
  document.body.appendChild(container)
  return {
    container,
    scroller: container,
    wrapper: document.createElement('div'),
    scrollTop: 100,
    scrollHeight: 5000,
    clientHeight: 800,
    messages: 10,
    distanceFromBottom: 4200,
    distanceFromTop: 100,
    scrollPercent: 0.02,
    isAtBottom: false,
    containerInfo: {
      null: false,
      tag: 'DIV',
      className: 'probe',
      display: 'block',
      visibility: 'visible',
      offsetHeight: 800,
      offsetParent: 'body',
    },
  }
}

describe('scrollLogger level gating', () => {
  let logSpy: ReturnType<typeof vi.spyOn>
  let warnSpy: ReturnType<typeof vi.spyOn>
  let errorSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    vi.resetModules()
    // info and debug both route through console.log (see scrollLogger emit)
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    document.querySelectorAll('__logger_probe__').forEach((n) => n.remove())
    vi.restoreAllMocks()
    vi.unstubAllEnvs()
  })

  it('silences info logs when DEV is false', async () => {
    vi.stubEnv('DEV', false)
    const logger = createScrollLogger('gate-test')
    logger.info({ ...makeCtx(), reason: 'reached-bottom' })
    expect(logSpy).not.toHaveBeenCalled()
  })

  it('still emits warn when DEV is false', async () => {
    vi.stubEnv('DEV', false)
    const logger = createScrollLogger('gate-test')
    logger.warn({ ...makeCtx(), reason: 'reached-bottom' })
    expect(warnSpy).toHaveBeenCalled()
  })

  it('still emits error when DEV is false', async () => {
    vi.stubEnv('DEV', false)
    const logger = createScrollLogger('gate-test')
    logger.error({ ...makeCtx(), reason: 'reached-bottom' })
    expect(errorSpy).toHaveBeenCalled()
  })

  it('emits info normally in dev', async () => {
    vi.stubEnv('DEV', true)
    const logger = createScrollLogger('gate-test')
    logger.info({ ...makeCtx(), reason: 'reached-bottom' })
    expect(logSpy).toHaveBeenCalled()
  })
})
