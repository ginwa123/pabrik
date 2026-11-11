import { readStorage, writeStorage } from './tabsStorage'

export type DiffMode = 'unified' | 'split'

/** Both diff surfaces read the same preference, so "I always read split" is set once. */
const DIFF_MODE_STORAGE_KEY = 'pabrik.centerdiff.mode'

export function readDiffMode(): DiffMode {
  const stored = readStorage(DIFF_MODE_STORAGE_KEY)
  return stored === 'split' ? 'split' : 'unified'
}

export function writeDiffMode(mode: DiffMode): void {
  writeStorage(DIFF_MODE_STORAGE_KEY, mode)
}
