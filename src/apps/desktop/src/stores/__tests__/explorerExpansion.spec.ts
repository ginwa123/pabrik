import { describe, expect, it, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useExplorerExpansionStore } from '../explorerExpansion'
import { makeLocalStorageStub } from '../../__tests__/helpers'

const STORAGE_KEY = 'pabrik-explorer-expanded:v1'

function freshStore() {
  setActivePinia(createPinia())
  return useExplorerExpansionStore()
}

describe('explorer expansion store', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('starts with every folder collapsed', () => {
    const store = freshStore()
    expect(store.isExpanded('/repo', '/repo/src')).toBe(false)
    expect(store.expandedFor('/repo')).toEqual([])
  })

  it('reports a folder as expanded once it is expanded', () => {
    const store = freshStore()
    store.expand('/repo', '/repo/src')
    expect(store.isExpanded('/repo', '/repo/src')).toBe(true)
  })

  it('reports a folder as collapsed once it is collapsed', () => {
    const store = freshStore()
    store.expand('/repo', '/repo/src')
    store.collapse('/repo', '/repo/src')
    expect(store.isExpanded('/repo', '/repo/src')).toBe(false)
  })

  it('toggle flips the folder and answers the state it landed on', () => {
    const store = freshStore()
    expect(store.toggle('/repo', '/repo/src')).toBe(true)
    expect(store.isExpanded('/repo', '/repo/src')).toBe(true)
    expect(store.toggle('/repo', '/repo/src')).toBe(false)
    expect(store.isExpanded('/repo', '/repo/src')).toBe(false)
  })

  it('keeps each cwd on its own expansion set', () => {
    const store = freshStore()
    store.expand('/one', '/one/src')
    store.expand('/two', '/two/docs')
    expect(store.expandedFor('/one')).toEqual(['/one/src'])
    expect(store.expandedFor('/two')).toEqual(['/two/docs'])
    expect(store.isExpanded('/one', '/two/docs')).toBe(false)
  })

  it('remembers an expansion across a store re-creation', () => {
    freshStore().expand('/repo', '/repo/src')
    expect(freshStore().isExpanded('/repo', '/repo/src')).toBe(true)
  })

  it('remembers a collapse across a store re-creation', () => {
    const store = freshStore()
    store.expand('/repo', '/repo/src')
    store.collapse('/repo', '/repo/src')
    expect(freshStore().isExpanded('/repo', '/repo/src')).toBe(false)
  })

  it('starts empty when the stored payload is not valid JSON', () => {
    localStorage.setItem(STORAGE_KEY, '{not json')
    expect(freshStore().expandedFor('/repo')).toEqual([])
  })

  it('ignores stored entries that are not lists of paths', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ '/repo': 'nope', '/other': ['/other/a', 7, ''] }),
    )
    const store = freshStore()
    expect(store.expandedFor('/repo')).toEqual([])
    expect(store.expandedFor('/other')).toEqual(['/other/a'])
  })

  it('keeps only the most recently used cwds', () => {
    const store = freshStore()
    for (let i = 0; i < 21; i += 1) store.expand(`/cwd-${i}`, `/cwd-${i}/src`)
    expect(store.expandedFor('/cwd-0')).toEqual([])
    expect(store.expandedFor('/cwd-20')).toEqual(['/cwd-20/src'])
  })
})
