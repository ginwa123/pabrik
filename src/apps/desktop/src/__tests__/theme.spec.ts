import { beforeEach, describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { createPinia, setActivePinia } from 'pinia'
import {
  DEFAULT_THEME,
  THEME_STORAGE_KEY,
  isThemeName,
  readStoredTheme,
  type ThemeName,
} from '../theme/themes'
import {
  activeScheme,
  activeTheme,
  applyTheme,
  initTheme,
  onThemeApplied,
  readThemeToken,
} from '../theme/runtime'
import { useThemeStore } from '../stores/theme'
import { makeLocalStorageStub } from './helpers'

const root = (): HTMLElement => document.documentElement

function mountStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
}

describe('theme registry', () => {
  it('reads a stored theme back', () => {
    const storage = makeLocalStorageStub()
    storage.setItem(THEME_STORAGE_KEY, 'light')
    expect(readStoredTheme(storage)).toBe('light')
  })

  it('falls back to the default theme for a value no theme owns', () => {
    const storage = makeLocalStorageStub()
    storage.setItem(THEME_STORAGE_KEY, 'neon')
    expect(readStoredTheme(storage)).toBe(DEFAULT_THEME)
  })

  it('falls back to the default theme when storage is unreachable', () => {
    expect(readStoredTheme(null)).toBe(DEFAULT_THEME)
  })

  it('knows only the themes it ships', () => {
    expect(isThemeName('light')).toBe(true)
    expect(isThemeName('neon')).toBe(false)
  })
})

describe('theme runtime', () => {
  beforeEach(() => {
    mountStorage()
    delete root().dataset.theme
  })

  it('paints the stored theme on the root element at boot', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'light')
    initTheme(root())
    expect(root().dataset.theme).toBe('light')
  })

  it('paints the default theme at boot when nothing is stored', () => {
    initTheme(root())
    expect(root().dataset.theme).toBe(DEFAULT_THEME)
  })

  it('tells every subscriber each time a theme is applied', () => {
    const heard: ThemeName[] = []
    const off = onThemeApplied(() => heard.push(activeTheme()))

    applyTheme(root(), 'light')
    applyTheme(root(), 'dark')

    off()
    applyTheme(root(), 'light')

    expect(heard).toEqual(['light', 'dark'])
  })

  it('reports the scheme of the theme on screen, so JS-painted surfaces follow it', () => {
    applyTheme(root(), 'light')
    expect(activeScheme()).toBe('light')
    applyTheme(root(), 'dark')
    expect(activeScheme()).toBe('dark')
  })

  it('hands a dark literal to a renderer when no stylesheet is reachable', () => {
    expect(readThemeToken('--semantic-card-bg', '#1D1C19')).toBe('#1D1C19')
  })
})

describe('theme store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mountStorage()
    delete root().dataset.theme
  })

  it('paints the app and remembers the choice for the next launch', () => {
    useThemeStore().setTheme('light')

    expect(root().dataset.theme).toBe('light')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('light')

    setActivePinia(createPinia())
    expect(useThemeStore().theme).toBe('light')
  })

  it('starts from the theme the last launch stored', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'light')
    expect(useThemeStore().theme).toBe('light')
  })

  it('refuses a theme id the registry does not know', () => {
    const store = useThemeStore()
    store.setTheme('neon' as ThemeName)

    expect(store.theme).toBe(DEFAULT_THEME)
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBeNull()
  })
})

describe('pre-paint script', () => {
  it('reads the same storage key the app writes', () => {
    const indexHtml = resolve(dirname(fileURLToPath(import.meta.url)), '../../index.html')
    expect(readFileSync(indexHtml, 'utf8')).toContain(`localStorage.getItem('${THEME_STORAGE_KEY}')`)
  })
})
