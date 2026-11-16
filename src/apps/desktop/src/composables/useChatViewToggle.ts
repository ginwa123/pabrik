/** Grouped transcript vs the raw `llm_history` table. */
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
