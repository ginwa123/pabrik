/** A diagram's own drawing size, in CSS pixels at 100% zoom. */
export interface DiagramSize {
  width: number
  height: number
}

/** A viewer's pan/zoom state: `x`/`y` are pixel offsets from the stage centre. */
export interface DiagramViewport {
  zoom: number
  x: number
  y: number
}

export interface DiagramPoint {
  x: number
  y: number
}

export interface InlineDiagramLayout {
  scale: number
  /** Width the drawing is laid out at, in px. */
  width: number
  /** True when the drawing is wider than the column, so the frame has to scroll. */
  overflow: boolean
}

/** Floor that keeps the renderer's 14px labels readable: below this a diagram scrolls instead of
 * shrinking. 0.75 keeps them at ~10.5px, which is the smallest legible step. */
export const MIN_INLINE_SCALE = 0.75

/** Ceiling for the viewer — past 8x an SVG is all pixels and an <img> is all blur. */
export const MAX_ZOOM = 8

export const ZOOM_STEP = 1.25

/** How much the viewer may ENLARGE a small drawing on open. SVG is lossless, but past 2x the line
 * weights read as fat rather than as a bigger diagram. */
export const MAX_OPEN_UPSCALE = 2

export const KEYBOARD_PAN_PX = 96

/** Used when the stage has no measurable box (jsdom, or the first frame after mount). */
export const STAGE_FALLBACK: DiagramSize = { width: 1024, height: 768 }

const floorZoom = (): number => 0.02

const pxAttribute = (markup: string, name: string): number | null => {
  const match = new RegExp(`${name}\\s*=\\s*["']\\s*(\\d+(?:\\.\\d+)?)\\s*(?:px)?\\s*["']`, 'i').exec(
    markup,
  )
  const raw = match?.[1]
  if (!raw) return null
  const value = Number(raw)
  return Number.isFinite(value) && value > 0 ? value : null
}

/** Read the drawing's intrinsic size out of its own markup, so the inline layout never needs a
 * laying-out browser. A `viewBox` wins: mermaid and PlantUML both publish `width="100%"` with the
 * real numbers only in the viewBox. */
export function parseDiagramSize(markup: string): DiagramSize | null {
  const box = /viewBox\s*=\s*["']([^"']+)["']/i.exec(markup)?.[1]
  if (box) {
    const parts = box.split(/[\s,]+/).map(Number)
    const width = parts[2] ?? 0
    const height = parts[3] ?? 0
    if (width > 0 && height > 0) return { width, height }
  }
  const width = pxAttribute(markup, 'width')
  const height = pxAttribute(markup, 'height')
  if (width === null || height === null) return null
  return { width, height }
}

/** How wide to lay a drawing out inside a column: 1:1 while it fits, then step down only as far as
 * the legibility floor — past that it keeps its width and the frame scrolls. */
export function inlineDiagramLayout(
  natural: DiagramSize | null,
  available: number,
): InlineDiagramLayout | null {
  if (!natural || natural.width <= 0 || !Number.isFinite(available) || available <= 0) return null
  const scale = Math.min(1, Math.max(MIN_INLINE_SCALE, available / natural.width))
  const width = Math.round(natural.width * scale)
  return { scale, width, overflow: width > available }
}

/** The whole drawing visible at once, never blown up past 100%. */
export function fitZoom(natural: DiagramSize | null, stage: DiagramSize): number {
  if (!natural || natural.width <= 0 || natural.height <= 0) return 1
  if (stage.width <= 0 || stage.height <= 0) return 1
  const fit = Math.min(stage.width / natural.width, stage.height / natural.height)
  return Math.min(1, Math.max(floorZoom(), fit))
}

/** The zoom a viewer OPENS at (and returns to with "Fit"): the whole drawing, floating between the
 * inline legibility floor and `MAX_OPEN_UPSCALE` — a fitted 5% view is as unreadable as the column
 * was, and a fitted 600% view of a two-node sketch is a joke. */
export function openZoom(natural: DiagramSize | null, stage: DiagramSize): number {
  if (!natural || natural.width <= 0 || natural.height <= 0) return 1
  if (stage.width <= 0 || stage.height <= 0) return 1
  const contain = Math.min(stage.width / natural.width, stage.height / natural.height)
  return Math.min(MAX_OPEN_UPSCALE, Math.max(MIN_INLINE_SCALE, contain))
}

export function clampZoom(zoom: number, min: number = floorZoom(), max: number = MAX_ZOOM): number {
  if (!Number.isFinite(zoom)) return min
  return Math.min(max, Math.max(min, zoom))
}

const panLimit = (content: number, stage: number, zoom: number): number => {
  if (content <= 0 || stage <= 0) return 0
  return Math.max(0, (content * zoom - stage) / 2)
}

/** Keep the drawing covering the stage: an edge can reach the stage edge, never pull past it. */
export function clampViewport(
  state: DiagramViewport,
  natural: DiagramSize | null,
  stage: DiagramSize,
): DiagramViewport {
  const limitX = panLimit(natural?.width ?? 0, stage.width, state.zoom)
  const limitY = panLimit(natural?.height ?? 0, stage.height, state.zoom)
  return {
    zoom: state.zoom,
    x: Math.min(limitX, Math.max(-limitX, state.x)),
    y: Math.min(limitY, Math.max(-limitY, state.y)),
  }
}

/** Zoom while holding the point under the pointer still — the difference between a diagram that
 * grows away from the cursor and one that grows where you are looking. */
export function zoomAround(
  state: DiagramViewport,
  nextZoom: number,
  anchor: DiagramPoint,
  natural: DiagramSize | null,
  stage: DiagramSize,
): DiagramViewport {
  const zoom = clampZoom(nextZoom, fitZoom(natural, stage))
  const ratio = state.zoom > 0 ? zoom / state.zoom : 1
  return clampViewport(
    {
      zoom,
      x: anchor.x - (anchor.x - state.x) * ratio,
      y: anchor.y - (anchor.y - state.y) * ratio,
    },
    natural,
    stage,
  )
}

export function panBy(
  state: DiagramViewport,
  dx: number,
  dy: number,
  natural: DiagramSize | null,
  stage: DiagramSize,
): DiagramViewport {
  return clampViewport({ zoom: state.zoom, x: state.x + dx, y: state.y + dy }, natural, stage)
}

/** The state a viewer opens in: the whole drawing, centred. */
export function fittedViewport(natural: DiagramSize | null, stage: DiagramSize): DiagramViewport {
  return { zoom: openZoom(natural, stage), x: 0, y: 0 }
}

export function formatZoom(zoom: number): string {
  return `${Math.round(zoom * 100)}%`
}
