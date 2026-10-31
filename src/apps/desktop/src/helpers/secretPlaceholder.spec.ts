import { describe, expect, it } from 'vitest'

import {
  SECRET_PLACEHOLDER_PREFIX,
  SECRET_PLACEHOLDER_SUFFIX,
  applySecretPlaceholder,
  matchSecretNames,
  placeholderQueryAt,
} from './secretPlaceholder'

const open = SECRET_PLACEHOLDER_PREFIX
const close = SECRET_PLACEHOLDER_SUFFIX

describe('placeholderQueryAt', () => {
  it('reports the typed name once the prefix is on screen', () => {
    const text = `sk-live ${open}GIT`
    expect(placeholderQueryAt(text, text.length)).toEqual({
      query: 'GIT',
      start: 8,
      end: text.length,
    })
  })

  it('offers every name right after the prefix is typed', () => {
    expect(placeholderQueryAt(open, open.length)).toEqual({ query: '', start: 0, end: open.length })
  })

  it('reports nothing for an ordinary credential', () => {
    expect(placeholderQueryAt('sk-abcdef', 9)).toBeNull()
    expect(placeholderQueryAt('', 0)).toBeNull()
  })

  it('reports nothing once the placeholder is closed', () => {
    const complete = `${open}GITHUB_TOKEN${close}`
    expect(placeholderQueryAt(complete, complete.length)).toBeNull()
  })

  it('reports nothing when the caret sits before the prefix', () => {
    const text = `abc ${open}`
    expect(placeholderQueryAt(text, 0)).toBeNull()
  })

  it('reports nothing for a whitespace or brace in the typed name', () => {
    const spaced = `${open}GIT HUB`
    expect(placeholderQueryAt(spaced, spaced.length)).toBeNull()
  })
})

describe('matchSecretNames', () => {
  const names = ['GITHUB_TOKEN', 'STRIPE_API_KEY', 'GITHUB_APP_ID', 'SLACK_WEBHOOK']

  it('ranks prefix matches before substring matches', () => {
    expect(matchSecretNames(names, 'github')).toEqual(['GITHUB_TOKEN', 'GITHUB_APP_ID'])
    expect(matchSecretNames(names, 'key')).toEqual(['STRIPE_API_KEY'])
  })

  it('matches case-insensitively and keeps the stored spelling', () => {
    expect(matchSecretNames(names, 'StRiPe')).toEqual(['STRIPE_API_KEY'])
  })

  it('offers every name, in stored order, for an empty query', () => {
    expect(matchSecretNames(names, '')).toEqual(names)
  })

  it('returns nothing when the query matches nothing, so no menu is shown', () => {
    expect(matchSecretNames(names, 'zzz')).toEqual([])
    expect(matchSecretNames([], 'github')).toEqual([])
  })

  it('caps the list at the limit', () => {
    expect(matchSecretNames(names, '', 2)).toEqual(['GITHUB_TOKEN', 'STRIPE_API_KEY'])
  })
})

describe('applySecretPlaceholder', () => {
  it('replaces the typed query with the full placeholder and leaves the caret after it', () => {
    const text = `sk-live ${open}GIT`
    const result = applySecretPlaceholder(text, text.length, 'GITHUB_TOKEN')
    const expected = `sk-live ${open}GITHUB_TOKEN${close}`
    expect(result).toEqual({ text: expected, caret: expected.length })
  })

  it('inserts an empty field and keeps the text around it', () => {
    const result = applySecretPlaceholder(open, open.length, 'STRIPE_API_KEY')
    expect(result?.text).toBe(`${open}STRIPE_API_KEY${close}`)
  })

  it('does not duplicate the closing braces when the caret is inside a closed placeholder', () => {
    const text = `${open}GIT${close}`
    const caret = open.length + 'GIT'.length
    const result = applySecretPlaceholder(text, caret, 'GITHUB_TOKEN')
    expect(result?.text).toBe(`${open}GITHUB_TOKEN${close}`)
  })

  it('replaces a placeholder in the middle of a line without touching the rest', () => {
    const text = `Bearer ${open}OLD${close} trailing`
    const caret = open.length + 'Bearer '.length + 'OLD'.length
    const result = applySecretPlaceholder(text, caret, 'NEW_NAME')
    expect(result?.text).toBe(`Bearer ${open}NEW_NAME${close} trailing`)
  })

  it('refuses when there is no placeholder being typed', () => {
    expect(applySecretPlaceholder('sk-plain', 8, 'GITHUB_TOKEN')).toBeNull()
    expect(applySecretPlaceholder(open, open.length, '')).toBeNull()
  })
})
