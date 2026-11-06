<script setup lang="ts">
import { computed } from 'vue'
import { useTabsStore } from '../../stores/tabs'
import { useInjectTabStripActions } from '../../composables/useTabStrip'
import { useTabMarks } from '../../composables/useTabMarks'
import { isDiffQuery } from '../../helpers/tabTarget'

const props = withDefaults(
  defineProps<{
    owner: string
    title: string
    showSidebarToggle?: boolean
  }>(),
  { showSidebarToggle: true },
)

const emit = defineEmits<{
  'toggle-sidebar': []
  close: []
}>()

const tabsStore = useTabsStore()
const actions = useInjectTabStripActions()

const row = computed(() => tabsStore.stripOf(props.owner))
const activeId = computed(() => tabsStore.activeTabId)
const activeTab = computed(() => row.value.find((tab) => tab.id === activeId.value) ?? null)

// `+N −M` per file tab, and the square when those numbers moved while you were elsewhere.
const { markOfTab, refresh: refreshMarks } = useTabMarks({
  tabs: () => row.value,
  activeId: () => activeId.value,
  enabled: () => props.owner !== '',
})
const marks = computed(() => new Map(row.value.map((tab) => [tab.id, markOfTab(tab)])))

/** The active tab shows a file, and a file has changes worth a click. */
const canOpenDiff = computed(() => {
  const tab = activeTab.value
  if (!tab || tab.pinned) return false
  if (isDiffQuery(tab.query)) return false
  const file = tab.query.file ?? ''
  return file !== '' && (tab.query.cwd ?? '') !== ''
})

function activate(tabId: string): void {
  if (tabId === activeId.value) return
  if (actions) actions.activate(tabId)
  else tabsStore.activate(tabId)
  void refreshMarks()
}

function close(tabId: string): void {
  if (actions) actions.close(tabId)
  else tabsStore.close(tabId)
  void refreshMarks()
}

function openDiff(): void {
  if (!actions || !activeTab.value) return
  actions.openDiff(activeTab.value.id)
}
</script>

<template>
  <div
    class="session-strip shrink-0 flex items-stretch"
    role="tablist"
    :aria-label="`Tabs opened in ${title}`"
    data-testid="session-tab-strip"
    style="height: 36px; background-color: var(--semantic-sidebar-bg)"
  >
    <div class="session-strip-tabs flex items-end flex-1 min-w-0 overflow-x-auto">
      <div
        v-for="tab in row"
        :key="tab.id"
        class="session-tab flex items-center gap-2 shrink-0 max-w-[240px] min-w-[108px] flex-1 basis-[154px] h-full px-2.5 text-micro"
        :class="{ 'is-active': tab.id === activeId, 'is-pinned': tab.pinned }"
        role="tab"
        :aria-selected="tab.id === activeId"
        :tabindex="tab.id === activeId ? 0 : -1"
        :title="tab.key"
        :data-testid="`session-tab-${tab.kind}`"
        @click="activate(tab.id)"
        @auxclick.middle.prevent="close(tab.id)"
        @keydown.enter.prevent="activate(tab.id)"
        @keydown.space.prevent="activate(tab.id)"
      >
        <svg
          v-if="tab.kind === 'chat'"
          class="shrink-0"
          width="12"
          height="12"
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M2 2.6h8v5.2H5.4L3 10V7.8H2z" />
        </svg>
        <svg
          v-else-if="tab.kind === 'diff'"
          class="shrink-0"
          width="12"
          height="12"
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
          aria-hidden="true"
        >
          <path d="M1.6 3.4h8.8M1.6 8.6h8.8" />
        </svg>
        <svg
          v-else
          class="shrink-0"
          width="12"
          height="12"
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M3 1.6h4L9.4 4v6.4H3z" />
          <path d="M6.8 1.7V4h2.5" />
        </svg>

        <span class="min-w-0 flex-1 truncate">{{ tab.title }}</span>

        <span
          v-if="marks.get(tab.id)?.counts"
          class="session-tab-counts shrink-0 text-micro"
          data-testid="session-tab-counts"
        >
          <span class="session-tab-add">+{{ marks.get(tab.id)?.counts?.added }}</span>
          <span class="session-tab-del">−{{ marks.get(tab.id)?.counts?.removed }}</span>
        </span>
        <span
          v-if="marks.get(tab.id)?.unseen"
          class="session-tab-unseen shrink-0"
          aria-hidden="true"
          data-testid="session-tab-unseen"
        />

        <button
          v-if="!tab.pinned"
          type="button"
          class="session-tab-close shrink-0 w-5 h-5 flex items-center justify-center rounded"
          :aria-label="`Close ${tab.title}`"
          :data-testid="`session-tab-close-${tab.kind}`"
          @click.stop="close(tab.id)"
        >
          <svg
            width="8"
            height="8"
            viewBox="0 0 8 8"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path d="M1 1l6 6M7 1l-6 6" />
          </svg>
        </button>
      </div>
    </div>

    <div class="flex items-center shrink-0 gap-0.5 pr-2">
      <slot name="extras" />

      <button
        v-if="canOpenDiff"
        type="button"
        class="shrink-0 w-7 h-7 rounded flex items-center justify-center hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Show this file's changes as their own tab"
        aria-label="Show this file's changes"
        data-testid="session-strip-open-diff"
        @click="openDiff()"
      >
        <svg
          width="12"
          height="12"
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.3"
          stroke-linecap="round"
          aria-hidden="true"
        >
          <path d="M1.6 3.4h8.8M1.6 8.6h8.8" />
        </svg>
      </button>

      <button
        v-if="showSidebarToggle"
        type="button"
        class="shrink-0 w-7 h-7 rounded flex items-center justify-center text-body hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Toggle changes sidebar (Cmd/Ctrl+B)"
        aria-label="Toggle changes sidebar"
        data-testid="session-strip-sidebar-toggle"
        @click="emit('toggle-sidebar')"
      >
        ◫
      </button>

      <button
        type="button"
        class="shrink-0 w-7 h-7 rounded flex items-center justify-center text-title-sm hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Close chat"
        aria-label="Close chat"
        data-testid="session-strip-close-session"
        @click="emit('close')"
      >
        ✕
      </button>
    </div>
  </div>
</template>

<style scoped>
.session-strip {
  border-bottom: 1px solid var(--color-border);
}

.session-strip-tabs {
  scrollbar-width: none;
}

.session-strip-tabs::-webkit-scrollbar {
  height: 0;
}

.session-tab {
  color: var(--semantic-text-muted);
  font-weight: 500;
  white-space: nowrap;
  border-radius: 6px 6px 0 0;
  cursor: pointer;
}

.session-tab:hover {
  background-color: var(--semantic-hover-bg);
}

.session-tab.is-active {
  background-color: var(--semantic-active-bg);
  color: var(--semantic-text);
  font-weight: 600;
}

.session-tab.is-pinned {
  color: var(--semantic-text);
  font-weight: 600;
}

.session-tab-counts {
  font-variant-numeric: tabular-nums;
  font-weight: 500;
}

.session-tab-add {
  color: var(--color-green);
}

.session-tab-del {
  color: var(--color-red);
}

.session-tab-unseen {
  width: 6px;
  height: 6px;
  border-radius: 1.5px;
  background-color: var(--color-yellow);
}

.session-tab-close {
  color: inherit;
  opacity: 0.4;
}

.session-tab.is-active .session-tab-close,
.session-tab:hover .session-tab-close {
  opacity: 0.9;
}
</style>
