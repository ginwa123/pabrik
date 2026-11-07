import { describe, expect, it } from 'vitest'

import { isAbsolutePath, normalisePath, resolveTabPath } from '../helpers/tabPath'
import {
  diffTabKey,
  fileTabKey,
  ownerOfTarget,
  tabKeyOf,
  tabKeyVariants,
} from '../helpers/tabTarget'

describe('tabPath', () => {
  it('knows an absolute path when it sees one', () => {
    expect(isAbsolutePath('/repo/src/a.ts')).toBe(true)
    expect(isAbsolutePath('C:\\repo\\a.ts')).toBe(true)
    expect(isAbsolutePath('src/a.ts')).toBe(false)
    expect(isAbsolutePath('./src/a.ts')).toBe(false)
  })

  it('collapses . and .. and duplicate separators', () => {
    expect(normalisePath('/repo//src/./a.ts')).toBe('/repo/src/a.ts')
    expect(normalisePath('/repo/src/../src/a.ts')).toBe('/repo/src/a.ts')
    expect(normalisePath('/repo/sub/../../other/a.ts')).toBe('/other/a.ts')
    expect(normalisePath('/repo/src/')).toBe('/repo/src')
    // a `..` that would climb above the root is dropped, not kept
    expect(normalisePath('/../a.ts')).toBe('/a.ts')
    // a relative path keeps a leading `..`, because it still means something
    expect(normalisePath('../a.ts')).toBe('../a.ts')
    expect(normalisePath('C:\\repo\\..\\a.ts')).toBe('C:\\a.ts')
  })

  it('resolves a relative file against the cwd, and never against nothing', () => {
    expect(resolveTabPath('src/a.ts', '/repo')).toBe('/repo/src/a.ts')
    expect(resolveTabPath('./src/a.ts', '/repo/')).toBe('/repo/src/a.ts')
    expect(resolveTabPath('../other/a.ts', '/repo/sub')).toBe('/repo/other/a.ts')
    expect(resolveTabPath('/repo/src/a.ts', '/elsewhere')).toBe('/repo/src/a.ts')
    // no cwd: the path is its own answer
    expect(resolveTabPath('src/a.ts', '')).toBe('src/a.ts')
    expect(resolveTabPath('', '/repo')).toBe('')
  })
})

describe('a file tab is one file, whatever spelling and cwd it arrives with', () => {
  it('gives every spelling of one file the same key', () => {
    const absolute = '/repo/sub/../src/a.ts'
    expect(fileTabKey(absolute, '/repo')).toBe('file:/repo/src/a.ts')
    expect(fileTabKey('src/a.ts', '/repo')).toBe('file:/repo/src/a.ts')
    expect(fileTabKey('./src/a.ts', '/repo/')).toBe('file:/repo/src/a.ts')
    // the tab's own cwd is a different directory from the file's repo: the resolved path still wins
    expect(fileTabKey('../repo/src/a.ts', '/elsewhere')).toBe('file:/repo/src/a.ts')
    expect(diffTabKey('src/../src/a.ts', '/repo')).toBe('diff:/repo/src/a.ts')
  })

  it('keys a file opened in a path-form chat exactly like one opened with ?session=', () => {
    const target = { view: 'code-editor', file: 'src/a.ts', cwd: '/repo' }
    // the path form carries no `session` — it is the URL the app really navigates chats to
    expect(ownerOfTarget('/app/ws_1/chat/sa', target)).toBe('sa')
    expect(tabKeyOf('/app/ws_1/chat/sa', target)).toBe(
      tabKeyOf('/app', { ...target, session: 'sa' }),
    )
    // …and a file's changes are their own tab in the same row
    expect(tabKeyOf('/app/ws_1/chat/sa', { ...target, mode: 'diff' })).toBe('diff:/repo/src/a.ts')
  })

  it('offers the unresolved spelling of a file as the same tab', () => {
    const target = { view: 'code-editor', file: 'src/a.ts', cwd: '/repo' }
    expect(tabKeyVariants('/app', target)).toEqual(['file:/repo/src/a.ts', 'file:src/a.ts'])
    // the diff of a file is its own tab, never a variant of the file
    const diff = tabKeyVariants('/app', { ...target, mode: 'diff' })
    expect(diff).toEqual(['diff:/repo/src/a.ts', 'diff:src/a.ts'])
    expect(diff).not.toContain('file:/repo/src/a.ts')
  })
})
