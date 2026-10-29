import type { Ref } from 'vue'
import type { DiffSelection } from './parseUnifiedDiff'

export type PanelEmit = {
  (e: 'show-diff', selection: DiffSelection): void
  (e: 'show-diff-list', files: DiffSelection[]): void
}

export type SelectionState = {
  path: Ref<string | null>
  staged: Ref<boolean>
}

export type PanelDataCommon = {
  cwd: () => string
  prUrl: () => string
  prProvider: () => string | undefined
  isPrMode: () => boolean
  isPrTab: () => boolean
  emit: PanelEmit
  serverError: (err: unknown, fallback: string) => string
  selection: SelectionState
  loadSeq: { current: number }
}
