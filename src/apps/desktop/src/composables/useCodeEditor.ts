import { inject, type InjectionKey, type Ref } from 'vue'
import type { FolderEntry } from '../api'

/** Options for opening a file in the in-app CodeEditor. */
export type OpenInCodeEditorOptions = {
  filePath: string
  fileName?: string
  cwd: string
  /**    * Optional 1-based line number to scroll to when the editor opens. When `undefined`, the editor
   * opens at line 1. Threaded through from the diff-view's `@jump-to-line` emit so the user can
   * click a line in the diff and land on that exact line in the editor. */
  line?: number
  /**    * Open the same file on its changes: `?mode=diff`. A file and its diff are two entries in a
   * session's strip, not one entry with a toggle. */
  diff?: boolean
  /**    * The commit whose changes the diff shows (`?rev=`). A commit row's diff is that commit's, not
   * the worktree's. */
  rev?: string
  /**    * The pull request whose changes the diff shows (`?pr=`). A PR row's diff is the request's, not
   * the worktree's. */
  pr?: string
}

export type OpenInCodeEditorFn = (opts: OpenInCodeEditorOptions) => Promise<void> | void

export const OPEN_IN_CODE_EDITOR_KEY: InjectionKey<OpenInCodeEditorFn> = Symbol(
  'openInCodeEditor',
) as InjectionKey<OpenInCodeEditorFn>

/**  * Inject the `openInCodeEditor` handler provided by `AppLayout`. Returns `null` when the component
 * is rendered outside of an `AppLayout` subtree (e.g. in unit tests), so the calling component can
 * gracefully hide its "Open in editor" button. */
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

/**  * Inject the open-file state provided by `AppLayout`. `null` outside an `AppLayout` subtree (unit
 * tests) — callers then render nothing, which is exactly the pre-existing behaviour for a chat with
 * no file open. */
export function useInjectCodeViewer(): CodeViewerState | null {
  return inject(CODE_VIEWER_STATE_KEY, null)
}

/**  * Never-null projection of `CodeViewerState` for templates: the reactive refs unwrapped to plain
 * values, or an empty model when there is no provider. A template can then bind one object without
 * narrowing. */
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
