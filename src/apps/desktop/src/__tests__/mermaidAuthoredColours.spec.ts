import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MermaidPalette } from '../helpers/mermaid'
import { MERMAID_PALETTE_FALLBACK, _resetMermaidLoader, renderMermaid } from '../helpers/mermaid'
import { paintAuthoredColours } from '../helpers/mermaidPaint'
import { applyTheme } from '../theme/runtime'

const { initializeMock, renderMock } = vi.hoisted(() => ({
  initializeMock: vi.fn(),
  renderMock: vi.fn(),
}))

vi.mock('mermaid', () => ({ default: { initialize: initializeMock, render: renderMock } }))

const AUTHORED = `flowchart LR
  a["frame height 120px"] --> b["report 120px"]
  classDef plain fill:#282727,stroke:#7a8382,stroke-width:2px
  classDef bad fill:#282727,stroke:#c4746e,stroke-width:2px
  class a plain
  class b bad
  linkStyle default stroke:#7a8382`

const LIGHT: MermaidPalette = {
  ...MERMAID_PALETTE_FALLBACK,
  canvas: '#faf5d3',
  node: '#e9e0b4',
  edge: '#d5cea3',
  line: '#6b6757',
  ink: '#545464',
  muted: '#625f52',
  accent: '#45628f',
  roles: {
    blue: '#2f6f86',
    green: '#54703a',
    yellow: '#75652a',
    violet: '#624c83',
    pink: '#a04a68',
    orange: '#94520f',
    red: '#bd3f52',
    aqua: '#40635c',
  },
}

const LIGHT_TOKENS: Record<string, string> = {
  '--semantic-card-bg': LIGHT.canvas,
  '--color-bg-p1': LIGHT.node,
  '--color-bg-p2': LIGHT.edge,
  '--color-gray-3': LIGHT.line,
  '--semantic-text': LIGHT.ink,
  '--semantic-text-muted': LIGHT.muted,
  '--semantic-link': LIGHT.accent,
  '--color-blue': LIGHT.roles.blue,
  '--color-green': LIGHT.roles.green,
  '--color-yellow': LIGHT.roles.yellow,
  '--color-violet': LIGHT.roles.violet,
  '--color-pink': LIGHT.roles.pink,
  '--color-orange': LIGHT.roles.orange,
  '--color-red': LIGHT.roles.red,
  '--color-aqua': LIGHT.roles.aqua,
}

const themeTokens = (tokens: Record<string, string>): void => {
  vi.stubGlobal('getComputedStyle', () => ({
    getPropertyValue: (name: string) => tokens[name] ?? '',
  }))
}

const drawWhatItIsGiven = (): void => {
  renderMock.mockImplementation((_id: string, source: string) => {
    const colours = source.match(/(?:fill|stroke):\s*#[0-9a-f]{6}/gi) ?? []
    return Promise.resolve({ svg: `<svg data-colours="${colours.join(' ')}"></svg>` })
  })
}

const authoredColours = (source: string): string[] =>
  source.match(/#[0-9a-f]{6}/gi)?.map((hex) => hex.toLowerCase()) ?? []

beforeEach(() => {
  _resetMermaidLoader()
  initializeMock.mockClear()
  renderMock.mockReset()
  drawWhatItIsGiven()
  delete document.documentElement.dataset.theme
})

afterEach(() => {
  vi.unstubAllGlobals()
  applyTheme(document.documentElement, 'dark')
})

describe('an authored diagram in the light theme', () => {
  it('draws the shapes in the light surface and the light role accents, never the authored dark fill', async () => {
    themeTokens(LIGHT_TOKENS)
    applyTheme(document.documentElement, 'light')

    const svg = await renderMermaid(AUTHORED)

    expect(svg).toContain(`fill:${LIGHT.node}`)
    expect(svg).toContain(`stroke:${LIGHT.line}`)
    expect(svg).toContain(`stroke:${LIGHT.roles.red}`)
    expect(svg).not.toContain('#282727')
  })

  it('keeps the label ink off the shape surface, so the text is readable', async () => {
    themeTokens(LIGHT_TOKENS)
    applyTheme(document.documentElement, 'light')

    const painted = paintAuthoredColours(AUTHORED, LIGHT)

    expect(authoredColours(painted)).not.toContain('#282727')
    expect(LIGHT.node).not.toBe(LIGHT.ink)
  })

  it('repaints every colour the agent prompt hands the model', () => {
    const promptPalette = [
      '#1d1c19',
      '#282727',
      '#393836',
      '#7a8382',
      '#c5c9c5',
      '#a6a69c',
      '#8ba4b0',
      '#87a987',
      '#c4b28a',
      '#8992a7',
      '#a292a3',
      '#b6927b',
      '#c4746e',
      '#8ea4a2',
    ]
    const source = promptPalette
      .map((hex, index) => `classDef role${index} fill:${hex},stroke:${hex}`)
      .join('\n')

    expect(authoredColours(paintAuthoredColours(source, LIGHT))).toEqual(
      expect.not.arrayContaining(promptPalette),
    )
  })

  it('keeps a node label that mentions a colour verbatim', () => {
    const labelled = 'flowchart LR\n  a["the surface is #282727"] --> b\ntext with #c4746e'

    expect(paintAuthoredColours(labelled, LIGHT)).toBe(labelled)
  })

  it('leaves a diagram that declares no colours to the renderer', () => {
    const plain = 'flowchart LR\n  A[Ask] --> B[Diagram]'

    expect(paintAuthoredColours(plain, LIGHT)).toBe(plain)
  })
})

describe('an authored diagram in the dark theme', () => {
  it('keeps the authored literals, which are already the dark theme', async () => {
    themeTokens({})
    applyTheme(document.documentElement, 'dark')

    const svg = await renderMermaid(AUTHORED)

    expect(svg).toContain(`fill:${MERMAID_PALETTE_FALLBACK.node}`)
    expect(svg).toContain(`stroke:${MERMAID_PALETTE_FALLBACK.line}`)
    expect(svg).toContain('stroke:#c4746e')
  })

  it('renders the same diagram differently per theme', async () => {
    themeTokens({})
    applyTheme(document.documentElement, 'dark')
    const dark = await renderMermaid(AUTHORED)

    themeTokens(LIGHT_TOKENS)
    applyTheme(document.documentElement, 'light')
    const light = await renderMermaid(AUTHORED)

    expect(light).not.toBe(dark)
  })
})
