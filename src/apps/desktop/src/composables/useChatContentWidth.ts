/**
 * Transcript width preference — module state, three presets, remembered per browser.
 */
import { computed, ref } from 'vue'

export type ChatContentWidth = 'comfortable' | 'wide' | 'full'

export const CHAT_CONTENT_WIDTH_STORAGE_KEY = 'pabrik-chat-content-width'

/** The CSS lives in ChatView.vue's `.chat-column` block; this maps preset → class. */
const PRESET_CLASS: Record<ChatContentWidth, string> = {
  comfortable: 'chat-width-comfortable',
  wide: 'chat-width-wide',
  full: '',
}

const PRESET_LABEL: Record<ChatContentWidth, string> = {
  comfortable: 'Comfortable',
  wide: 'Wide',
  full: 'Full',
}

/** Click order. `full` is the default, so one click steps in and not out. */
const CYCLE: ChatContentWidth[] = ['comfortable', 'wide', 'full']

const isPreset = (value: unknown): value is ChatContentWidth =>
  value === 'comfortable' || value === 'wide' || value === 'full'

// jsdom dropped localStorage from its default globals and Node's own is absent
// without --localstorage-file, so every access goes through this guard: a missing
// store means "no preference", never a crash at import time.
const store = (): Storage | undefined => {
  if (typeof window === 'undefined') return undefined
  return (window as { localStorage?: Storage }).localStorage
}

const read = (): ChatContentWidth => {
  const saved = store()?.getItem(CHAT_CONTENT_WIDTH_STORAGE_KEY) ?? null
  return isPreset(saved) ? saved : 'full'
}

// Module scope, not a pinia store: ChatAppBar.vue is mounted bare in specs and
// rendered by three different chat hosts, and all of them must share one value.
const width = ref<ChatContentWidth>(read())

const setWidth = (next: ChatContentWidth): void => {
  width.value = next
  store()?.setItem(CHAT_CONTENT_WIDTH_STORAGE_KEY, next)
}

const cycleWidth = (): void => {
  setWidth(CYCLE[(CYCLE.indexOf(width.value) + 1) % CYCLE.length]!)
}

const presetClass = computed(() => PRESET_CLASS[width.value])

const label = computed(() => PRESET_LABEL[width.value])

const nextLabel = computed(
  () => PRESET_LABEL[CYCLE[(CYCLE.indexOf(width.value) + 1) % CYCLE.length]!],
)

export function useChatContentWidth() {
  return { width, presetClass, label, nextLabel, setWidth, cycleWidth }
}
