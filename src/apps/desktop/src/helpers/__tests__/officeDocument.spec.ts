import { describe, expect, it } from 'vitest'
import {
  DEFAULT_OFFICE_KIND,
  isOfficeFormat,
  isOfficeKind,
  parseOfficeBody,
  serializeOfficeBody,
} from '../officeDocument'

describe('officeDocument — format', () => {
  it('recognises the office format and nothing else', () => {
    expect(isOfficeFormat('office')).toBe(true)
    expect(isOfficeFormat('markdown')).toBe(false)
    expect(isOfficeFormat(undefined)).toBe(false)
    expect(isOfficeFormat(null)).toBe(false)
  })

  it('recognises the two kinds Univer can render', () => {
    expect(isOfficeKind('doc')).toBe(true)
    expect(isOfficeKind('sheet')).toBe(true)
    expect(isOfficeKind('slide')).toBe(false)
    expect(isOfficeKind(undefined)).toBe(false)
  })
})

describe('officeDocument — body', () => {
  it('a serialized body parses back to the same kind and snapshot', () => {
    const snapshot = { sheets: { s1: { cellData: { '0': { '0': { v: 'Q3' } } } } } }
    const body = serializeOfficeBody('sheet', snapshot)

    expect(parseOfficeBody(body)).toEqual({ kind: 'sheet', snapshot })
  })

  it('an empty body is a blank spreadsheet, not an error', () => {
    // A document created without content is a legitimate starting state: the
    // editor opens a blank sheet and the first Save writes a real snapshot.
    expect(parseOfficeBody('')).toEqual({ kind: DEFAULT_OFFICE_KIND, snapshot: {} })
    expect(parseOfficeBody(null)).toEqual({ kind: DEFAULT_OFFICE_KIND, snapshot: {} })
    expect(parseOfficeBody(undefined)).toEqual({ kind: DEFAULT_OFFICE_KIND, snapshot: {} })
  })

  it('a body that is not JSON is unreadable', () => {
    expect(parseOfficeBody('not json at all')).toBeNull()
  })

  it('a JSON body that is not an envelope is unreadable', () => {
    expect(parseOfficeBody('[]')).toBeNull()
    expect(parseOfficeBody('"a string"')).toBeNull()
    expect(parseOfficeBody('{"sheets":{}}')).toBeNull()
  })

  it('an envelope with an unknown kind is unreadable', () => {
    // Univer 1.4.0 ships no slides preset, so a slide body must not be opened
    // as if it were a spreadsheet.
    expect(parseOfficeBody('{"kind":"slide","snapshot":{}}')).toBeNull()
  })

  it('an envelope with no snapshot object is unreadable', () => {
    expect(parseOfficeBody('{"kind":"doc"}')).toBeNull()
    expect(parseOfficeBody('{"kind":"doc","snapshot":[]}')).toBeNull()
  })

  it('a document body keeps its kind', () => {
    const body = serializeOfficeBody('doc', { body: { dataStream: 'Hello\r\n' } })
    expect(parseOfficeBody(body)?.kind).toBe('doc')
  })
})
