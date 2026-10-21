import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

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
