import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { userScopedKey } from '../helpers/userScope'

// Storage keys
const STORAGE_KEY_SIDEBAR_COLLAPSED = 'sidebar-collapsed'
const STORAGE_KEY_SIDEBAR_WIDTH = 'sidebar-width'
const STORAGE_KEY_ACTIVE_CHAT_ID = 'active-chat-id'
const STORAGE_KEY_ACTIVE_CHAT_NAME = 'active-chat-name'
const STORAGE_KEY_ACTIVE_TASK_ID = 'active-task-id'
const STORAGE_KEY_CHATS_SORT_DIRECTION = 'pabrik_chats_sort_direction'

export const useNavigationStore = defineStore('navigation', () => {
  // Sidebar state
  const sidebarCollapsed = ref(loadSidebarCollapsed())
  const sidebarWidth = ref(loadSidebarWidth())

  // Active chat state
  const activeChatId = ref('')
  const activeChatName = ref('')

  // Active task state
  const activeTaskId = ref<string | null>(null)

  // Chats sort direction
  const chatsSortDirection = ref(loadChatsSortDirection())

  // Sub-agent peek panel state. When set, <ChatView> renders <SubAgentPeekPanel> for the given
  // sub-agent session. The payload carries everything the panel needs from the spawn_sub_agent tool
  // card (so we don't have to re-parse the message).
  const peekPanel = ref<{
    sessionId: string
    agentName: string
    instruction: string
  } | null>(null)

  function openPeek(payload: { sessionId: string; agentName: string; instruction: string }) {
    peekPanel.value = payload
  }

  function closePeek() {
    peekPanel.value = null
  }

  // Helper functions
  function loadSidebarCollapsed(): boolean {
    const saved = localStorage.getItem(STORAGE_KEY_SIDEBAR_COLLAPSED)
    if (saved !== null) {
      return saved === 'true'
    }
    return false // Default to not collapsed
  }

  function loadSidebarWidth(): number {
    const saved = localStorage.getItem(STORAGE_KEY_SIDEBAR_WIDTH)
    if (saved !== null) {
      const parsed = parseInt(saved, 10)
      if (!isNaN(parsed)) {
        return Math.max(72, Math.min(480, parsed))
      }
    }
    return 288 // Default width
  }

  function loadChatsSortDirection(): 'asc' | 'desc' {
    const saved = localStorage.getItem(STORAGE_KEY_CHATS_SORT_DIRECTION)
    return saved === 'asc' ? 'asc' : 'desc'
  }

  // Sidebar actions
  function setSidebarCollapsed(collapsed: boolean) {
    sidebarCollapsed.value = collapsed
    localStorage.setItem(STORAGE_KEY_SIDEBAR_COLLAPSED, String(collapsed))
  }

  function toggleSidebar() {
    setSidebarCollapsed(!sidebarCollapsed.value)
  }

  function setSidebarWidth(width: number) {
    sidebarWidth.value = Math.max(72, Math.min(480, width))
    localStorage.setItem(STORAGE_KEY_SIDEBAR_WIDTH, String(sidebarWidth.value))
  }

  // Chats sort direction action
  function setChatsSortDirection(direction: 'asc' | 'desc') {
    chatsSortDirection.value = direction
    localStorage.setItem(STORAGE_KEY_CHATS_SORT_DIRECTION, direction)
  }

  // Chat actions
  function setActiveChat(sessionId: string, name?: string) {
    activeChatId.value = sessionId ? `chat-${sessionId}` : ''
    if (name) activeChatName.value = name
    if (sessionId) {
      localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_ID), sessionId)
    } else {
      localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_ID))
    }
    if (name) {
      localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_NAME), name)
    }
    // Clear task when setting chat
    clearActiveTask()
  }

  function setActiveChatName(name: string) {
    activeChatName.value = name
    localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_NAME), name)
  }

  function clearActiveChat() {
    activeChatId.value = ''
    activeChatName.value = ''
    localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_ID))
    localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_NAME))
  }

  // Task actions
  function setActiveTask(taskId: string | null) {
    activeTaskId.value = taskId
    if (taskId) {
      localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_TASK_ID), taskId)
    } else {
      localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_TASK_ID))
    }
    // Clear chat when ACTIVATING a task.
    if (taskId !== null) {
      clearActiveChat()
    }
  }

  function clearActiveTask() {
    activeTaskId.value = null
    localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_TASK_ID))
  }

  // Clear all active state
  function clearAll() {
    clearActiveChat()
    clearActiveTask()
  }

  // Initialize from URL params (called on app mount)
  function initFromUrl(sessionId?: string, taskId?: string, view?: string) {
    if (view === 'chat' && sessionId) {
      // From URL params, we just set the ID - name comes from localStorage or API
      activeChatId.value = `chat-${sessionId}`
      activeChatName.value = localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_NAME)) || ''
    } else if (view === 'task' && taskId) {
      setActiveTask(taskId)
    } else {
      // Fallback to localStorage
      const savedChatId = localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_ID))
      const savedChatName = localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_CHAT_NAME))
      const savedTaskId = localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_TASK_ID))

      if (savedChatId) {
        activeChatId.value = `chat-${savedChatId}`
      }
      if (savedChatName) {
        activeChatName.value = savedChatName
      }
      if (savedTaskId && view === 'task') {
        activeTaskId.value = savedTaskId
      }
    }
  }

  // Computed for getting just the session ID (without chat- prefix)
  const sessionId = computed(() => {
    return activeChatId.value.replace(/^chat-/, '')
  })

  return {
    // State
    sidebarCollapsed,
    sidebarWidth,
    activeChatId,
    activeChatName,
    activeTaskId,
    chatsSortDirection,
    peekPanel,
    // Computed
    sessionId,
    // Actions
    setSidebarCollapsed,
    toggleSidebar,
    setSidebarWidth,
    setChatsSortDirection,
    setActiveChat,
    setActiveChatName,
    clearActiveChat,
    setActiveTask,
    clearActiveTask,
    clearAll,
    initFromUrl,
    openPeek,
    closePeek,
  }
})