import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, unmount } from '../fpsOverlay'

// The overlay is a dev-only measurement tool (desktop scroll-perf plan,
// Task 5). Contract:
//   - mount() starts a rAF loop and injects a fixed-position chip into
//     document.body showing rolling FPS.
//   - unmount() stops the loop and removes the chip.
//   - In production builds (import.meta.env.DEV === false) both calls
//     are no-ops — zero cost in shipped binaries.
describe('fpsOverlay', () => {
  let rafCallbacks: Array<(t: number) => void>

  beforeEach(() => {
    vi.stubEnv('DEV', true)
    rafCallbacks = []
    vi.stubGlobal(
      'requestAnimationFrame',
      vi.fn((cb: (t: number) => void) => {
        rafCallbacks.push(cb)
        return rafCallbacks.length
      }),
    )
    vi.stubGlobal('cancelAnimationFrame', vi.fn())
  })

  afterEach(() => {
    unmount()
    vi.unstubAllGlobals()
    vi.unstubAllEnvs()
    document.getElementById('pabrik-fps-overlay')?.remove()
  })

  function tickFrames(times: number, stepMs = 16) {
    let t = performance.now()
    for (let i = 0; i < times; i++) {
      t += stepMs
      const cbs = rafCallbacks.splice(0)
      for (const cb of cbs) cb(t)
    }
  }

  it('mounts a chip into document.body in dev mode', () => {
    mount()
    const el = document.getElementById('pabrik-fps-overlay')
    expect(el).not.toBeNull()
    expect(el!.textContent).toMatch(/FPS/)
  })

  it('updates the displayed FPS after a second of frames', () => {
    mount()
    // 64 frames at 16ms ≈ 1024ms of wall time → crosses the 1s window
    // and writes a numeric reading.
    tickFrames(64)
    const el = document.getElementById('pabrik-fps-overlay')!
    expect(el.textContent).toMatch(/\d+/)
    expect(el.textContent).not.toBe('-- FPS')
  })

  it('unmount removes the chip and cancels the loop', () => {
    mount()
    expect(document.getElementById('pabrik-fps-overlay')).not.toBeNull()
    unmount()
    expect(document.getElementById('pabrik-fps-overlay')).toBeNull()
    expect(cancelAnimationFrame).toHaveBeenCalled()
  })

  it('is a no-op when DEV is false (prod build)', () => {
    vi.stubEnv('DEV', false)
    mount()
    expect(document.getElementById('pabrik-fps-overlay')).toBeNull()
    expect(requestAnimationFrame).not.toHaveBeenCalled()
    // unmount must also be safe when nothing was mounted
    expect(() => unmount()).not.toThrow()
  })

  it('double-mount is idempotent (no duplicate chips)', () => {
    mount()
    mount()
    expect(document.querySelectorAll('#pabrik-fps-overlay').length).toBe(1)
  })
})
