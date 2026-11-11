import type { CodeViewerState } from '../../composables/useCodeEditor'
import type { useCodeEditorSession } from '../../composables/useCodeEditorSession'

/** The open file, projected for the surfaces that render it (ChatView's centre column). One object
 * so a template binds it without narrowing, and so `AppLayout` stays under its line ceiling. */
export function buildCodeViewerState(
  session: ReturnType<typeof useCodeEditorSession>,
  close: () => void,
): CodeViewerState {
  return {
    file: session.file,
    content: session.content,
    loading: session.loading,
    error: session.error,
    requestedLine: session.requestedLine,
    cwd: session.cwd,
    diff: session.diff,
    rev: session.rev,
    pr: session.pr,
    close,
  }
}
