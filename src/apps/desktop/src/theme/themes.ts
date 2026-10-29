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
    id: 'light',
    label: 'Light',
    description: 'Kanagawa Lotus — the same palette seen in daylight, hues unchanged.',
    scheme: 'light',
    isDefault: false,
    swatch: { bg: '#f2ecbc', card: '#faf5d3', fg: '#545464', accent: '#624c83' },
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
