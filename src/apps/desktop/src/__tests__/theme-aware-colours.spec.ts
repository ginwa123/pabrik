/** A surface that paints a Tailwind palette colour does not flip with `data-theme`, so light-red ink
 * lands on a light card and disappears. Every painted colour comes from a token in `style.css`.
 * `UNPAINTED` is the exception: a scrim and a media letterbox must darken in every scheme. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const PALETTE_CLASS =
  /(?<![\w-])(?:(?:[a-z-]+):)*(?:!)?(?:bg|text|border|ring|fill|stroke|divide|placeholder|decoration|outline|from|via|to|shadow|accent|caret)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|white|black)(?:-\d{2,3})?(?:\/(?:\d{1,3}|\[[\d.]+\]))?(?![\w-])/g

const UNPAINTED = /^(?:bg-black(?:\/(?:[5-9]\d|100))?|text-white|text-black)$/

const SOURCES = ((): string[] => {
  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) {
        return entry.name === '__tests__' || entry.name === 'stubs' ? [] : walk(path)
      }
      const isSource =
        /\.(?:vue|ts|css)$/.test(entry.name) &&
        !entry.name.endsWith('.spec.ts') &&
        entry.name !== 'style.css'
      return isSource ? [path] : []
    })
  return walk(SRC)
})()

const offenders = SOURCES.flatMap((file) =>
  [...readFileSync(file, 'utf8').matchAll(PALETTE_CLASS)]
    .map((match) => match[0])
    .filter((className) => !UNPAINTED.test(className))
    .map((className) => `${relative(SRC, file)}: ${className}`),
)

const declaredTokens = new Set(
  [...SOURCES, resolve(SRC, 'style.css')].flatMap((file) =>
    [...readFileSync(file, 'utf8').matchAll(/(?<![\w-])(--[a-z0-9-]+)['"]?\s*:/g)].map(
      (match) => match[1],
    ),
  ),
)

const namedTokens = SOURCES.flatMap((file) =>
  [...readFileSync(file, 'utf8').matchAll(/var\((--[a-z0-9-]+)\s*[,)]/g)].map((match) => ({
    file: relative(SRC, file),
    token: match[1]!,
  })),
)

const undeclared = namedTokens
  .filter((named) => !declaredTokens.has(named.token))
  .map((named) => `${named.file}: ${named.token}`)

describe('every painted colour is a theme token', () => {
  it('declares the tokens a component names', () => {
    expect(undeclared).toEqual([])
  })

  it('paints no surface with a Tailwind palette colour', () => {
    expect(offenders).toEqual([])
  })
})
