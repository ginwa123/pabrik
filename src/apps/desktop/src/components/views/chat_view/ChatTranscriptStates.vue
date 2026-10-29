<script setup lang="ts">
import UiIcon from '../../ui/UiIcon.vue'
import type { MessageGroup } from './useChatMessagePresentation'

defineProps<{
  isLoadingMore: boolean
  isInitializing: boolean
  isLoading: boolean
  error: string | null
  historyConfirmed: boolean
  messageGroups: MessageGroup[]
  hasMoreMessages: boolean
  scrollerIsScrollable: boolean
  pageSize: number
  loadChatHistory: () => void
  maybeLoadOlder: (trigger: 'edge' | 'manual') => void
}>()
</script>

<template>
  <!-- Loading More indicator (floats above the scroller during pagination). -->
  <div
    v-if="isLoadingMore"
    class="absolute top-0 left-0 right-0 flex justify-center py-2 z-10 pointer-events-none"
    data-testid="chat-loading-more"
    role="status"
    aria-label="Loading older messages"
  >
    <div
      class="flex items-center gap-2 px-4 py-2 rounded-full shadow-sm"
      style="background-color: var(--semantic-card-bg)"
    >
      <div
        class="w-4 h-4 border-2 rounded-full animate-spin"
        style="border-color: var(--color-violet); border-top-color: transparent"
      ></div>
      <span class="text-body" style="color: var(--semantic-text-dim)">Loading more...</span>
    </div>
  </div>

  <!-- Initializing skeleton — shown while the remote half of the. -->
  <div
    v-if="isInitializing"
    data-testid="chat-initializing-skeleton"
    class="flex flex-col gap-3 px-4 max-w-[var(--chat-content-max)] mx-auto pt-6 w-full"
    role="status"
    aria-label="Loading conversation"
  >
    <div
      v-for="w in ['42%', '88%', '67%']"
      :key="w"
      class="h-4 rounded animate-pulse"
      :style="{ width: w, backgroundColor: 'var(--semantic-card-bg)' }"
    ></div>
  </div>

  <!-- Load error — `error` was previously write-only (set on fetch
       failure but never rendered). Shown only once initializing is
       over and no messages arrived. -->
  <div
    v-if="error && !isInitializing && messageGroups.length === 0"
    data-testid="chat-load-error"
    class="flex flex-col items-center justify-center h-full px-4"
  >
    <p class="text-body mb-3" style="color: var(--semantic-text-dim)">{{ error }}</p>
    <button
      @click="loadChatHistory()"
      class="px-4 py-1.5 rounded-full text-dense"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
    >
      Retry
    </button>
  </div>

  <!-- Empty State --. -->
  <div
    v-if="historyConfirmed && !isInitializing && !isLoading && !error && messageGroups.length === 0"
    class="flex flex-col items-center justify-center h-full px-4"
  >
    <div
      class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-display"
      style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
    >
      <UiIcon name="chat" size-class="w-7 h-7" />
    </div>
    <h3 class="text-title-sm font-medium mb-2" style="color: var(--semantic-text)">
      How can I help you?
    </h3>
    <p class="text-body text-center" style="color: var(--semantic-text-dim)">
      Start a conversation by typing a message below
    </p>
  </div>

  <!-- Load more messages button. -->
  <div
    v-if="hasMoreMessages && !isLoadingMore && messageGroups.length > 0 && !scrollerIsScrollable"
    class="flex justify-center pt-2 pb-1"
    data-testid="load-more-messages"
  >
    <button
      @click="maybeLoadOlder('manual')"
      class="flex items-center gap-2 px-4 py-1.5 rounded-full text-dense transition-all duration-200 hover:scale-105"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      :title="`Load ${pageSize} older messages`"
    >
      <span>↑</span>
      <span>Load more messages</span>
    </button>
  </div>
</template>
