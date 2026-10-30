<script setup lang="ts">
import { ref } from 'vue'
import type { PanelTab } from './sidebarDiffUrl'

defineProps<{
  isPrMode: boolean
  activeTab: PanelTab
  conversationCount: number
  changeCount: number
  prCount: number
  forgeShort: string
}>()

const emit = defineEmits<{ select: [tab: PanelTab] }>()

const tabStrip = ref<HTMLElement | null>(null)
const stripOverflows = ref(false)

const setActiveTab = (tab: PanelTab) => emit('select', tab)

// The strip holds six labels in a 238px cluster, so the active tab has to be
// scrolled into view: a tab you cannot see is a tab you cannot come back to.
const scrollActiveTabIntoView = () => {
  const el = tabStrip.value
  if (!el) return
  const active = el.querySelector<HTMLElement>('[aria-selected="true"]')
  if (!active) return
  const left = active.offsetLeft
  const right = left + active.offsetWidth
  if (left < el.scrollLeft) el.scrollLeft = left
  else if (right > el.scrollLeft + el.clientWidth) el.scrollLeft = right - el.clientWidth
}

const measureStrip = () => {
  const el = tabStrip.value
  if (!el) return
  stripOverflows.value = el.scrollWidth > el.clientWidth + 1
}

const scrollStrip = (direction: -1 | 1) => {
  const el = tabStrip.value
  if (!el) return
  el.scrollBy({ left: direction * 120, behavior: 'smooth' })
}

const syncScroll = () => {
  scrollActiveTabIntoView()
  measureStrip()
}

defineExpose({ syncScroll })
</script>
<template>
    <!-- ── Sub-tab strip ───────────────────────────────────────────────────
         One row: a scrollable tab cluster and a fixed action cluster. The
         counts moved out of the labels and into pills, which is what makes
         five tabs fit at the 200px minimum — "Pull request (43)" is 148px,
         "PR" plus a pill is 46px. -->
    <div
      class="relative flex items-center gap-2 px-2 h-9 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
      role="tablist"
    >
      <div ref="tabStrip" class="flex items-center gap-1 flex-1 min-w-0 h-full overflow-x-auto">
        <button
          v-if="isPrMode"
          type="button"
          class="shrink-0 h-8 px-2.5 rounded flex items-center gap-1.5 text-dense transition-colors duration-150"
          data-testid="sidebar-tab-conversation"
          role="tab"
          :aria-selected="activeTab === 'conversation'"
          :style="
            activeTab === 'conversation'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('conversation')"
        >
          Conversation
          <span
            v-if="conversationCount > 0"
            class="px-1.5 rounded-full text-micro font-semibold"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            >{{ conversationCount }}</span
          >
        </button>
        <button
          type="button"
          class="shrink-0 h-8 px-2.5 rounded flex items-center gap-1.5 text-dense transition-colors duration-150"
          data-testid="sidebar-tab-files"
          role="tab"
          :aria-selected="activeTab === 'files'"
          :style="
            activeTab === 'files'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('files')"
        >
          Local
          <span
            v-if="changeCount > 0"
            class="px-1.5 rounded-full text-micro font-semibold"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            >{{ changeCount }}</span
          >
        </button>
        <button
          v-if="isPrMode"
          type="button"
          class="shrink-0 h-8 px-2.5 rounded flex items-center gap-1.5 text-dense transition-colors duration-150"
          data-testid="sidebar-tab-pr"
          role="tab"
          :aria-selected="activeTab === 'pr'"
          :style="
            activeTab === 'pr'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('pr')"
        >
          {{ forgeShort }}
          <span
            v-if="prCount > 0"
            class="px-1.5 rounded-full text-micro font-semibold"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            >{{ prCount }}</span
          >
        </button>
        <button
          type="button"
          class="shrink-0 h-8 px-2.5 rounded text-dense transition-colors duration-150"
          data-testid="sidebar-tab-commits"
          role="tab"
          :aria-selected="activeTab === 'commits'"
          :style="
            activeTab === 'commits'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('commits')"
        >
          Commits
        </button>
        <button
          type="button"
          class="shrink-0 h-8 px-2.5 rounded text-dense transition-colors duration-150"
          data-testid="sidebar-tab-checks"
          role="tab"
          :aria-selected="activeTab === 'checks'"
          :style="
            activeTab === 'checks'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('checks')"
        >
          Checks
        </button>
        <button
          type="button"
          class="shrink-0 h-8 px-2.5 rounded text-dense transition-colors duration-150"
          data-testid="sidebar-tab-evals"
          role="tab"
          :aria-selected="activeTab === 'evals'"
          :style="
            activeTab === 'evals'
              ? {
                  color: 'var(--semantic-text)',
                  fontWeight: 600,
                  boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
                }
              : { color: 'var(--semantic-text)', opacity: '0.6' }
          "
          @click="setActiveTab('evals')"
        >
          Evals
        </button>
      </div>
      <div class="flex items-center gap-0.5 shrink-0">
        <slot name="actions" />
      </div>
      <!-- The strip is narrower than its labels. The chevrons float over the
           cluster's edge, so they cost no width of their own. -->
      <div
        v-if="stripOverflows"
        class="absolute right-11 top-0 h-9 flex items-center gap-0.5 pl-1"
        style="background-color: var(--color-bg)"
        data-testid="sidebar-tab-scroll"
      >
        <button
          type="button"
          class="w-5 h-5 rounded flex items-center justify-center text-dense"
          style="color: var(--semantic-text-dim)"
          title="Scroll the tabs left"
          data-testid="sidebar-tab-scroll-left"
          @click="scrollStrip(-1)"
        >
          ‹
        </button>
        <button
          type="button"
          class="w-5 h-5 rounded flex items-center justify-center text-dense"
          style="color: var(--semantic-text-dim)"
          title="Scroll the tabs right"
          data-testid="sidebar-tab-scroll-right"
          @click="scrollStrip(1)"
        >
          ›
        </button>
      </div>
    </div>
</template>
