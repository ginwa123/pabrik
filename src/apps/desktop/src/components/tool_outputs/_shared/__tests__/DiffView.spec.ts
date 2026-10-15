/**
 * Tests for DiffView.vue.
 *
 * Verifies:
 *  - renders split-view by default; toggle to unified swaps the view
 *  - shows the change count when there are changes
 *  - shows file path in the header when provided
 *  - sticky gutter cells render with the line-number content (and DON'T
 *    show "0" for inserts/deletes that have no before/after line)
 *  - empty before/after renders '(no content)' placeholder
 *  - REGRESSION: line-shift after insert renders as 1 changed row, not
 *    falsely flagging all subsequent lines
 *  - hunk headers appear in unified view with `@@ -start,count +start,count @@`
 *  - data-row / data-changed attrs reflect the diff state (for E2E selectors)
 */
import { mount } from '@vue/test-utils'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'

import DiffView from '../DiffView.vue'
import { makeLocalStorageStub } from '../../../../__tests__/helpers'

beforeAll(() => {
  // jsdom 29 dropped localStorage from default globals; install a stub.
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

beforeEach(() => {
  localStorage.clear()
})

/** Class names anywhere inside `root` that force a text color with
 * `!important` — the only form that beats `.tok-*` in the compiled CSS. */
function importantTextTints(root: {
  findAll: (s: string) => { classes: () => string[] }[]
}): string[] {
  return root
    .findAll('*')
    .flatMap((el) => el.classes())
    .filter((c) => c.startsWith('!text-'))
}

describe('DiffView', () => {
  it('renders the diff header with default mode = split', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'a\nb\nc',
        after: 'a\nb\nC',
      },
    })
    expect(wrapper.text()).toContain('diff')
    expect(wrapper.text()).toContain('Before')
    expect(wrapper.text()).toContain('After')
  })

  it('shows the file path when provided', () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a', after: 'a', filePath: '/foo/bar.ts' },
    })
    expect(wrapper.text()).toContain('/foo/bar.ts')
  })

  it('shows the change count', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'a\nb\nc\nd',
        after: 'a\nb\nX\nd',
      },
    })
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('toggles to unified view when the Unified button is clicked', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    // Find the "Unified" button
    const buttons = wrapper.findAll('button')
    const unifiedBtn = buttons.find((b) => b.text() === 'Unified')
    expect(unifiedBtn).toBeTruthy()
    await unifiedBtn!.trigger('click')
    // After toggle, unified hunk header should be visible
    expect(wrapper.text()).toMatch(/@@ -\d+,\d+ \+\d+,\d+ @@/)
    // No more "Before"/"After" labels in unified mode
    expect(wrapper.text()).not.toContain('Before')
  })

  it('toggles back to split view', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Unified')!
      .trigger('click')
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Split')!
      .trigger('click')
    expect(wrapper.text()).toContain('Before')
  })

  it('REGRESSION: line-shift after insert renders only 1 changed row', () => {
    // Inserting 'b' at position 2 of a 10-line file should mark only line 2
    // as changed. Lines 3-10 must remain isChanged=false in the split view.
    const wrapper = mount(DiffView, {
      props: {
        before: 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10',
        after: 'l1\nl2\nINSERTED\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10',
      },
    })
    // Find all rows on the before side
    const rows = wrapper.findAll('[data-side="before"][data-row]')
    const changedCount = rows.filter((r) => r.attributes('data-changed') === 'true').length
    expect(changedCount).toBe(1)
  })

  it('renders hunk headers in unified view', async () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'ctx1\nctx2\nOLD\nctx3\nctx4',
        after: 'ctx1\nctx2\nNEW\nctx3\nctx4',
      },
    })
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Unified')!
      .trigger('click')
    const hunks = wrapper.findAll('[data-hunk]')
    expect(hunks.length).toBeGreaterThan(0)
    expect(hunks[0]!.text()).toMatch(/^@@ -\d+,\d+ \+\d+,\d+ @@$/)
  })

  it('renders "(no content)" placeholder for empty inputs', () => {
    const wrapper = mount(DiffView, {
      props: { before: '', after: '' },
    })
    expect(wrapper.text()).toContain('(no content)')
  })

  it('handles pure-insert (empty before, single line after)', () => {
    const wrapper = mount(DiffView, {
      props: { before: '', after: 'hello' },
    })
    expect(wrapper.text()).toContain('hello')
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('handles pure-delete (single line before, empty after)', () => {
    const wrapper = mount(DiffView, {
      props: { before: 'hello', after: '' },
    })
    expect(wrapper.text()).toContain('hello')
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('persists mode toggle to localStorage', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Unified')!
      .trigger('click')
    expect(localStorage.getItem('diffview.mode')).toBe('unified')
    // Set split and verify
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Split')!
      .trigger('click')
    expect(localStorage.getItem('diffview.mode')).toBe('split')
  })

  it('reads initial mode from localStorage', () => {
    localStorage.setItem('diffview.mode', 'unified')
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    // unified mode is on, so we should see a hunk header
    expect(wrapper.text()).toMatch(/@@ -\d+,\d+ \+\d+,\d+ @@/)
    localStorage.clear()
  })

  // ─────────────────────────────────────────────────────────────────────
  // jump-to-line emit (chunks 5+6)
  // ─────────────────────────────────────────────────────────────────────

  it('emits jump-to-line when an after-side line number is clicked (split view)', async () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'l1\nl2\nl3',
        after: 'l1\nL2-CHANGED\nl3',
      },
    })
    // Find the row containing the after-line "2" (the inserted row).
    // The after-side row has data-side="after" and data-line="2".
    const afterLineRows = wrapper.findAll('[data-side="after"][data-line="2"]')
    expect(afterLineRows.length).toBe(1)
    const afterLineRow = afterLineRows[0]!
    // The gutter is the first <span> child (sibling of the bg layer).
    // Query for it directly because the row now has a [data-bg] div
    // before the gutter span.
    const gutter = afterLineRow.element.querySelector('span:not([data-bg])')!
    expect(gutter).toBeTruthy()
    await gutter.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    const events = wrapper.emitted('jump-to-line')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual([2])
  })

  it('emits jump-to-line from the unified gutter when clicked', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Unified')!
      .trigger('click')
    // Find the unified row for the inserted 'B' line — its afterLine is 2
    const insertedRows = wrapper.findAll('[data-kind="insert"][data-after-line="2"]')
    expect(insertedRows.length).toBe(1)
    // After-side gutter is the second span (sticky left-10).
    await insertedRows[0]!.element.children[1]!.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    )
    const events = wrapper.emitted('jump-to-line')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual([2])
  })

  it('does not emit jump-to-line for rows with no line number', async () => {
    const wrapper = mount(DiffView, {
      // Pure insert: empty before → no before-line numbers anywhere.
      props: { before: '', after: 'NEW' },
    })
    // The before-side gutter cells should have no line number — clicking
    // them should NOT emit (no `data-line` attr on those rows).
    const rowsWithoutLine = wrapper.findAll('[data-side="before"][data-row]')
    rowsWithoutLine.forEach((r) => {
      expect(r.attributes('data-line')).toBeUndefined()
    })
    expect(wrapper.emitted('jump-to-line')).toBeFalsy()
  })

  // ─────────────────────────────────────────────────────────────────────
  // Clean split-view rendering (chunks 5+6 redesign)
  //
  // Layout (top → bottom in DOM):
  //   1. PANE — <div class="overflow-x-auto ..."> (the scroll container)
  //   2. SHARED WRAPPER — <div style="width: max-content; min-width: 100%">
  //        sized once per pane so every row inherits the same final width
  //   3. ROW — <div class="block whitespace-pre" style="width: 100%;
  //        background-color: rgba(...)"> for changed rows. NO [data-bg]
  //        child — the bg is on the row itself. NO inline highlights
  //        (no <span class="...line-through...">, no per-word bg).
  // ─────────────────────────────────────────────────────────────────────

  it('split view: changed row has bg color on itself, NO inline highlights', () => {
    // User feedback: the previous version mixed row bg + per-word strikethrough + per-word
    // highlights on the same line, which was unreadable. The new design is row bg on the row
    // element + plain text — no [data-bg] child, no inline highlights.
    const wrapper = mount(DiffView, {
      props: {
        before: 'hello world',
        after: 'hello THERE',
      },
    })
    const beforeRows = wrapper.findAll('[data-side="before"][data-row]')
    expect(beforeRows.length).toBeGreaterThan(0)
    const firstBeforeRow = beforeRows[0]!
    // The bg is on the row's own inline style (not on a [data-bg] child). We assert the row has the
    // bg-color and that NO [data-bg] child element exists — locks in the redesigned layout so a
    // future revert to the old per-row [data-bg] layer is caught.
    expect(firstBeforeRow.attributes('style') ?? '').toMatch(/background-color/)
    expect(firstBeforeRow.find('[data-bg]').exists()).toBe(false)
    // Plain text — no strikethrough anywhere in the row.
    expect(firstBeforeRow.html()).not.toContain('line-through')
    // No green "insert" highlight inside the before side (was the
    // original visual confusion — strikethrough on green).
    expect(firstBeforeRow.html()).not.toMatch(/bg-green/)
  })

  it('split view: after-side changed row has the green bg color', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'hello world',
        after: 'hello THERE',
      },
    })
    const afterRows = wrapper.findAll('[data-side="after"][data-row]')
    expect(afterRows.length).toBeGreaterThan(0)
    const firstAfterRow = afterRows[0]!
    // After-side changed row has the green rgba on its inline style.
    expect(firstAfterRow.attributes('style') ?? '').toMatch(
      /background-color:\s*rgba\(\s*46,\s*160,\s*67/,
    )
    // Plain text — no strikethrough on the inserted line.
    expect(firstAfterRow.html()).not.toContain('line-through')
  })

  it('split view: shared sizing wrapper has width:max-content + min-width:100% (one wrapper per pane)', () => {
    // Critical UX combination: ONE shared sizing wrapper per pane
    // (width: max-content + min-width: 100%) so every row inherits the
    // same final width — the bg always covers the full pane, AND long
    // lines can scroll horizontally because the wrapper's max-content
    // width is computed from the widest row's content (or the pane,
    // whichever is larger). Per-row width:max-content does NOT work
    // because each row would only size from its own content. See the
    // long comment in DiffView.vue for the full rationale.
    const wrapper = mount(DiffView, {
      props: {
        before: 'x',
        after: 'Y',
      },
    })
    const row = wrapper.find('[data-row]')
    expect(row.exists()).toBe(true)
    // The row's direct parent is the SHARED WRAPPER (single per pane).
    // It has width:max-content + min-width:100%.
    const sharedWrapper = row.element.parentElement!
    const wrapperStyle = sharedWrapper.getAttribute('style') ?? ''
    expect(wrapperStyle).toMatch(/width:\s*max-content/)
    expect(wrapperStyle).toMatch(/min-width:\s*100%/)
    // The row itself is `width: 100%` of the shared wrapper — not
    // `max-content` (which would per-row-size).
    const rowStyle = row.attributes('style') ?? ''
    expect(rowStyle).toMatch(/width:\s*100%/)
    expect(rowStyle).not.toMatch(/width:\s*max-content/)
  })

  it('split view: pane uses overflow-x-auto (long lines trigger horizontal scroll)', () => {
    // The PANE (grandparent of the row, parent of the shared wrapper) uses `overflow-x: auto` so
    // long content triggers a horizontal scrollbar. Combined with the shared-wrapper sizing, the bg
    // stays anchored to the visible pane while the content scrolls under it.
    const wrapper = mount(DiffView, {
      props: {
        before: 'a\nb',
        after: 'A\nB',
      },
    })
    const row = wrapper.find('[data-row]')
    expect(row.exists()).toBe(true)
    // grand-parent of the row = the pane (overflow-x-auto).
    const sharedWrapper = row.element.parentElement!
    const pane = sharedWrapper.parentElement!
    expect(pane.classList.contains('overflow-x-auto')).toBe(true)
  })

  it('split view: gutter is position:sticky so line numbers stay visible when scrolling right', () => {
    // When the user scrolls right, the gutter (line number cell)
    // should stay visible at the left edge of the pane. This is
    // implemented via position:sticky + left:0 on the gutter span.
    const wrapper = mount(DiffView, {
      props: {
        before: 'a',
        after: 'B',
      },
    })
    const row = wrapper.find('[data-row]')
    expect(row.exists()).toBe(true)
    // The gutter is the first <span> in the row (sibling of [data-bg]).
    const gutter = row.element.querySelector('span:not([data-bg])')!
    expect(gutter).toBeTruthy()
    const gutterStyle = gutter.getAttribute('style') ?? ''
    expect(gutterStyle).toMatch(/position:\s*sticky/)
    expect(gutterStyle).toMatch(/left:\s*0/)
  })

  // ─────────────────────────────────────────────────────────────────────
  // Code coloring (text_replace output code coloring)
  // ─────────────────────────────────────────────────────────────────────

  it('colorizes tokens when filePath has a known extension', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'const a = "old"',
        after: 'const a = "new"',
        filePath: '/repo/src/foo.ts',
      },
    })
    const html = wrapper.html()
    expect(html).toContain('tok-keyword')
    expect(html).toContain('tok-string')
  })

  it('renders plain text (no token spans) for unknown extensions', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'const a = "old"',
        after: 'const a = "new"',
        filePath: '/repo/notes.log',
      },
    })
    const html = wrapper.html()
    expect(html).not.toContain('tok-keyword')
    expect(html).not.toContain('tok-string')
    // Content still renders.
    expect(wrapper.text()).toContain('const a =')
  })

  it('explicit language prop overrides the filePath derivation', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'const a = "old"',
        after: 'const a = "new"',
        filePath: '/repo/notes.log',
        language: 'typescript',
      },
    })
    expect(wrapper.html()).toContain('tok-keyword')
  })

  it('colorizes unified view rows too', async () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'const a = "old"',
        after: 'const a = "new"',
        filePath: '/repo/src/foo.py',
      },
    })
    await wrapper
      .findAll('button')
      .find((b) => b.text() === 'Unified')!
      .trigger('click')
    expect(wrapper.html()).toContain('tok-string')
  })

  it('states its own text colour on every pane, so plain tokens are readable', () => {
    // Measured in a real browser: with the row tint gone, `.tok-plain` (color: inherit) resolved to
    // the initial value — BLACK on the dark card. The pane must carry the base colour itself, not
    // inherit blindly from whatever hosts the diff.
    const wrapper = mount(DiffView, {
      props: { before: 'const a = 1', after: 'const b = 2', filePath: 'demo.ts' },
    })
    const panes = wrapper.findAll('.overflow-x-auto')
    expect(panes.length).toBeGreaterThan(0)
    for (const pane of panes) {
      expect(pane.classes()).toContain('text-[var(--semantic-text)]')
    }
  })

  it('shows syntax tokens on CHANGED rows, not a monochrome red/green tint', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'const keep = 1\nconst gone = 2',
        after: 'const keep = 1\nconst added = 3',
        filePath: 'demo.ts',
      },
    })

    const changed = wrapper.findAll('[data-changed="true"]')
    expect(changed.length).toBeGreaterThan(0)
    for (const row of changed) {
      // Nothing inside a changed row may carry an `!important` text tint
      // (`!text-red-500`): it wins over `.tok-*` in the compiled CSS and
      // paints the whole line one color. The row BACKGROUND is what marks
      // added/removed. (jsdom loads no stylesheet, so asserting the DOM
      // class is the only honest witness here — and it is exactly the class
      // whose removal makes the tokens visible in a browser.)
      expect(importantTextTints(row)).toEqual([])
      expect(row.findAll('.tok-keyword').length).toBeGreaterThan(0)
    }
  })

  it('unified view: the +/− gutter sign keeps its direction color', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'const gone = 2', after: 'const added = 3', filePath: 'demo.ts' },
    })
    const unifiedBtn = wrapper.findAll('button').find((b) => b.text() === 'Unified')
    expect(unifiedBtn).toBeTruthy()
    await unifiedBtn!.trigger('click')

    expect(wrapper.findAll('[data-kind="delete"] span.text-red-500').length).toBeGreaterThan(0)
    expect(wrapper.findAll('[data-kind="insert"] span.text-green-500').length).toBeGreaterThan(0)

    // The ROW carries the background tint only — an `!important` text tint
    // here is what would hide every token.
    for (const row of wrapper.findAll('[data-kind="delete"], [data-kind="insert"]')) {
      expect(importantTextTints(row)).toEqual([])
    }

    // ...while the code itself is still split into colored tokens.
    expect(wrapper.findAll('.tok-keyword').length).toBeGreaterThan(0)
  })
})
