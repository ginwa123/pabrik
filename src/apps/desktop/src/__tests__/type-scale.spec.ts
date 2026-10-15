/**
 * The app-wide type contract.
 *
 * The complaint that produced this file: font sizes had drifted into nine
 * hand-rolled arbitrary values (0.6rem, 0.65rem, 9px, 10px, 0.7rem,
 * 0.72rem, 11px, 0.8rem, 13px) plus Tailwind's own numeric ladder, with
 * the same visual size spelled four different ways. Nothing asserted a
 * measurement, so the next component was free to invent a tenth.
 *
 * The rule this enforces is simple: there is exactly one list of font
 * sizes and one list of font weights, in style.css's @theme block, and
 * every component picks a step off it by ROLE. A raw `text-[11px]` or a
 * bare `text-xs` fails here rather than in a screenshot review.
 *
 * Deliberately NOT a pixel-diff: that fails on a 1px antialiasing change
 * and passes on a 12px indent regression.
 *
 * Note: no `expect(value, message)` form — eslint-plugin-jest/valid-expect
 * rejects a second argument, so per-file context goes in the failure text
 * via the collected map instead.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative, resolve } from 'node:path'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/** The scale, and the pixels behind it. This list is the SPEC; style.css is
 * the implementation. If someone retunes a step, this assertion is the one
 * place that has to be updated in step with it. */
const SCALE: Record<string, string> = {
  '--text-micro': '10px',
  '--text-meta': '11px',
  '--text-dense': '12px',
  '--text-body': '14px',
  '--text-lead': '16px',
  '--text-title-sm': '18px',
  '--text-title': '20px',
  '--text-title-lg': '24px',
  '--text-display': '30px',
  '--text-display-lg': '36px',
}

const WEIGHTS: Record<string, string> = {
  '--font-weight-normal': '400',
  '--font-weight-medium': '500',
  '--font-weight-semibold': '600',
  '--font-weight-bold': '700',
}

/** `text-<step>` is the only accepted way to name a size in markup. */
const STEPS = Object.keys(SCALE).map((token) => token.replace('--text-', ''))
const SIZE_CLASS_RE = new RegExp(`(?<![\\w-])text-(${STEPS.join('|')})(?![\\w-])`)

/** Tailwind's numeric ladder. Still shipped by Tailwind, banned here. */
const BANNED_SIZES = ['xs', 'sm', 'base', 'lg', 'xl', '2xl', '3xl', '4xl']
const BANNED_SIZE_RE = new RegExp(`(?<![\\w-])text-(${BANNED_SIZES.join('|')})(?![\\w-]|-)`)

/** Any `text-[…]` whose payload is a length rather than a colour. */
const RAW_LENGTH_RE = /(?<![\w-])text-\[\s*[\d.]+(px|rem|em)\s*\]/

const BANNED_WEIGHTS = new Set(['thin', 'extralight', 'light', 'extrabold', 'black'])

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '__snapshots__') continue
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (/\.(vue|ts)$/.test(p)) out.push(p)
  }
  return out
}

const COMPONENT_FILES = walk(SRC).filter((p) => !p.endsWith('.spec.ts'))
const CSS = readFileSync(join(SRC, 'style.css'), 'utf8')

/**
 * Only the TEMPLATE and the class strings of a component are under
 * contract — a spec file legitimately contains `text-xs` inside the regex
 * that hunts for banned classes, and this file's own doc comment names the
 * old spellings. So specs are excluded from the scan.
 */
function collect(pick: (line: string) => string | null): Record<string, string[]> {
  const found: Record<string, string[]> = {}
  for (const file of COMPONENT_FILES) {
    const bad: string[] = []
    readFileSync(file, 'utf8')
      .split('\n')
      .forEach((text, i) => {
        const hit = pick(text)
        if (hit) bad.push(`line ${i + 1}: ${hit}`)
      })
    if (bad.length) found[relative(SRC, file)] = bad
  }
  return found
}

