/**
 * Static-contract regression tests for the canvas-background removal.
 *
 * Plan: docs/superpowers/plans/2026-07-29-remove-canvas-background.md
 *
 * These tests grep DesignView.vue's source to verify the canvas
 * background feature has been removed end-to-end:
 *
 *   - No `canvasWidth` / `canvasHeight` computed properties
 *   - No drag-clamp helpers (`clampX` / `clampY`)
 *   - No nudge-clamp lines (canvasWidth.value - 10 / canvasHeight.value - 10)
 *   - No W × H header inputs (data-testid="design-page-size" / "-width-input" / "-height-input")
 *   - No `canvasBounds` passed to `computeSnapDelta`
 *   - Canvas div has no fixed width / height / box-shadow / card-bg color
 *
 * If a future refactor reintroduces any of these (e.g., "let's add
 * the canvas back"), the tests fail loudly.
 */

import { readFileSync } from 'fs'
import { join } from 'path'
import { describe, expect, it } from 'vitest'

const DESIGN_VIEW_PATH = join(
  __dirname,
  '..',
  'components',
  'design',
  'DesignView.vue',
)

describe('DesignView removes the canvas-background feature', () => {
  const source = readFileSync(DESIGN_VIEW_PATH, 'utf8')

  it('does NOT declare canvasWidth / canvasHeight computed properties', () => {
    expect(source).not.toMatch(/const canvasWidth\s*=/)
    expect(source).not.toMatch(/const canvasHeight\s*=/)
  })

  it('does NOT declare the drag-clamp helpers clampX / clampY', () => {
    // The arrow-function clamp helpers used to wrap each element's
    // drag delta. After the canvas-background removal, drag passes
    // finalDx / finalDy straight through with no clamping.
    expect(source).not.toMatch(/const clampX\s*=\s*\(/)
    expect(source).not.toMatch(/const clampY\s*=\s*\(/)
  })

  it('does NOT clamp the arrow-key nudge against page bounds', () => {
    // The 4 clamp lines (canvasWidth.value - 10 / canvasHeight.value - 10)
    // have been removed; arrow keys now move freely.
    expect(source).not.toMatch(/canvasWidth\.value\s*-\s*10/)
    expect(source).not.toMatch(/canvasHeight\.value\s*-\s*10/)
  })

  it('does NOT render the W × H header inputs', () => {
    expect(source).not.toContain('data-testid="design-page-size"')
    expect(source).not.toContain('design-page-width-input')
    expect(source).not.toContain('design-page-height-input')
  })

  it('does NOT pass canvasBounds to computeSnapDelta', () => {
    // The 5th argument to computeSnapDelta was { width: canvasWidth.value,
    // height: canvasHeight.value } before the canvas-background removal.
    expect(source).not.toMatch(/width:\s*canvasWidth\.value/)
    expect(source).not.toMatch(/height:\s*canvasHeight\.value/)
  })

  it('canvas div has NO fixed width / height / box-shadow / card background', () => {
    // The old inline style on <div data-testid="design-canvas"> had: width: `${canvasWidth}px`
    // height: `${canvasHeight}px` backgroundColor: 'var(--semantic-card-bg)' boxShadow: '0 4px 20px
    // rgba(0, 0, 0, 0.3)' None of those should remain — the canvas div is now auto-grow.
    expect(source).not.toMatch(/width:\s*`\$\{canvasWidth\}/)
    expect(source).not.toMatch(/height:\s*`\$\{canvasHeight\}/)
    expect(source).not.toMatch(/backgroundColor:\s*'var\(--semantic-card-bg\)'/)
    expect(source).not.toMatch(/boxShadow:\s*'0 4px/)
  })

  it('does NOT declare the pageSizeDebounceTimer / commitPageSize / handlePageSizeChange functions', () => {
    // The debounced page-resize handler was removed alongside the
    // W × H header inputs.
    expect(source).not.toMatch(/let pageSizeDebounceTimer/)
    expect(source).not.toMatch(/const commitPageSize\s*=/)
    expect(source).not.toMatch(/const handlePageSizeChange\s*=/)
  })

  it('does NOT pass pageWidthInput / pageHeightInput as :value bindings', () => {
    expect(source).not.toMatch(/:\s*value="pageWidthInput"/)
    expect(source).not.toMatch(/:\s*value="pageHeightInput"/)
  })
})
