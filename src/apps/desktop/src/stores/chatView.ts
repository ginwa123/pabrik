/** How the chat draws its history. The mode lives in `config.json` (`chat_view`), so it travels
 * with the profile; this store is the app's copy of that value. */
import { defineStore } from 'pinia'
import { ref } from 'vue'

/** `dev` and `compact` differ in how tool calls are drawn; `raw` replaces the grouped transcript
 * with one line per `llm_history` row. */
export type ChatViewMode = 'dev' | 'compact' | 'raw'

/** Anything but "compact" or "raw" is the dev view. */
export function chatViewModeFrom(config: { chat_view?: string | null } | null): ChatViewMode {
  if (config?.chat_view === 'compact') return 'compact'
  if (config?.chat_view === 'raw') return 'raw'
  return 'dev'
}

// Module scope, not inside `defineStore`: `ChatAppBar.vue` is mounted bare in
// specs with no pinia installed, and its view toggle must work there.
const mode = ref<ChatViewMode>('dev')

export const chatViewMode = mode

export function setChatViewMode(next: ChatViewMode): void {
  mode.value = next
}

export const useChatViewStore = defineStore('chatView', () => {
  function setMode(next: ChatViewMode): void {
    setChatViewMode(next)
  }

  return { mode, setMode }
})
