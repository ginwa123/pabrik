import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

/** The app's base layer. A CSS declaration the browser drops is invisible in the unit suite and
 *  fatal on screen, so the base layer is checked here against what a browser actually accepts. */
const SRC = join(__dirname, '..')
const CSS = readFileSync(join(SRC, 'style.css'), 'utf8')

/** The `body { … }` rule inside `@layer base`. */
const baseBodyRule = (): string => {
  const layer = CSS.slice(CSS.indexOf('@layer base'))
  const start = layer.indexOf('body {')
  expect(start).toBeGreaterThan(-1)
  return layer.slice(start, layer.indexOf('}', start))
}

describe('the app base layer', () => {
  it('gives the body a colour the browser accepts', () => {
    // `text-[--color-fg]` is Tailwind v3's spelling; under v4 it compiles to the literal
    // `color:--color-fg`, which the browser drops. The body then has NO colour, and every text
    // that does not name its own inherits the browser's black — invisible on the dark theme.
    const rule = baseBodyRule()
    expect(rule).toContain('text-(--color-fg)')
    expect(rule).not.toContain('text-[--color-fg]')
  })

  it('gives the body a background the browser accepts', () => {
    const rule = baseBodyRule()
    expect(rule).toContain('bg-(--color-bg)')
    expect(rule).not.toContain('bg-[--color-bg]')
  })
})

/** Every file whose class strings Tailwind compiles. Spec files are excluded: they name the banned
 *  spellings inside the guards that hunt for them. */
function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '__snapshots__') continue
    const path = join(dir, name)
    if (statSync(path).isDirectory()) sourceFiles(path, out)
    else if (/\.(vue|ts|css)$/.test(path) && !path.endsWith('.spec.ts')) out.push(path)
  }
  return out
}

/** Tailwind v3's `border-[--color-border]`: v4 emits the bare token as the value, the browser drops
 *  the declaration, and border-color falls back to currentColor — the sidebar's near-white rules.
 *  Comments are stripped first: a quoted spelling there is history, not a class. */
const V3_VAR_UTILITY = /(?<![\w-])[a-z-]+-\[--[a-z0-9-]+\]/i
const withoutComments = (src: string): string =>
  src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/^\s*\/\/.*$/gm, '')

describe('the app source', () => {
  it('never names a CSS-variable utility the Tailwind v3 way', () => {
    const offenders: string[] = []
    for (const file of sourceFiles(SRC)) {
      withoutComments(readFileSync(file, 'utf8'))
        .split('\n')
        .forEach((line, index) => {
          if (V3_VAR_UTILITY.test(line)) offenders.push(`${relative(SRC, file)}:${index + 1}`)
        })
    }
    expect(offenders).toEqual([])
  })
})
