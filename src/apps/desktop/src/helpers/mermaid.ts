import type { MermaidConfig } from 'mermaid'

/** The colours and type a diagram is drawn in. Every field is a CSS custom property of the app
 * theme, so the diagram cannot drift from the transcript it sits in. */
export interface MermaidPalette {
  /** Diagram surface — the frame every shape sits on. */
  canvas: string
  /** Shape fill. */
  node: string
  /** Shape outline. */
  edge: string
  /** Connectors and arrows. */
  line: string
  /** Shape and edge label ink. */
  ink: string
  muted: string
  accent: string
  font: string
  /** Pie-slice colours, in palette order — the app's own accents, no new hues. */
  slices: string[]
}

/** Kanagawa Dragon literals, used when the CSS variables are unreachable (no DOM) or unset. Mirrors
 * `style.css` `:root` and ChatView's `HTML_FRAME_PALETTE_FALLBACK`. */
export const MERMAID_PALETTE_FALLBACK: MermaidPalette = {
  canvas: '#1D1C19',
  node: '#282727',
  edge: '#393836',
  line: '#7a8382',
  ink: '#c5c9c5',
  muted: '#a6a69c',
  accent: '#8ba4b0',
  font: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
  slices: ['#8ba4b0', '#87a987', '#c4b28a', '#8992a7', '#a292a3', '#b6927b', '#c4746e', '#8ea4a2'],
}

/** `pieN` takes a category colour, not a surface: these are the app's accent tokens, in order. */
const SLICE_VARS = [
  '--color-blue',
  '--color-green',
  '--color-yellow',
  '--color-violet',
  '--color-pink',
  '--color-orange',
  '--color-red',
  '--color-aqua',
]

const readVar = (name: string, fallback: string): string => {
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return fallback
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

let palette: MermaidPalette | null = null

/** Memoized — the app theme is fixed for the app's lifetime, and this runs for every diagram. */
export const resolveMermaidPalette = (): MermaidPalette => {
  if (palette) return palette
  const f = MERMAID_PALETTE_FALLBACK
  palette = {
    canvas: readVar('--semantic-card-bg', f.canvas),
    node: readVar('--color-bg-p1', f.node),
    edge: readVar('--color-bg-p2', f.edge),
    line: readVar('--color-gray-3', f.line),
    ink: readVar('--semantic-text', f.ink),
    muted: readVar('--semantic-text-muted', f.muted),
    accent: readVar('--semantic-link', f.accent),
    font: readVar('--font-sans', f.font),
    slices: SLICE_VARS.map((name, i) => readVar(name, f.slices[i] ?? f.accent)),
  }
  return palette
}

/**  * The theme is set once, at initialize: the diagram is authored by the model without colour
 * knowledge (`core.zig` forbids `%%{init}%%`), so the renderer owns every visual decision. */
const buildConfig = (p: MermaidPalette): MermaidConfig => ({
  startOnLoad: false,
  securityLevel: 'strict',
  theme: 'base',
  fontFamily: p.font,
  // Root-level, NOT `flowchart.htmlLabels` — mermaid 12 deprecated the per-diagram key and the
  // root one wins. SVG `<text>` labels stay immune to the app's Tailwind preflight; a
  // `<foreignObject>` label is real HTML in the transcript's own document and inherits it.
  htmlLabels: false,
  themeVariables: {
    darkMode: true,
    fontSize: '14px',
    background: p.canvas,
    primaryColor: p.node,
    primaryTextColor: p.ink,
    primaryBorderColor: p.edge,
    secondaryColor: p.node,
    secondaryTextColor: p.ink,
    secondaryBorderColor: p.edge,
    tertiaryColor: p.canvas,
    tertiaryTextColor: p.ink,
    tertiaryBorderColor: p.edge,
    mainBkg: p.node,
    nodeBorder: p.edge,
    nodeTextColor: p.ink,
    textColor: p.ink,
    titleColor: p.ink,
    lineColor: p.line,
    arrowheadColor: p.line,
    edgeLabelBackground: p.canvas,
    clusterBkg: p.canvas,
    clusterBorder: p.edge,
    // Sequence/state/note surfaces — same three tones, no fourth.
    actorBkg: p.node,
    actorBorder: p.edge,
    actorTextColor: p.ink,
    actorLineColor: p.line,
    signalColor: p.line,
    signalTextColor: p.ink,
    labelBoxBkgColor: p.node,
    labelBoxBorderColor: p.edge,
    labelTextColor: p.ink,
    loopTextColor: p.ink,
    noteBkgColor: p.node,
    noteBorderColor: p.edge,
    noteTextColor: p.ink,
    activationBkgColor: p.node,
    activationBorderColor: p.edge,
    sequenceNumberColor: p.canvas,
    pie1: p.slices[0],
    pie2: p.slices[1],
    pie3: p.slices[2],
    pie4: p.slices[3],
    pie5: p.slices[4],
    pie6: p.slices[5],
    pie7: p.slices[6],
    pie8: p.slices[7],
  },
  // Root-level `htmlLabels: false` (above) already forces SVG `<text>` labels; the per-diagram key
  // is DEPRECATED in mermaid 12 and ignored, so it is not repeated here.
  flowchart: { useMaxWidth: true, padding: 8 },
  sequence: { useMaxWidth: true },
  gantt: { useMaxWidth: true },
})

type MermaidApi = (typeof import('mermaid'))['default']

let api: Promise<MermaidApi> | null = null

/** Lazily pull in Mermaid (a large dependency) and initialize it once, on the first diagram of the
 * session — a transcript with no diagrams never pays for it. */
export const loadMermaid = (): Promise<MermaidApi> => {
  if (api === null) {
    api = import('mermaid')
      .then(({ default: mermaid }) => {
        mermaid.initialize(buildConfig(resolveMermaidPalette()))
        return mermaid
      })
      // A failed chunk load (offline, a stale deploy) must not poison every later diagram: drop the
      // cached promise so the next mount retries, and let the caller surface the reason.
      .catch((cause: unknown) => {
        api = null
        throw cause
      })
  }
  return api
}

/** Test-only reset — not exported through the helpers barrel (`helpers/index.ts`). */
export const _resetMermaidLoader = (): void => {
  api = null
  palette = null
}

let renderSeq = 0

/** Render Mermaid source to SVG markup. `mermaid.render` needs a unique, DOM-safe id per call: it
 * writes a temporary node under it and scopes the generated stylesheet to `#<id>`. */
export const renderMermaid = async (source: string): Promise<string> => {
  const mermaid = await loadMermaid()
  renderSeq += 1
  const { svg } = await mermaid.render(`chat-mermaid-${renderSeq}`, source)
  return svg
}
