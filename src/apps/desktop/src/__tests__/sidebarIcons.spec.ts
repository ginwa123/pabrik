/** Behaviour of the sidebar row glyphs: which glyph a row resolves to when it
 * has an override, when it has none, and when the stored name is one this
 * build cannot draw. */
import { describe, expect, it } from 'vitest'

import {
  documentIconFor,
  folderIconFor,
  ICON_PICKER_NAMES,
  isUiIconName,
} from '../stores/sidebarIcons'
import { ICON_PATHS } from '../components/ui/icons'

describe('folderIconFor', () => {
  it('draws a closed folder for a row with no override', () => {
    expect(folderIconFor({ icon: null }, false)).toBe('folder')
  })

  it('draws an open folder for an expanded row with no override', () => {
    expect(folderIconFor({ icon: null }, true)).toBe('folder-open')
  })

  it('draws the override whether the row is expanded or not', () => {
    expect(folderIconFor({ icon: 'tree' }, false)).toBe('tree')
    expect(folderIconFor({ icon: 'tree' }, true)).toBe('tree')
  })

  it('falls back to the folder pair when the stored name is not one this build can draw', () => {
    // A row written by a build that had an icon this one dropped.
    expect(folderIconFor({ icon: 'icon-from-a-future-build' }, false)).toBe('folder')
    expect(folderIconFor({ icon: 'icon-from-a-future-build' }, true)).toBe('folder-open')
  })

  it('treats a missing row as a closed folder rather than throwing', () => {
    expect(folderIconFor(undefined, false)).toBe('folder')
    expect(folderIconFor(null, true)).toBe('folder-open')
  })
})

describe('documentIconFor', () => {
  it('draws a file for a document with no override', () => {
    expect(documentIconFor({ icon: null })).toBe('file')
  })

  it('draws the override when it is a name this build can draw', () => {
    expect(documentIconFor({ icon: 'note' })).toBe('note')
  })

  it('falls back to a file when the stored name is not one this build can draw', () => {
    expect(documentIconFor({ icon: 'icon-from-a-future-build' })).toBe('file')
  })

  it('treats a missing row as a file rather than throwing', () => {
    expect(documentIconFor(undefined)).toBe('file')
  })
})

describe('isUiIconName', () => {
  it('accepts every name the registry can draw', () => {
    for (const name of Object.keys(ICON_PATHS)) {
      expect(isUiIconName(name)).toBe(true)
    }
  })

  it('rejects a prototype key, which would otherwise render an empty glyph', () => {
    // `'constructor' in ICON_PATHS` is true, so an `in`-based guard would let
    // this through and `ICON_PATHS['constructor']` would draw nothing.
    expect(isUiIconName('constructor')).toBe(false)
    expect(isUiIconName('toString')).toBe(false)
  })

  it('rejects a non-string', () => {
    expect(isUiIconName(null)).toBe(false)
    expect(isUiIconName(42)).toBe(false)
  })
})

describe('ICON_PICKER_NAMES', () => {
  it('is sorted, so the picker grid does not reshuffle between builds', () => {
    const sorted = [...ICON_PICKER_NAMES].sort()
    expect(ICON_PICKER_NAMES).toEqual(sorted)
  })

  it('offers only names the server will accept', () => {
    // The server rejects anything outside [a-z0-9-]{1,64} (icon_name.zig
    // isValidIconName). A registry key like `chevron_down` would be offered by
    // the picker and 400'd on save, so the two shapes have to stay in step.
    const serverAccepts = /^[a-z0-9-]{1,64}$/
    const rejected = ICON_PICKER_NAMES.filter((name) => !serverAccepts.test(name))
    expect(rejected).toEqual([])
  })
})
