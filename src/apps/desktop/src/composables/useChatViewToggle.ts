/** Grouped transcript vs the raw `llm_history` table. Module state, not a prop: `ChatAppBar.vue`
 * is mounted bare in specs and rendered by every chat host, and all of them share one value. */
import { computed } from 'vue'
import { chatViewMode, setChatViewMode } from '../stores/chatView'

export function useChatViewToggle() {
  const isRaw = computed(() => chatViewMode.value === 'raw')
  const label = computed(() => (isRaw.value ? 'Rows' : 'Grouped'))
  const nextLabel = computed(() => (isRaw.value ? 'Grouped' : 'Rows'))

  /** `raw` is a view of the same rows, so leaving it returns to the grouped transcript. */
  const toggle = (): void => {
    setChatViewMode(isRaw.value ? 'dev' : 'raw')
  }

  return { isRaw, label, nextLabel, toggle }
}
