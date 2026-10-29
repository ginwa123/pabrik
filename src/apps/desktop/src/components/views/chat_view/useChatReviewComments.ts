import { computed, ref, type Ref } from 'vue'
import { copyTextToClipboard } from '../chat_right_sidebar/DiffCommentBox.vue'
import type { DiffSelection } from '../chat_right_sidebar/parseUnifiedDiff'

export interface SavedReviewComment {
  filePath: string
  message: string
  formatted: string
  savedAt: number
}

export interface ChatReviewCommentsDeps {
  centerFiles: Ref<DiffSelection[]>
  initial: SavedReviewComment[]
  persist: (comments: SavedReviewComment[]) => void
}

export function useChatReviewComments({ centerFiles, initial, persist }: ChatReviewCommentsDeps) {
  const savedReviewComments = ref<SavedReviewComment[]>(initial)

  function appendSavedReviewComment(entry: SavedReviewComment): void {
    savedReviewComments.value = [...savedReviewComments.value, entry].slice(-200)
    persist(savedReviewComments.value)
  }

  // Legacy compat: the old mini-chat emitted raw markdown for the LLM.
  // Now it only persists — never calls api.sendChatMessage.
  function onChatSidebarSubmitReview(message: string) {
    appendSavedReviewComment({ filePath: '', message, formatted: message, savedAt: Date.now() })
  }

  function onChatSidebarCommentSaved(payload: {
    filePath: string
    startLine: number
    endLine: number
    message: string
    formatted: string
  }) {
    appendSavedReviewComment({
      filePath: payload.filePath,
      message: payload.message,
      formatted: payload.formatted,
      savedAt: Date.now(),
    })
  }

  const reviewCommentsForDiff = computed(() => {
    const order = new Map(centerFiles.value.map((f, i) => [f.path, i]))
    return savedReviewComments.value
      .filter((e) => order.has(e.filePath))
      .sort((a, b) => (order.get(a.filePath) ?? 0) - (order.get(b.filePath) ?? 0))
  })

  const copiedAllReviews = ref(false)
  let copiedAllTimer: ReturnType<typeof setTimeout> | null = null

  async function copyAllReviewComments() {
    const body = reviewCommentsForDiff.value.map((e) => e.formatted).join('\n\n---\n\n')
    if (!body) return
    await copyTextToClipboard(body)
    copiedAllReviews.value = true
    if (copiedAllTimer) clearTimeout(copiedAllTimer)
    copiedAllTimer = setTimeout(() => {
      copiedAllReviews.value = false
    }, 2000)
  }

  return {
    copiedAllReviews,
    copyAllReviewComments,
    onChatSidebarCommentSaved,
    onChatSidebarSubmitReview,
    reviewCommentsForDiff,
    savedReviewComments,
  }
}
