import { ref } from 'vue'
import {
  DEFAULT_THEME,
  THEME_STORAGE_KEY,
  isThemeName,
  schemeOf,
  type ThemeName,
  type ThemeScheme,
} from './themes'

/** Bumped on every applied theme. A surface that bakes a palette into a rendered artefact (an SVG,
 * an iframe srcdoc, an xterm instance) reads this so the artefact is rebuilt instead of keeping the
 * colours of the theme it was first drawn in. */
export const themeRevision = ref(0)

const listeners = new Set<() => void>()

/** Paint `theme` on `root` and tell every subscriber. The DOM attribute is the only state a
 * stylesheet needs, so nothing else has to be kept in sync with the palette. */
export function applyTheme(root: HTMLElement, theme: ThemeName): void {
  root.dataset.theme = theme
  themeRevision.value += 1
  for (const listener of listeners) listener()
}

/** Subscribe to theme applications; returns the unsubscribe function (same shape as the SSE bus). */
export function onThemeApplied(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

const themeStorage = (): Pick<Storage, 'getItem' | 'setItem'> | null =>
  typeof localStorage === 'undefined' ? null : localStorage

export function persistTheme(theme: ThemeName): void {
  themeStorage()?.setItem(THEME_STORAGE_KEY, theme)
}

/** Re-apply the stored theme on the root at boot. The PRE-PAINT application, before this module
 * graph loads, is the inline script in `index.html`. */
export function initTheme(root: HTMLElement = document.documentElement): ThemeName {
  const stored = themeStorage()?.getItem(THEME_STORAGE_KEY)
  const theme: ThemeName = isThemeName(stored) ? stored : DEFAULT_THEME
  applyTheme(root, theme)
  return theme
}

/** The theme on screen right now. Read from the DOM, not from a copy, so a helper that runs outside
 * a component sees what the user sees. */
export function activeTheme(): ThemeName {
  if (typeof document === 'undefined') return DEFAULT_THEME
  const applied = document.documentElement.dataset.theme
  return isThemeName(applied) ? applied : DEFAULT_THEME
}

export const activeScheme = (): ThemeScheme => schemeOf(activeTheme())

/** A token's computed value, for the surfaces that must hand a literal colour to a renderer that
 * cannot see the cascade (canvas, SVG, iframe, terminal). `fallback` is the dark-theme literal: it
 * is the value a DOM-less test sees, which keeps those renderers deterministic. */
export function readThemeToken(name: string, fallback: string): string {
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return fallback
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}
