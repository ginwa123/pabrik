import type { Terminal } from '@xterm/xterm'
import { readThemeToken } from '../theme/runtime'

export interface XtermTheme {
  background: string
  foreground: string
  cursor: string
}

/** xterm paints into a canvas, so it cannot read a CSS variable: hand it the resolved values. Both
 * terminals in the app build their theme here, so they cannot drift into two different darks. */
export const resolveXtermTheme = (): XtermTheme => ({
  background: readThemeToken('--color-bg-dim', '#12120f'),
  foreground: readThemeToken('--semantic-text', '#c5c9c5'),
  cursor: readThemeToken('--semantic-text', '#c5c9c5'),
})

/** Re-paint a live terminal. Guarded on `options` because the unit-test fake has none. */
export function applyXtermTheme(term: Terminal | null): void {
  if (term?.options) term.options.theme = resolveXtermTheme()
}
