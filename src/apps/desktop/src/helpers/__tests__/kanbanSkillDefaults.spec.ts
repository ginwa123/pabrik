/** Behaviour of the create-task skill defaults: what the picker remembers for
 * a board, and which remembered names it may prefill. */
import { describe, expect, it } from 'vitest'
import {
  browserSkillDefaultsStorage,
  readSkillDefaults,
  resolveDefaultSkills,
  skillDefaultsKey,
  writeSkillDefaults,
  type SkillDefaultsStorage,
} from '../kanbanSkillDefaults'

function fakeStorage(seed: Record<string, string> = {}): SkillDefaultsStorage {
  const rows = new Map(Object.entries(seed))
  return {
    getItem: (key) => rows.get(key) ?? null,
    setItem: (key, value) => {
      rows.set(key, value)
    },
  }
}

describe('skill defaults remembered per board', () => {
  it('a board with no remembered picks starts empty', () => {
    const storage = fakeStorage()

    expect(readSkillDefaults(storage, skillDefaultsKey('ws_1', 'item_1'))).toEqual([])
  })

  it('keeps the pick order the user clicked', () => {
    const storage = fakeStorage()
    const key = skillDefaultsKey('ws_1', 'item_1')

    writeSkillDefaults(storage, key, ['prove-your-work', 'no-comments'])

    expect(readSkillDefaults(storage, key)).toEqual(['prove-your-work', 'no-comments'])
  })

  it('remembers an explicit "none" as none', () => {
    const storage = fakeStorage()
    const key = skillDefaultsKey('ws_1', 'item_1')
    writeSkillDefaults(storage, key, ['pdf'])

    writeSkillDefaults(storage, key, [])

    expect(readSkillDefaults(storage, key)).toEqual([])
  })

  it("one board never inherits another board's picks", () => {
    const storage = fakeStorage()
    writeSkillDefaults(storage, skillDefaultsKey('ws_1', 'item_1'), ['pdf'])

    expect(readSkillDefaults(storage, skillDefaultsKey('ws_1', 'item_2'))).toEqual([])
    expect(readSkillDefaults(storage, skillDefaultsKey('ws_2', 'item_1'))).toEqual([])
  })

  it('drops blank and repeated names from a stored value', () => {
    const storage = fakeStorage({ k: '||pdf||||pdf||no-comments||' })

    expect(readSkillDefaults(storage, 'k')).toEqual(['pdf', 'no-comments'])
  })

  it('degrades to no storage at all', () => {
    expect(readSkillDefaults(browserSkillDefaultsStorage(), 'unused-key-xyz')).toEqual([])
  })
})

describe('prefilling the picker from remembered picks', () => {
  const available = ['pdf', 'no-comments', 'behavior-unit-tests']

  it('keeps every remembered skill the workspace still has', () => {
    expect(resolveDefaultSkills(['no-comments', 'behavior-unit-tests'], available)).toEqual([
      'no-comments',
      'behavior-unit-tests',
    ])
  })

  it('skips a remembered skill that was deleted from the workspace', () => {
    expect(resolveDefaultSkills(['pdf', 'deleted-skill'], available)).toEqual(['pdf'])
  })

  it('prefills nothing when the remembered set is all gone', () => {
    expect(resolveDefaultSkills(['deleted-skill'], available)).toEqual([])
  })

  it('prefills nothing when nothing was remembered', () => {
    expect(resolveDefaultSkills([], available)).toEqual([])
  })
})
