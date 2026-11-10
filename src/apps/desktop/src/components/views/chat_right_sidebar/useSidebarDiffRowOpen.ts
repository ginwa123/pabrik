import type { Ref } from 'vue'
import type { GitCommit, GitCommitFile, GitFileChange } from '../../../api'
import { useInjectOpenInCodeEditor } from '../../../composables/useCodeEditor'
import { isBackgroundOpenEvent } from '../../../helpers/tabTarget'
import type { SplitDiffFile } from './parseUnifiedDiff'

type Deps = {
  cwd: () => string
  prFiles: Ref<SplitDiffFile[]>
  openInBrowserTab: (path: string) => void
  selectFile: (file: GitFileChange, staged: boolean) => void
  selectPrFile: (file: SplitDiffFile) => void
  togglePreview: (path: string) => void
  onCommitFileClick: (payload: { commit: GitCommit; file: GitCommitFile }) => void
}

export function useSidebarDiffRowOpen(deps: Deps) {
  const openInEditor = useInjectOpenInCodeEditor()

  const openFileInEditor = (path: string): boolean => {
    if (!openInEditor || !deps.cwd()) return false
    void openInEditor({ filePath: path, cwd: deps.cwd() })
    return true
  }

  const onFileRowClick = (event: MouseEvent, file: GitFileChange, staged: boolean) => {
    if (isBackgroundOpenEvent(event)) {
      deps.openInBrowserTab(file.path)
      return
    }
    if (openFileInEditor(file.path)) return
    deps.selectFile(file, staged)
  }

  const onPrFileRowClick = (event: MouseEvent, file: SplitDiffFile) => {
    if (isBackgroundOpenEvent(event)) {
      deps.openInBrowserTab(file.path)
      return
    }
    if (openFileInEditor(file.path)) return
    deps.selectPrFile(file)
    deps.togglePreview(file.path)
  }

  const onCommitFileRowClick = (payload: { commit: GitCommit; file: GitCommitFile }) => {
    const raw = payload.file.path
    const path = raw.includes(' -> ') ? (raw.split(' -> ').pop() ?? raw) : raw
    if (openFileInEditor(path)) return
    deps.onCommitFileClick(payload)
  }

  const onConflictFileClick = (path: string) => {
    if (openFileInEditor(path)) return
    const file = deps.prFiles.value.find((candidate) => candidate.path === path)
    if (file) {
      deps.selectPrFile(file)
      return
    }
    deps.openInBrowserTab(path)
  }

  return { onFileRowClick, onPrFileRowClick, onCommitFileRowClick, onConflictFileClick }
}
