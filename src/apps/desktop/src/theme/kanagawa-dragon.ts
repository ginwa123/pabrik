/** Kanagawa Dragon Theme
 * A dark, atmospheric colorscheme inspired by Japanese woodblock prints
 * Based on kanagawa.nvim colorscheme by rebelot */
export const kanagawa = {
  // Background shades
  colors: {
    // Base backgrounds (dark)
    bgDim: '#12120f',
    bgGutter: '#282727',
    bgM3: '#0d0c0c',
    bgM2: '#12120f',
    bgM1: '#1D1C19',
    bg: '#181616',
    bgP1: '#282727',
    bgP2: '#393836',

    // Text
    fg: '#c5c9c5',
    fgDim: '#C8C093',
    fgReverse: '#223249',

    // Grays
    gray: '#a6a69c',
    gray2: '#9e9b93',
    gray3: '#7a8382',

    // Accent colors
    violet: '#8992a7',
    aqua: '#8ea4a2',
    yellow: '#c4b28a',
    blue: '#8ba4b0',
    green: '#87a987',
    green2: '#8a9a7b',
    pink: '#a292a3',
    orange: '#b6927b',
    red: '#c4746e',
    ash: '#737c73',

    // Special
    special: '#7a8382',
    whitespace: '#625e5a',
    nontext: '#625e5a',

    // UI states
    blue1: '#223249',
    blue2: '#2D4F67',

    // Border
    border: '#625e5a',
    borderLight: '#393836',
  },

  // Semantic tokens for common use cases
  semantic: {
    // Surfaces
    sidebarBg: '#12120f',
    sidebarBorder: '#282727',
    contentBg: '#181616',
    cardBg: '#1D1C19',

    // Text
    text: '#c5c9c5',
    textMuted: '#a6a69c',
    textDim: '#7a8382',

    // Interactive
    link: '#8ba4b0',
    linkHover: '#a3d4d5',
    accent: '#8992a7',
    accentHover: '#9CABCA',

    // Status
    success: '#87a987',
    warning: '#c4b28a',
    error: '#c4746e',
    info: '#8ba4b0',

    // Active states
    activeBg: '#282727',
    activeText: '#c5c9c5',
    hoverBg: '#1D1C19',
    hoverText: '#d5cea3',
  },
} as const

export type KanagawaTheme = typeof kanagawa

// CSS custom properties generator
export function generateCSSVariables(): string {
  const vars: string[] = []

  // Direct colors
  Object.entries(kanagawa.colors).forEach(([key, value]) => {
    vars.push(`--color-${key}: ${value};`)
  })

  // Semantic tokens
  Object.entries(kanagawa.semantic).forEach(([key, value]) => {
    vars.push(`--semantic-${key}: ${value};`)
  })

  return vars.join('\n  ')
}
