import { onMounted, onUnmounted, ref } from 'vue'
import {
  fetchPrConflictCached,
  fetchPrStatusCached,
  onPrStatusInvalidated,
} from '../../../helpers/prStatusCache'
import { effectiveChatCwd, type ChatRow } from './chatRowHelpers'

export interface FilePickerPrStatusDeps {
  navItems: { readonly value: ChatRow[] }
}

export function useChatsPrStatus(deps: FilePickerPrStatusDeps) {
  const { navItems } = deps

  // PR branch badges use the same palette as WorkspaceItemTaskCard:
  // green = open, violet = merged, red = closed. Rows without a pull
  // request omit the badge entirely.
  const prStatuses = ref<Record<string, string>>({})
  // Conflict-only hint per chat: true when the PR reports CONFLICTING/DIRTY.
  // Quiet-when-clean — absent/false for mergeable, unknown, or failed fetches.
  const prConflicts = ref<Record<string, boolean>>({})
  const prSeqByChat = new Map<string, number>()

  const refreshChatPrStatus = async (item: ChatRow) => {
    const branch = item.git_branch || ''
    const cwd = effectiveChatCwd(item)
    if (!branch || !cwd) {
      if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
      if (prConflicts.value[item.id]) delete prConflicts.value[item.id]
      return
    }
    const seq = (prSeqByChat.get(item.id) || 0) + 1
    prSeqByChat.set(item.id, seq)
    // Shared cache: dedupes the list-load burst across rows, retries
    // transient failures, resolves '' (fail-silent) when unknown.
    const [status, hasConflict] = await Promise.all([
      fetchPrStatusCached(cwd, branch),
      fetchPrConflictCached(cwd, branch),
    ])
    if (prSeqByChat.get(item.id) !== seq) return
    if (status) prStatuses.value[item.id] = status
    else if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
    if (hasConflict) prConflicts.value[item.id] = true
    else if (prConflicts.value[item.id]) delete prConflicts.value[item.id]
  }

  // Resolve PR colors whenever the row list (re)populates — same burst
  // pattern as the kanban board mount. Runs at the end of loadChats().
  const burstChatPrStatus = () => {
    for (const item of navItems.value || []) {
      if (item.git_branch) void refreshChatPrStatus(item)
    }
  }

  // A merge or close ANYWHERE — this tab's MergeBox, or the `git_pr_state` SSE event from another
  // client — drops the shared cache entry and calls this back.
  let unsubscribePrStatus: (() => void) | null = null
  onMounted(() => {
    unsubscribePrStatus = onPrStatusInvalidated(() => {
      burstChatPrStatus()
    })
  })
  onUnmounted(() => {
    unsubscribePrStatus?.()
    unsubscribePrStatus = null
  })

  return { prStatuses, prConflicts, refreshChatPrStatus, burstChatPrStatus }
}
