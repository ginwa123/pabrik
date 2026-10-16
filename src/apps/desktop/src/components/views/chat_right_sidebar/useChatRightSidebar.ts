import { ref, onMounted, onUnmounted } from 'vue'

const STORAGE_KEY_WIDTH = 'pabrik-right-sidebar-width'
const DEFAULT_WIDTH = 280
const MIN_WIDTH = 200
const MAX_WIDTH = 600

function openKey(chatType: string): string {
  return `pabrik-chat-right-sidebar-open:${chatType}`
}

function loadWidth(): number {
  try {
    const saved = localStorage.getItem(STORAGE_KEY_WIDTH)
    if (saved) {
      const parsed = parseInt(saved, 10)
      if (!isNaN(parsed) && parsed >= MIN_WIDTH && parsed <= MAX_WIDTH) return parsed
    }
  } catch {
    // localStorage unavailable (SSR/tests) — fall through to default.
  }
  return DEFAULT_WIDTH
}

function loadOpen(chatType: string): boolean {
  try {
    const saved = localStorage.getItem(openKey(chatType))
    if (saved !== null) return saved === 'true'
  } catch {
    // ignore
  }
  // Default closed so the chat keeps its full width until the user opts in.
  return false
}

// Per-chat right-sidebar state for ChatView. Single git-diff panel —
// no tab state. Persists width globally (shared with the legacy
// sidebar key) and open/closed per chat type (`chat` | `task`).
export function useChatRightSidebar(chatType: string) {
  const isOpen = ref(loadOpen(chatType))
  const width = ref(loadWidth())
  const selectedFile = ref<{ path: string; staged: boolean } | null>(null)

  const saveWidth = () => {
    try {
      localStorage.setItem(STORAGE_KEY_WIDTH, width.value.toString())
    } catch {
      // ignore
    }
  }

  const saveOpen = () => {
    try {
      localStorage.setItem(openKey(chatType), isOpen.value ? 'true' : 'false')
    } catch {
      // ignore
    }
  }

  const setWidth = (w: number) => {
    width.value = Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, w))
    saveWidth()
  }

  const toggle = () => {
    isOpen.value = !isOpen.value
    saveOpen()
  }

  const open = () => {
    if (!isOpen.value) {
      isOpen.value = true
      saveOpen()
    }
  }

  const close = () => {
    if (isOpen.value) {
      isOpen.value = false
      saveOpen()
    }
  }

  const selectFile = (path: string, staged: boolean) => {
    selectedFile.value = { path, staged }
  }

  const clearSelection = () => {
    selectedFile.value = null
  }

  const onKeydown = (e: KeyboardEvent) => {
    const mod = e.metaKey || e.ctrlKey
    if (mod && e.key.toLowerCase() === 'b') {
      e.preventDefault()
      toggle()
    }
  }

  onMounted(() => {
    window.addEventListener('keydown', onKeydown)
  })
  onUnmounted(() => {
    window.removeEventListener('keydown', onKeydown)
  })

  // NOTE: `chatType` is a plain (non-reactive) parameter fixed per composable instance — observing
  // it would never fire, since the source never changes. Each instance already hydrates via
  // `ref(loadOpen(chatType))` above, so there is nothing to re-sync.
  return {
    isOpen,
    width,
    selectedFile,
    toggle,
    open,
    close,
    setWidth,
    selectFile,
    clearSelection,
    MIN_WIDTH,
    MAX_WIDTH,
  }
}
