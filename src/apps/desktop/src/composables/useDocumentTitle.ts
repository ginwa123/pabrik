import { useRouter } from 'vue-router'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useCurrentMainView } from './useCurrentMainView'

const BASE_TITLE = 'Pabrik'

/** Keep the browser tab title in sync with what the main content area is showing: the active session name for chats, the active task (or item) name for workspace … */
export function useDocumentTitle(): void {
  const navigationStore = useNavigationStore()
  const workspacesStore = useWorkspacesStore()
  const currentMainView = useCurrentMainView()

  const updateTitle = () => {
    const { kind } = currentMainView.value
    const chatName = navigationStore.activeChatName
    const taskName = workspacesStore.activeTask?.name
    const itemName = workspacesStore.activeWorkspaceItem?.name
    let name = ''
    if (kind === 'chat') {
      name = chatName
    } else if (kind === 'workspace') {
      name = taskName || itemName || ''
    }
    document.title = name ? `${name} - Pabrik` : BASE_TITLE
  }

  updateTitle()
  navigationStore.$subscribe(() => updateTitle())
  workspacesStore.$subscribe(() => updateTitle())
  try {
    // Pure URL changes (e.g.
    useRouter().afterEach(() => updateTitle())
  } catch {
    // Router absent — nothing to sync.
  }
}
