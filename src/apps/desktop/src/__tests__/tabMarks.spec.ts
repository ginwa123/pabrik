import { describe, expect, it } from 'vitest'

import type { Tab } from '../helpers/tabTarget'
import { cwdOf, fileOf, markOf, recordSeen, type TabCounts } from '../helpers/tabMarks'

const tab = (file: string, extra: Record<string, string> = {}): Tab => ({
  id: `tab_${file}`,
  key: `file:/repo:${file}`,
  kind: 'file',
  title: file,
  path: '/app',
  query: { view: 'code-editor', file, cwd: '/repo', ...extra },
  createdAt: 1,
})

const counts = (added: number, removed: number): TabCounts => ({ added, removed })

describe('tabMarks', () => {
  it('reads the file and cwd off the tab, never off anything global', () => {
    expect(fileOf(tab('src/a.ts'))).toBe('src/a.ts')
    expect(cwdOf(tab('src/a.ts', { cwd: '/worktree-A' }))).toBe('/worktree-A')
    // the session's own tab shows no file
    expect(fileOf({ ...tab('x'), query: { view: 'chat', session: 'sa' } })).toBe('')
  })

  it('shows counts only for a file that has some', () => {
    const known = { 'src/a.ts': counts(3, 1), 'src/clean.ts': counts(0, 0) }
    expect(markOf(tab('src/a.ts'), false, known, {})).toEqual({
      counts: counts(3, 1),
      unseen: false,
    })
    // a clean file keeps its tab quiet
    expect(markOf(tab('src/clean.ts'), false, known, {})).toEqual({ counts: null, unseen: false })
    // an unknown file (no diff fetched yet, or no git) is quiet too, and still openable
    expect(markOf(tab('src/unknown.ts'), false, known, {})).toEqual({ counts: null, unseen: false })
  })

  it('is never unseen while you are looking at it', () => {
    const known = { 'src/a.ts': counts(9, 9) }
    const seen = { 'src/a.ts': counts(1, 1) }
    expect(markOf(tab('src/a.ts'), true, known, seen).unseen).toBe(false)
    expect(markOf(tab('src/a.ts'), false, known, seen).unseen).toBe(true)
  })

  it('needs a baseline before it can say a tab went unseen', () => {
    const seen = { 'src/a.ts': counts(3, 1) }
    // same numbers as last time: nothing new to look at
    expect(markOf(tab('src/a.ts'), false, { 'src/a.ts': counts(3, 1) }, seen).unseen).toBe(false)
    // only the added lines moved
    expect(markOf(tab('src/a.ts'), false, { 'src/a.ts': counts(4, 1) }, seen).unseen).toBe(true)
    // only the removed lines moved
    expect(markOf(tab('src/a.ts'), false, { 'src/a.ts': counts(3, 2) }, seen).unseen).toBe(true)
    // no baseline (a tab opened while the file already had changes): counts, no square
    expect(markOf(tab('src/a.ts'), false, { 'src/a.ts': counts(4, 1) }, {})).toEqual({
      counts: counts(4, 1),
      unseen: false,
    })
  })

  it('records what was seen without rewriting a record that did not change', () => {
    const before = { 'src/a.ts': counts(3, 1) }
    expect(recordSeen(before, { 'src/a.ts': counts(3, 1) }, ['src/a.ts'])).toBe(before)

    const next = recordSeen(before, { 'src/a.ts': counts(5, 2) }, ['src/a.ts'])
    expect(next).toEqual({ 'src/a.ts': counts(5, 2) })
    expect(next).not.toBe(before)
    // a file with no counts is not recorded
    expect(recordSeen(before, {}, ['src/b.ts'])).toBe(before)
  })
})
