/** The theme contract: a theme is an entry in `src/theme/themes.ts` plus a
 * `:root[data-theme='<id>']` block in `style.css`. A theme that forgets a colour token or
 * `--color-scheme` inherits the default silently, and this spec is what catches that. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

import { THEMES } from '../theme/themes'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CSS = readFileSync(resolve(SRC, 'style.css'), 'utf8')

type Declarations = Map<string, string>

const parseDeclarations = (block: string): Declarations => {
  const declarations: Declarations = new Map()
  for (const match of block.matchAll(/^\s*(--[a-z0-9-]+):\s*(.+);\s*$/gm)) {
    const [, token, value] = match
    if (token && value) declarations.set(token, value.trim())
  }
  return declarations
}

const BASE_BLOCK = CSS.match(/^:root\s*\{([\s\S]*?)^\}/m)?.[1] ?? ''
const BASE = parseDeclarations(BASE_BLOCK)

const THEME_BLOCKS = new Map<string, Declarations>()
for (const match of CSS.matchAll(/^:root\[data-theme='([a-z0-9-]+)'\]\s*\{([\s\S]*?)^\}/gm)) {
  const [, id, block] = match
  if (id && block) THEME_BLOCKS.set(id, parseDeclarations(block))
}

/** A colour is anything a browser paints with; geometry (`32px`) is not a per-theme token. */
const isColour = (value: string): boolean =>
  /^(#[0-9a-fA-F]{3,8}|rgba?\(|hsla?\(|color-mix\(|oklch\()/.test(value)

const COLOUR_TOKENS = [...BASE].filter(([, value]) => isColour(value)).map(([token]) => token)

const missingIn = (block: Declarations): string[] =>
  COLOUR_TOKENS.filter((token) => !block.has(token))

describe('theme token coverage', () => {
  it('declares a palette block for every theme that is not the default', () => {
    const blockless = THEMES.filter((theme) => !theme.isDefault && !THEME_BLOCKS.has(theme.id))
    expect(blockless.map((theme) => theme.id)).toEqual([])
  })

  it('declares no block for a theme the registry does not ship', () => {
    const known = new Set<string>(THEMES.map((theme) => theme.id))
    const orphans = [...THEME_BLOCKS.keys()].filter((id) => !known.has(id))
    expect(orphans).toEqual([])
  })

  it('finds colour tokens in the base palette at all', () => {
    expect(COLOUR_TOKENS.length).toBeGreaterThan(40)
  })

  it.each([...THEME_BLOCKS.keys()])('overrides every base colour token in the %s theme', (id) => {
    const block = THEME_BLOCKS.get(id) ?? new Map<string, string>()
    expect(missingIn(block)).toEqual([])
  })

  it.each([...THEME_BLOCKS.keys()])('invents no token the base palette lacks in %s', (id) => {
    const unknown = [...(THEME_BLOCKS.get(id)?.keys() ?? [])].filter((token) => !BASE.has(token))
    expect(unknown).toEqual([])
  })

  it.each([...THEME_BLOCKS.keys()])('paints the %s theme in its registry scheme', (id) => {
    const scheme = THEMES.find((theme) => theme.id === id)?.scheme
    expect(THEME_BLOCKS.get(id)?.get('--color-scheme')).toBe(scheme)
  })

  it('paints the base palette in the default scheme', () => {
    expect(BASE.get('--color-scheme')).toBe(THEMES.find((theme) => theme.isDefault)?.scheme)
  })
})
