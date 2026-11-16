<!--
  MoveToPageDialog — focused page picker for the right-click
  "Move to page..." menu item (plan: 2026-08-06-move-element-to-page.md).

  Layout:
    1. Header — "Move <element name> to which page?" title + close (×) button.
    2. Scrollable list of OTHER pages in the design (current page excluded).
       Each row: "→ <page name>" + click handler.
    3. Empty state when only one page exists: "This is the only page."

  The user reports from chunk 1's spec: the modal lists OTHER pages
  in the design (filters out the current page) so the user can't
  pick the page they're already on (which would be a no-op and
  would error with SamePage on the backend anyway).

  Why Teleport to body: matches the existing centered-modal pattern
  (KanbanTaskDetailDialog, DesignChatDialog). Escapes the design
  canvas's overflow / transform contexts.

  Public API:
    props:
      visible         boolean
      elementName     string — the name of the element being moved
                              (shown in the title)
      currentPageId   string — the page the element currently lives on
      pages           DesignPage[] — all pages in the design (the
                              dialog filters out currentPageId)
    emits:
      close   []
      select  [pageId: string] — user picked a target page
-->
<script setup lang="ts">
import { computed } from 'vue'
import type { DesignPage } from '../../api'

const props = defineProps<{
  visible: boolean
  elementName: string
  currentPageId: string
  pages: ReadonlyArray<DesignPage>
}>()

const emit = defineEmits<{
  close: []
  select: [pageId: string]
}>()

// Filter out the current page — picking the same page is a no-op (would error with `SamePage` on the backend).
const otherPages = computed(() => {
  const filtered = props.pages.filter((p) => p.id !== props.currentPageId)
  return [...filtered].sort((a, b) => a.position - b.position)
})

</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      style="background-color: rgba(0, 0, 0, 0.5);"
      data-testid="move-to-page-dialog-backdrop"
      @click="emit('close')"
    >
      <div
        class="rounded-lg shadow-xl flex flex-col"
        :style="{
          backgroundColor: 'var(--semantic-sidebar-bg)',
          border: '1px solid var(--color-border)',
          width: '480px',
          maxWidth: '95vw',
          maxHeight: '80vh',
        }"
        data-testid="move-to-page-dialog"
        @click.stop
      >
        <!-- Header -->
        <div
          class="flex items-center justify-between px-4 py-3"
          :style="{ borderBottom: '1px solid var(--color-border)' }"
        >
          <h3 class="text-lead font-semibold" style="color: var(--semantic-text);">
            Move "{{ elementName }}" to which page?
          </h3>
          <button
            type="button"
            class="px-2 py-1 rounded hover:opacity-80"
            style="color: var(--semantic-text-dim);"
            data-testid="move-to-page-dialog-close"
            aria-label="Close"
            @click="emit('close')"
          >
            ×
          </button>
        </div>

        <!-- Body -->
        <div class="overflow-y-auto px-2 py-2" :style="{ maxHeight: '60vh' }">
          <div
            v-if="otherPages.length === 0"
            class="px-4 py-8 text-center text-body"
            style="color: var(--semantic-text-dim);"
            data-testid="move-to-page-dialog-only-page"
          >
            This is the only page.
          </div>
          <button
            v-for="page in otherPages"
            :key="page.id"
            type="button"
            class="w-full px-4 py-3 text-left flex items-center justify-between rounded transition-colors hover:opacity-80"
            style="color: var(--semantic-text);"
            :data-testid="`move-to-page-dialog-option-${page.id}`"
            @click="emit('select', page.id)"
          >
            <span class="truncate">{{ page.name || '(untitled)' }}</span>
            <span class="text-body" style="color: var(--semantic-text-dim);">→</span>
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
