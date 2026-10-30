/** Behavioural tests for the diagram viewport maths — the part of "a diagram you can actually
 * read" that has an answer without a browser: how wide to lay it out in a column, and where the
 * pointer is while zooming and panning. */
import { describe, expect, it } from 'vitest'
import {
  MAX_ZOOM,
  MIN_INLINE_SCALE,
  clampZoom,
  fitZoom,
  fittedViewport,
  formatZoom,
  inlineDiagramLayout,
  panBy,
  parseDiagramSize,
  zoomAround,
} from '../diagramViewport'

describe('parseDiagramSize', () => {
  it('reads the drawing size out of the viewBox', () => {
    expect(parseDiagramSize('<svg viewBox="0 0 1240 640" width="100%"><g /></svg>')).toEqual({
      width: 1240,
      height: 640,
    })
  })

  it('falls back to numeric width and height attributes', () => {
    expect(parseDiagramSize('<svg width="300" height="180"></svg>')).toEqual({
      width: 300,
      height: 180,
    })
  })

  it('reports no size when the markup carries none', () => {
    expect(parseDiagramSize('<svg width="100%"></svg>')).toBeNull()
    expect(parseDiagramSize('')).toBeNull()
  })
})

describe('inlineDiagramLayout', () => {
  it('lays a diagram that fits the column out at its own size', () => {
    const layout = inlineDiagramLayout({ width: 700, height: 300 }, 800)
    expect(layout).toEqual({ scale: 1, width: 700, overflow: false })
  })

  it('never enlarges a diagram narrower than the column', () => {
    expect(inlineDiagramLayout({ width: 200, height: 120 }, 1200)?.width).toBe(200)
  })

  it('keeps a diagram far wider than the column at the legible floor and marks it overflowing', () => {
    const layout = inlineDiagramLayout({ width: 3000, height: 600 }, 800)
    expect(layout?.scale).toBe(MIN_INLINE_SCALE)
    expect(layout?.width).toBe(2250)
    expect(layout?.overflow).toBe(true)
  })

  it('reports nothing until both the drawing and the column have a size', () => {
    expect(inlineDiagramLayout(null, 800)).toBeNull()
    expect(inlineDiagramLayout({ width: 900, height: 400 }, 0)).toBeNull()
  })
})

describe('fitZoom', () => {
  it('fits the whole drawing inside the stage, by its tighter dimension', () => {
    expect(fitZoom({ width: 2000, height: 1000 }, { width: 1000, height: 800 })).toBe(0.5)
    expect(fitZoom({ width: 1000, height: 4000 }, { width: 1000, height: 800 })).toBe(0.2)
  })

  it('never enlarges a drawing that is already smaller than the stage', () => {
    expect(fitZoom({ width: 400, height: 300 }, { width: 1000, height: 800 })).toBe(1)
  })

  it('zooms from 100% when the drawing size is unknown', () => {
    expect(fitZoom(null, { width: 1000, height: 800 })).toBe(1)
    expect(fittedViewport(null, { width: 1000, height: 800 })).toEqual({ zoom: 1, x: 0, y: 0 })
  })
})

describe('zoomAround', () => {
  const stage = { width: 1000, height: 800 }
  const natural = { width: 2000, height: 800 }

  it('keeps the point under the pointer in place', () => {
    const zoomed = zoomAround({ zoom: 1, x: 0, y: 0 }, 2, { x: 100, y: 0 }, natural, stage)
    expect(zoomed.zoom).toBe(2)
    expect(zoomed.x).toBe(-100)
  })

  it('stops zooming out at the scale that shows the whole drawing', () => {
    expect(zoomAround({ zoom: 0.5, x: 0, y: 0 }, 0.1, { x: 0, y: 0 }, natural, stage).zoom).toBe(0.5)
  })

  it('stops zooming in at the maximum', () => {
    expect(zoomAround({ zoom: 4, x: 0, y: 0 }, 999, { x: 0, y: 0 }, natural, stage).zoom).toBe(
      MAX_ZOOM,
    )
  })

  it('pulls the drawing back once it no longer covers the stage', () => {
    const zoomed = zoomAround({ zoom: 1, x: 400, y: 0 }, 0.5, { x: 0, y: 0 }, natural, stage)
    expect(zoomed.zoom).toBe(0.5)
    expect(zoomed.x).toBe(0)
  })
})

describe('panBy', () => {
  const stage = { width: 1000, height: 800 }
  const natural = { width: 2000, height: 800 }

  it('stops when the drawing edge reaches the stage edge', () => {
    expect(panBy({ zoom: 1, x: 0, y: 0 }, 5000, 0, natural, stage).x).toBe(500)
    expect(panBy({ zoom: 1, x: 0, y: 0 }, -5000, 0, natural, stage).x).toBe(-500)
  })

  it('does not pan at all when the drawing already fits', () => {
    expect(panBy({ zoom: 0.5, x: 0, y: 0 }, 300, 300, natural, stage)).toEqual({
      zoom: 0.5,
      x: 0,
      y: 0,
    })
  })
})

describe('clampZoom', () => {
  it('keeps a zoom inside the range, and survives a broken factor', () => {
    expect(clampZoom(0.0001, 0.3)).toBe(0.3)
    expect(clampZoom(64, 0.3)).toBe(MAX_ZOOM)
    expect(clampZoom(Number.NaN, 0.3)).toBe(0.3)
  })
})

describe('formatZoom', () => {
  it('reads as a percentage', () => {
    expect(formatZoom(0.755)).toBe('76%')
    expect(formatZoom(1)).toBe('100%')
  })
})
