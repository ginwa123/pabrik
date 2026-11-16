import { inject, type InjectionKey, type Ref } from 'vue'
import type { FolderEntry } from '../api'

/** Options for opening a file in the in-app CodeEditor. */
export type OpenInCodeEditorOptions = {
  filePath: string
  fileName?: string
  cwd: string
  /** Optional 1-based line number to scroll to when the editor opens. */
  line?: number
  /** Open the same file on its changes: `?mode=diff`. */
  diff?: boolean
  /** The commit whose changes the diff shows (`?rev=`). */
  rev?: string
  /** The pull request whose changes the diff shows (`?pr=`). */
  pr?: string
}

export type OpenInCodeEditorFn = (opts: OpenInCodeEditorOptions) => Promise<void> | void

export const OPEN_IN_CODE_EDITOR_KEY: InjectionKey<OpenInCodeEditorFn> = Symbol(
  'openInCodeEditor',
) as InjectionKey<OpenInCodeEditorFn>

/** Inject the `openInCodeEditor` handler provided by `AppLayout`. */
export function useInjectOpenInCodeEditor(): OpenInCodeEditorFn | null {
  return inject(OPEN_IN_CODE_EDITOR_KEY, null)
}

/** The open file the code viewer is showing, shared by provide/inject. */
export type CodeViewerState = {
  file: Ref<FolderEntry | null>
  content: Ref<string>
  loading: Ref<boolean>
  error: Ref<string | null>
  requestedLine: Ref<number | null>
  /** The cwd the file was opened with (never a recomputed sidebar value). */
  cwd: Ref<string>
  /** True when this target is the file's changes rather than the file. */
  diff: Ref<boolean>
  /** The commit whose changes the diff shows. Empty = the worktree's. */
  rev: Ref<string>
  /** The pull request whose changes the diff shows. Empty = the worktree's. */
  pr: Ref<string>
  /** Close the viewer: clear the session and strip the URL keys. */
  close: () => void
}

export const CODE_VIEWER_STATE_KEY: InjectionKey<CodeViewerState> = Symbol(
  'codeViewerState',
) as InjectionKey<CodeViewerState>

/** Inject the open-file state provided by `AppLayout`. */
export function useInjectCodeViewer(): CodeViewerState | null {
  return inject(CODE_VIEWER_STATE_KEY, null)
}

/** Never-null projection of `CodeViewerState` for templates: the reactive refs unwrapped to plain values, or an empty model when there is no provider. */
export type CodeViewerView = {
  file: FolderEntry | null
  content: string
  loading: boolean
  error: string | null
  line: number | null
  cwd: string
  diff: boolean
  rev: string
  pr: string
  close: () => void
}
