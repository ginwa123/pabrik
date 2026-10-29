/** The app's theme registry — the ONE list of themes. Adding a theme is two edits: an entry here and
 * a `:root[data-theme='<id>']` block in `style.css` holding its colour tokens. The settings UI, the
 * boot code and the token-coverage spec all read this list, so nothing else has to learn the name. */
export type ThemeScheme = 'dark' | 'light'

interface ThemeDefinitionShape {
  readonly id: string
  readonly label: string
  readonly description: string
  /** Base colour scheme the theme paints. Drives native controls and the surfaces coloured in JS
   * (xterm, mermaid, monaco) that cannot read a CSS variable. */
  readonly scheme: ThemeScheme
  /** `true` for the theme whose tokens are the base `:root` block in style.css. */
  readonly isDefault: boolean
  /** Tile preview in Settings. Literal colours, not tokens: the tile draws a theme that may not be
   * the applied one, so it cannot read the live cascade. */
  readonly swatch: {
    readonly bg: string
    readonly card: string
    readonly fg: string
    readonly accent: string
  }
}

/** Display order: the dark family first, then the light one. */
export const THEMES = [
  {
    id: 'dark',
    label: 'Dark',
    description: 'Kanagawa Dragon — the low-light woodblock palette this app was designed in.',
    scheme: 'dark',
    isDefault: true,
    swatch: { bg: '#181616', card: '#1D1C19', fg: '#c5c9c5', accent: '#8992a7' },
  },
  {
    id: 'one-dark-pro',
    label: 'One Dark Pro',
    description: 'Atom’s iconic charcoal layout with pastel syntax colours.',
    scheme: 'dark',
    isDefault: false,
    swatch: { bg: '#282c34', card: '#2c313a', fg: '#abb2bf', accent: '#c678dd' },
  },
  {
    id: 'github-dark',
    label: 'GitHub Dark',
    description: 'GitHub’s own night canvas — near-black page, one clear blue accent.',
    scheme: 'dark',
    isDefault: false,
    swatch: { bg: '#0d1117', card: '#161b22', fg: '#e6edf3', accent: '#58a6ff' },
  },
  {
    id: 'dracula',
    label: 'Dracula Official',
    description: 'Purple dusk with neon syntax accents — high contrast, unmistakable.',
    scheme: 'dark',
    isDefault: false,
    swatch: { bg: '#282a36', card: '#343746', fg: '#f8f8f2', accent: '#bd93f9' },
  },
  {
    id: 'tokyo-night',
    label: 'Tokyo Night',
    description: 'Deep blue-violet night, read sharp on any language.',
    scheme: 'dark',
    isDefault: false,
    swatch: { bg: '#1a1b26', card: '#1f2335', fg: '#c0caf5', accent: '#bb9af7' },
  },
  {
    id: 'catppuccin',
    label: 'Catppuccin',
    description: 'Macchiato: creamy pastels on a soft indigo night.',
    scheme: 'dark',
    isDefault: false,
    swatch: { bg: '#24273a', card: '#2c3047', fg: '#cad3f5', accent: '#c6a0f6' },
  },
  {
    id: 'light',
    label: 'Light',
    description: 'Kanagawa Lotus — the same palette seen in daylight, hues unchanged.',
    scheme: 'light',
    isDefault: false,
    swatch: { bg: '#f2ecbc', card: '#faf5d3', fg: '#545464', accent: '#624c83' },
  },
  {
    id: 'github-light',
    label: 'GitHub Light',
    description: 'Primer white and grey, one blue accent — the palette engineers read fluently.',
    scheme: 'light',
    isDefault: false,
    swatch: { bg: '#ffffff', card: '#f6f8fa', fg: '#1f2328', accent: '#0969da' },
  },
  {
    id: 'atom-one-light',
    label: 'Atom One Light',
    description: 'Warm off-white and soft greys, with Atom’s violet accent.',
    scheme: 'light',
    isDefault: false,
    swatch: { bg: '#fafafa', card: '#ffffff', fg: '#383a42', accent: '#a626a4' },
  },
] as const satisfies readonly ThemeDefinitionShape[]

export type ThemeDefinition = (typeof THEMES)[number]
export type ThemeName = ThemeDefinition['id']

export const DEFAULT_THEME: ThemeName = 'dark'
export const THEME_STORAGE_KEY = 'pabrik-theme'

export const isThemeName = (value: unknown): value is ThemeName =>
  typeof value === 'string' && THEMES.some((theme) => theme.id === value)

export const findTheme = (id: ThemeName): ThemeDefinition | undefined =>
  THEMES.find((theme) => theme.id === id)

/** A theme's base scheme, defaulting to dark for an id the registry does not know. */
export const schemeOf = (id: string): ThemeScheme => (findTheme(id as ThemeName)?.scheme ?? 'dark')

/** The stored theme, or the default when nothing valid is stored. `storage` is injected so a test
 * can hand in a fake instead of a global. */
export function readStoredTheme(storage: Pick<Storage, 'getItem'> | null): ThemeName {
  const stored = storage?.getItem(THEME_STORAGE_KEY)
  return isThemeName(stored) ? stored : DEFAULT_THEME
}