describe('type scale', () => {
  it('defines every size step and weight in style.css', () => {
    const missing = [...Object.entries(SCALE), ...Object.entries(WEIGHTS)]
      .filter(([name, value]) => !new RegExp(`${name}:\\s*${value}\\s*;`).test(CSS))
      .map(([name, value]) => `${name} should be ${value}`)
    expect(missing).toEqual([])
  })

  it('keeps the ramp strictly increasing, so a step means a magnitude', () => {
    // A scale where two steps share a pixel value is a scale with two
    // names for one thing — the exact ambiguity this file exists to stop.
    const px = Object.values(SCALE).map((v) => parseInt(v, 10))
    const ordered = [...px].sort((a, b) => a - b)
    expect({ duplicates: px.filter((v, i) => px.indexOf(v) !== i), isRamp: px }).toEqual({
      duplicates: [],
      isRamp: ordered,
    })
  })

  it('has no hand-rolled font size in any component', () => {
    const found = collect((line) => {
      const m = RAW_LENGTH_RE.exec(line)
      return m ? `${m[0]} — pick a step off the scale` : null
    })
    expect(found).toEqual({})
  })

  it('has no bare Tailwind size class in any component', () => {
    // `text-xs` reads as a size but bypasses the scale: change the ramp
    // and this element silently keeps the old pixel value.
    const found = collect((line) => {
      const m = BANNED_SIZE_RE.exec(line)
      return m ? `${m[0]} — use text-<step> from the scale` : null
    })
    expect(found).toEqual({})
  })

  it('uses only the four weights on the ladder', () => {
    const found = collect((line) => {
      const weight =
        /(?<![\w-])font-(thin|extralight|light|normal|medium|semibold|bold|extrabold|black)(?![\w-])/.exec(
          line,
        )?.[1]
      return weight !== undefined && BANNED_WEIGHTS.has(weight)
        ? `font-${weight} — not on the weight ladder`
        : null
    })
    expect(found).toEqual({})
  })

  it('writes no raw font-size in CSS except the relative one', () => {
    // `.markdown-content code` is `0.875em` on purpose: inline code has
    // to shrink with whatever it is nested inside, which a px step or a
    // rem step cannot do. Everything else resolves off the scale.
    const raw = CSS.split('\n')
      .map((text, i) => ({ n: i + 1, text }))
      .filter(({ text }) => /^\s*font-size:/.test(text))
      .filter(({ text }) => !/var\(--text-/.test(text) && !/0\.875em/.test(text))
      .map(({ n, text }) => `line ${n}: ${text.trim()}`)
    expect(raw).toEqual([])
  })

  it('writes no raw font-size inside a component <style> block', () => {
    // The hole that let 96 off-scale values survive the class migration:
    // `collect()` reads every line of every component, but it only looks
    // for Tailwind CLASSES. A `font-size: 0.8125rem` inside a .vue
    // <style> block is not a class, so nothing here saw it.
    //
    // Scanned as whole BLOCK TEXT, not line by line. A per-line
    // `^\s*font-size:` test is vacuous: it misses the single-line rule
    // `.probe { font-size: 13px; }` outright. (It was proved vacuous by
    // injecting exactly that and watching the spec stay green.)
    const RAW_CSS_SIZE_RE = /font-size:\s*[0-9.]+(?:px|rem)/g
    // A block tag must be ALONE on its line. WorkspaceItemTaskCard.vue:591
    // carries a comment reading "…lives in the scoped <style> block" and
    // KanbanView.vue:1641 one reading "<script setup>. Do NOT remove…";
    // a looser match flips the tracker on there and never off, which
    // silently skips the rest of the file. The tracker must therefore be
    // able to prove it balanced, hence the assert below.
    const blockTag = (tag: string, closing: boolean) =>
      new RegExp(`^\\s*${closing ? '</' : '<'}${tag}\\b[^>]*>\\s*$`)

    const found: Record<string, string[]> = {}
    for (const file of COMPONENT_FILES.filter((p) => p.endsWith('.vue'))) {
      const bad: string[] = []
      let inStyle = false
      let inScript = false
      readFileSync(file, 'utf8')
        .split('\n')
        .forEach((text, i) => {
          if (blockTag('style', false).test(text)) inStyle = true
          if (blockTag('style', true).test(text)) inStyle = false
          if (blockTag('script', false).test(text)) inScript = true
          if (blockTag('script', true).test(text)) inScript = false
          if (!inStyle || inScript) return
          // Attribute every offset back to a line so a failure names one.
          for (const m of text.matchAll(RAW_CSS_SIZE_RE)) {
            bad.push(`line ${i + 1}: ${m[0]} — pick a step off the scale`)
          }
        })
      // An unbalanced file means the tracker lost sync and the scan above
      // covered the wrong lines — that must fail, not pass quietly.
      expect({
        file: relative(SRC, file),
        balanced: !inStyle && !inScript,
      }).toEqual({ file: relative(SRC, file), balanced: true })
      if (bad.length) found[relative(SRC, file)] = bad
    }
    expect(found).toEqual({})
  })

  it('writes no raw font-size in a template style="" attribute', () => {
    // The same hole by the other door: an inline `style="font-size: 8px"`
    // carries its size mid-line, so neither the class scan nor the
    // whole-line CSS scan can see it. Two sibling task components shipped
    // the same warning glyph at 8px and 10px for exactly this reason.
    //
    // Skipped inside <script>, where the same text is DATA: the default
    // body of a design element the user then edits in Monaco, and the
    // xterm/Monaco fontSize options, which take a number and cannot take
    // var() at all.
    const INLINE_RAW_RE = /style="[^"]*font-size:\s*[0-9.]+(px|rem)/
    const blockTag = (tag: string, closing: boolean) =>
      new RegExp(`^\\s*${closing ? '</' : '<'}${tag}\\b[^>]*>\\s*$`)

    const found: Record<string, string[]> = {}
    for (const file of COMPONENT_FILES.filter((p) => p.endsWith('.vue'))) {
      const bad: string[] = []
      let inStyle = false
      let inScript = false
      readFileSync(file, 'utf8')
        .split('\n')
        .forEach((text, i) => {
          if (blockTag('style', false).test(text)) inStyle = true
          if (blockTag('style', true).test(text)) inStyle = false
          if (blockTag('script', false).test(text)) inScript = true
          if (blockTag('script', true).test(text)) inScript = false
          if (inStyle || inScript) return
          if (INLINE_RAW_RE.test(text)) bad.push(`line ${i + 1}: ${text.trim().slice(0, 80)}`)
        })
      if (bad.length) found[relative(SRC, file)] = bad
    }
    expect(found).toEqual({})
  })

  it('resolves at least one component onto the scale (smoke)', () => {
    // Guards against the scan silently matching nothing — a regex that
    // stopped matching would turn every other test here vacuous.
    const used = collect((line) => (SIZE_CLASS_RE.test(line) ? 'x' : null))
    expect(Object.keys(used).length).toBeGreaterThan(20)
  })
})
