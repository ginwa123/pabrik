/**
 * The sidebar's spacing contract.
 *
 * Four left edges and three row heights accumulated in this panel because
 * nothing ever asserted a measurement — the one "contract" comment in the
 * tree pointed at a spec that did not exist. These tests assert the values
 * against the --sb-* geometry tokens, so a row that hand-rolls its own
 * pixel count fails here rather than in a screenshot review.
 *
 * Type used to live here too, as four --sb-fs-* tokens. It does not any
 * more: the sidebar picks steps off the app-wide scale in style.css
 * (see type-scale.spec.ts), so a sidebar label and the same label in a
 * dialog are the same number by construction. The tests below still pin
 * WHICH step each part of the panel uses, because "smallest" is not a
 * contract — 10px for a section title and 10px for a timestamp is a
 * decision, and it is the one the reviewer asked to shrink.
 *
 * Deliberately NOT a pixel-diff of a screenshot: that fails on a 1px
 * antialiasing change and passes on a 14px indent regression.
 *
 * Note: no `expect(value, message)` form — eslint-plugin-jest/valid-expect
 * rejects a second argument, so per-file context goes in the failure text
 * via the collected map instead.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/** Geometry only. There is deliberately no --sb-fs-* here: font size is
 * not a sidebar concern, it is an app-wide one (type-scale.spec.ts). */
const TOKENS: Record<string, string> = {
  '--sb-gutter': '12px',
  '--sb-row': '32px',
  '--sb-indent': '12px',
  '--sb-hit': '24px',
}

/** The files that make up the three left-sidebar menus. */
const MENU_FILES = [
  'components/shell/Sidebar.vue',
  'components/workspace/WorkspaceSwitcher.vue',
  'components/views/ChatsList.vue',
  'components/workspace/ProjectsList.vue',
  // Documents section (Migration 095). Added to MENU_FILES so the arbitrary-padding / font-size /
  // type-token bans below apply to it — a new sidebar section that skips the guard is how the panel
  // drifts back to four different left edges.
  'components/workspace/DocumentsList.vue',
  'components/workspace/WorkspaceItem.vue',
  'components/workspace/WorkspaceItemTaskRow.vue',
]

/** Files whose rows are list rows and therefore have a fixed height. */
const ROW_FILES = [
  'components/views/ChatsList.vue',
  'components/workspace/WorkspaceItem.vue',
  'components/workspace/WorkspaceItemTaskRow.vue',
  // Documents rows (Migration 095) are the same kind of object as a chat row: one clickable line in
  // a sidebar list. They must resolve their height and type off the same two tokens or the panel
  // grows a fourth row rhythm.
  'components/workspace/DocumentsList.vue',
]

const read = (p: string) => readFileSync(resolve(SRC, p), 'utf8')

type Line = { n: number; text: string }

/** Lines between `sb-scope: overlay` markers are floating popovers
 * (tooltips, dropdown cards), not rows in the three menus. They keep
 * their own width and type scale on purpose, so the row contract does
 * not apply to them. The marker is explicit and reviewable rather than a
 * regex guessing at what counts as a popover. */
function menuLines(src: string): Line[] {
  const out: Line[] = []
  let inOverlay = false
  src.split('\n').forEach((text, i) => {
    if (text.includes('<!-- sb-scope: overlay')) inOverlay = true
    if (!inOverlay) out.push({ n: i + 1, text })
    if (text.includes('<!-- /sb-scope: overlay')) inOverlay = false
  })
  return out
}

