import type { MermaidPalette } from './mermaid'

type PaletteSlot = (palette: MermaidPalette) => string

const AUTHORED_LITERALS: ReadonlyArray<readonly [authored: string, slot: PaletteSlot]> = [
  ['#1d1c19', (p) => p.canvas],
  ['#282727', (p) => p.node],
  ['#393836', (p) => p.edge],
  ['#7a8382', (p) => p.line],
  ['#c5c9c5', (p) => p.ink],
  ['#a6a69c', (p) => p.muted],
  ['#8ba4b0', (p) => p.roles.blue],
  ['#87a987', (p) => p.roles.green],
  ['#c4b28a', (p) => p.roles.yellow],
  ['#8992a7', (p) => p.roles.violet],
  ['#a292a3', (p) => p.roles.pink],
  ['#b6927b', (p) => p.roles.orange],
  ['#c4746e', (p) => p.roles.red],
  ['#8ea4a2', (p) => p.roles.aqua],
]

const PAINTED_LINE = /^\s*(?:classDef|style|linkStyle)\b/i

export const paintAuthoredColours = (source: string, palette: MermaidPalette): string =>
  source
    .split('\n')
    .map((line) => {
      if (!PAINTED_LINE.test(line)) return line
      return AUTHORED_LITERALS.reduce(
        (painted, [authored, slot]) => painted.replace(new RegExp(authored, 'gi'), slot(palette)),
        line,
      )
    })
    .join('\n')
