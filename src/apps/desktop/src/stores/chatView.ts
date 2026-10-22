/** How the chat draws tool calls. The mode lives in `config.json` (`chat_view`), so it
 * travels with the profile; this store is the app's copy of that value. */
import { defineStore } from 'pinia'
import { ref } from 'vue'

export type ChatViewMode = 'dev' | 'compact'

/** Anything but "compact" is the dev view. */
export function chatViewModeFrom(config: { chat_view?: string | null } | null): ChatViewMode {
  return config?.chat_view === 'compact' ? 'compact' : 'dev'
}

export const useChatViewStore = defineStore('chatView', () => {
  const mode = ref<ChatViewMode>('dev')

  function setMode(next: ChatViewMode): void {
    mode.value = next
  }

  return { mode, setMode }
})
