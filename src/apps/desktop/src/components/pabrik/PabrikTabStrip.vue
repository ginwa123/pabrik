<script setup lang="ts">
import { computed, onMounted, onUpdated } from 'vue'
import { useRoute } from 'vue-router'

const STORAGE_KEY = 'pabrik-settings-active-tab'

type TabId = 'general' | 'profiles' | 'mcp' | 'tools' | 'evals'

const props = defineProps<{
  modelValue: TabId
  /**
   * Restrict the strip to these sections. Omitted (or empty) = all five, which
   * is what the user-scope page wants; the workspace scope passes the four
   * that moved there.
   */
  sections?: readonly TabId[]
}>()

const emit = defineEmits<{
  'update:modelValue': [value: TabId]
}>()

// Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
// 'general' tab is the FIRST tab — operational settings (notification
// toggles + retry delay) sit before profiles so the user lands on
// the most-frequently-touched settings first. Plan 2026-08-24-
// config-simplify-remove-defaults: the 'defaults' tab was removed
// (top-level LLM defaults no longer persist). Plan
// 2026-09-04-subagents-per-profile: the 'sub-agents' tab was removed
// (no global list — each profile owns its sub-agents, edited inline
// in the Profiles tab via expand chevron).
const tabs: ReadonlyArray<{ id: TabId; label: string }> = [
  { id: 'general', label: 'General' },
  { id: 'profiles', label: 'Profiles' },
  { id: 'mcp', label: 'MCP Servers' },
  { id: 'tools', label: 'Tools' },
  { id: 'evals', label: 'Skill Evals' },
] as const

/**
 * The tabs actually offered. A section the caller did not ask for is not
 * rendered AND cannot be restored from storage below - otherwise a workspace
 * page would silently jump to a tab it does not have.
 */
const visibleTabs = computed(() =>
  props.sections && props.sections.length > 0
    ? tabs.filter((t) => props.sections?.includes(t.id))
    : tabs,
)

// Undefined when mounted without a router (unit tests). The restore
// emit below must never run under a real router that already carries
// a `?section=` deep link — it would clobber the linked tab with the
// localStorage value on mount. The parent (PabrikConfigEditor) reads
// `?section=` first, then falls back to localStorage itself.
const route = useRoute()

onMounted(() => {
  const raw = route?.query?.section
  const section = Array.isArray(raw) ? raw[0] : raw
  if (typeof section === 'string' && visibleTabs.value.some((t) => t.id === section)) return
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved && visibleTabs.value.some((t) => t.id === saved) && saved !== props.modelValue) {
    emit('update:modelValue', saved as TabId)
  }
})

// Persist the active tab alongside the emit so refresh restores it (the
// parent also strips the default tab from the URL — storage is the
// fallback the URL-backed computed reads).
function persistTab(id: TabId) {
  try {
    localStorage.setItem(STORAGE_KEY, id)
  } catch {
    /* quota / private mode */
  }
}
function selectTab(id: TabId) {
  persistTab(id)
  emit('update:modelValue', id)
}

// The strip is controlled: the parent applies v-model after the click, so
// a parent-driven prop change persists too (prev-value guard on update).
// The click handler above already wrote the same value — same write twice,
// not two writes.
let prevTabValue = props.modelValue
onUpdated(() => {
  if (props.modelValue === prevTabValue) return
  prevTabValue = props.modelValue
  persistTab(props.modelValue)
})
</script>

<template>
  <div
    role="tablist"
    aria-label="Pabrik settings sections"
    class="flex items-center gap-1 border-b"
    style="border-color: var(--color-border)"
  >
    <button
      v-for="tab in visibleTabs"
      :key="tab.id"
      role="tab"
      type="button"
      :aria-selected="modelValue === tab.id"
      :data-tab-id="tab.id"
      :data-active="modelValue === tab.id ? 'true' : 'false'"
      @click="selectTab(tab.id)"
      class="relative px-4 h-10 text-body font-medium transition-colors duration-150"
      :style="{
        color: modelValue === tab.id ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">{{ tab.label }}</span>
      <span
        v-if="modelValue === tab.id"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet)"
        aria-hidden="true"
      />
    </button>
  </div>
</template>
