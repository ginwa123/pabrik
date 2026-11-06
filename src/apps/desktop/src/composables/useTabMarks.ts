import { onMounted, ref } from 'vue'
import { countDiffLines } from '../components/views/chat_right_sidebar/parseUnifiedDiff'
import { fetchFolderDiff } from '../helpers/folderDiffCache'
import {
  cwdOf,
  fileOf,
  markOf,
  recordSeen,
  type TabCounts,
  type TabMark,
} from '../helpers/tabMarks'
import type { Tab } from '../helpers/tabTarget'

type TabMarksOptions = {
  tabs: () => Tab[]
  activeId: () => string
  /** False where there is no working directory to ask about (a bare chat). */
  enabled: () => boolean
}

/** The counts a session's file tabs wear, refreshed from the gestures that change the row. */
export function useTabMarks(opts: TabMarksOptions) {
  const counts = ref<Record<string, TabCounts>>({})
  const seen = ref<Record<string, TabCounts>>({})

  async function refresh(): Promise<void> {
    if (!opts.enabled()) return
    const tabs = opts.tabs().filter((tab) => fileOf(tab) !== '' && cwdOf(tab) !== '')
    if (tabs.length === 0) return
    const settled = await Promise.allSettled(
      tabs.map((tab) => fetchFolderDiff(cwdOf(tab), fileOf(tab), false)),
    )
    const next: Record<string, TabCounts> = {}
    settled.forEach((result, index) => {
      if (result.status !== 'fulfilled') return
      const tab = tabs[index]
      if (tab) next[fileOf(tab)] = countDiffLines(result.value.diff_content)
    })
    if (Object.keys(next).length === 0) return
    counts.value = { ...counts.value, ...next }
    // Whatever is on screen now has been seen: a square means "changed while you were elsewhere".
    const active = opts.tabs().find((tab) => tab.id === opts.activeId())
    if (active) seen.value = recordSeen(seen.value, counts.value, [fileOf(active)])
  }

  onMounted(() => void refresh())

  function markOfTab(tab: Tab): TabMark {
    return markOf(tab, tab.id === opts.activeId(), counts.value, seen.value)
  }

  return { counts, seen, markOfTab, refresh }
}
