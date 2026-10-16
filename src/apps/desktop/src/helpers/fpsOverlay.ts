/** Dev-only FPS overlay (desktop scroll-perf plan, Task 5). A tiny fixed-position chip that shows
 * rolling frames-per-second so platform-level rendering fixes (Linux gfx env pinning, macOS scheme
 * handler, Windows resize coalescing) can be MEASURED instead of guessed. */
const OVERLAY_ID = 'pabrik-fps-overlay'

let rafId: number | null = null
let frameCount = 0
let windowStart = 0

function tick(now: number): void {
  frameCount++
  const elapsed = now - windowStart
  if (elapsed >= 1000) {
    const fps = Math.round((frameCount * 1000) / elapsed)
    const el = document.getElementById(OVERLAY_ID)
    if (el) el.textContent = `${fps} FPS`
    frameCount = 0
    windowStart = now
  }
  rafId = requestAnimationFrame(tick)
}

/** Start the overlay. No-op in production builds or if already mounted. */
export function mount(): void {
  if (!import.meta.env.DEV) return
  if (document.getElementById(OVERLAY_ID) != null) return

  const chip = document.createElement('div')
  chip.id = OVERLAY_ID
  chip.textContent = '-- FPS'
  Object.assign(chip.style, {
    position: 'fixed',
    top: '8px',
    right: '8px',
    zIndex: '2147483647',
    padding: '2px 8px',
    borderRadius: '6px',
    background: 'rgba(0, 0, 0, 0.65)',
    color: '#7ee787',
    font: '600 11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace',
    pointerEvents: 'none',
    userSelect: 'none',
  } satisfies Partial<CSSStyleDeclaration>)
  document.body.appendChild(chip)

  frameCount = 0
  windowStart = performance.now()
  rafId = requestAnimationFrame(tick)
}

/** Stop the overlay and remove the chip. Idempotent; safe in prod. */
export function unmount(): void {
  if (rafId != null) {
    cancelAnimationFrame(rafId)
    rafId = null
  }
  document.getElementById(OVERLAY_ID)?.remove()
}
