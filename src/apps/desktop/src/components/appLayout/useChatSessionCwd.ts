import { ref, type Ref } from 'vue'
import * as api from '../../api'
import type { useNavigationStore } from '../../stores/navigation'

type NavigationStore = ReturnType<typeof useNavigationStore>

export interface UseChatSessionCwdReturn {
  chatSessionCwd: Ref<string>
  fetchChatSessionCwd: (sessionId: string) => Promise<void>
}

/** Chat session cwd for the folder explorer and git panel, fetched from the API. */
export function useChatSessionCwd(navigationStore: NavigationStore): UseChatSessionCwdReturn {
  const chatSessionCwd = ref<string>('')

  // Session-cwd localStorage cache (replaces the old chatSessionCwd watcher).
  const writeSessionCwdCache = (newCwd: string) => {
    if (newCwd && navigationStore.activeChatId) {
      const sessionId = navigationStore.activeChatId.replace(/^chat-/, '')
      localStorage.setItem(`session_cwd_${sessionId}`, newCwd)
    }
  }

  const fetchChatSessionCwd = async (sessionId: string) => {
    chatSessionCwd.value = ''
    try {
      // Single lightweight detail read (GET /api/llm/session/:id, no message payload).
      const session = await api.getSession(sessionId)
      if (session && session.cwd) {
        chatSessionCwd.value = session.cwd
        writeSessionCwdCache(session.cwd)
      }
    } catch (err) {
      console.error('Failed to fetch chat session cwd:', err)
    }
  }

  return { chatSessionCwd, fetchChatSessionCwd }
}