const classLines = (file: string) =>
  menuLines(read(file)).filter(({ text }) => /:?class="/.test(text))

/** `file -> the lines that are wrong`, so a failure names the file. */
function collect(pick: (line: string) => string | null): Record<string, string[]> {
  const found: Record<string, string[]> = {}
  for (const file of MENU_FILES) {
    const bad: string[] = []
    for (const { n, text } of classLines(file)) {
      const hit = pick(text)
      if (hit) bad.push(`line ${n}: ${hit}`)
    }
    if (bad.length) found[file] = bad
  }
  return found
}

describe('sidebar spacing + type scale', () => {
  it('defines every --sb-* token in style.css', () => {
    const css = read('style.css')
    const missing = Object.entries(TOKENS)
      .filter(([name, value]) => !new RegExp(`${name}:\\s*${value}\\s*;`).test(css))
      .map(([name, value]) => `${name} should be ${value}`)
    expect(missing).toEqual([])
  })

  it('resolves geometry from the tokens, never a hand-rolled pixel count', () => {
    // Arbitrary pixel values are the drift signal. A named Tailwind step
    // like px-3 resolves to 12px, which is the gutter anyway, so flagging
    // it would be noise.
    const found = collect((line) => {
      const m = /(^|\s)(px|py|p|pl|pr|pt|pb|m|ml|mr|mt|mb|w|h)-\[\d+px\]/.exec(line)
      return m ? line.trim().slice(0, 90) : null
    })
    expect(found).toEqual({})
  })

  it('uses one row height token for every list row', () => {
    const missing = ROW_FILES.filter((f) => !read(f).includes('h-[var(--sb-row)]'))
    expect(missing).toEqual([])
  })

  it('keeps the virtualiser in step with the row height (Q5)', () => {
    // The row dropped 48 -> 32px. If these drift apart the list scrolls
    // against a height nothing renders.
    const src = read('components/views/ChatsList.vue')
    expect(src).toContain(':default-item-height="32"')
    expect(src).not.toContain(':default-item-height="48"')
  })

  it('gives both section headers the same height, gutter and rule (D16)', () => {
    const problems: string[] = []
    for (const [name, file] of [
      ['Recent', 'components/views/ChatsList.vue'],
      ['Projects', 'components/workspace/ProjectsList.vue'],
      // Documents (Migration 095) is a third peer section, not a
      // sub-header of Projects — so it answers the same three questions
      // the other two do.
      ['Documents', 'components/workspace/DocumentsList.vue'],
    ] as const) {
      const src = read(file)
      if (!src.includes('px-[var(--sb-gutter)] h-7')) {
        problems.push(`${name} header must sit on the gutter at 28px`)
      }
      if (!src.includes('border-b border-[--color-border]/40')) {
        problems.push(`${name} header must draw the separating rule`)
      }
    }
    expect(problems).toEqual([])
  })

  it('has no leftover arbitrary font sizes in the menu rows', () => {
    // Handled app-wide by type-scale.spec.ts; repeated here because the sidebar is the panel most
    // likely to grow its own private scale back. A 9/10/14/15/16/20 in a menu row is exactly the
    // drift this file exists to catch.
    const found = collect((line) => {
      const px = /text-\[(\d+)px\]/.exec(line)?.[1]
      return px !== undefined ? `text-[${px}px] — pick a step off the type scale` : null
    })
    expect(found).toEqual({})
  })

  it('gives every row in all three menus the same label size', () => {
    // The complaint that started this: a chat name rendered at 14px in
    // Recent and 12px nested under a project, with the owning project
    // at 13px in between. 12px (`text-dense`) is the row step.
    const missing = ROW_FILES.filter((f) => !read(f).includes('text-dense'))
    expect(missing).toEqual([])
  })

  it('never sizes a sidebar row above the step the rows use', () => {
    // The popups are the part that goes wrong quietly: the switcher's
    // "+ New workspace" footer and its own workspace options sit in ONE
    // panel, and the options used to be 14px while the footer was 12px.
    const found = collect((line) => {
      const m =
        /(?<![\w-])text-(body|lead|title-sm|title|title-lg|display|display-lg)(?![\w-])/.exec(line)
      return m ? `${m[0]} — a sidebar row is text-dense (12px)` : null
    })
    expect(found).toEqual({})
  })

  it('keeps the sidebar on the one app-wide scale (no private copy)', () => {
    // --sb-fs-* was the sidebar's private copy of the app scale. Two
    // lists of font sizes drift; that is the bug this task reported.
    const offenders = MENU_FILES.filter((f) => /--sb-fs-/.test(read(f)))
    expect(offenders).toEqual([])
    expect(read('style.css')).not.toContain('--sb-fs-')
  })

  it('does not claim a test contract that does not exist (D17)', () => {
    // The old header comment asserted that a sidebarSpacing.spec.ts
    // grep-guarded its class string. No such file ever existed — a
    // repo-wide search for "sidebarSpacing" returned only the comment.
    expect(read('components/views/ChatsList.vue')).not.toContain('sidebarSpacing.spec.ts')
  })
})
