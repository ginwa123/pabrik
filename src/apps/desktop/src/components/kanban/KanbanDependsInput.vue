<!--
  KanbanDependsInput — multi-select for a task's dependencies.

  Visual layout mirrors KanbanTagsInput (chips + filter input +
  dropdown) so the two pickers read as a pair:
    ┌─────────────────────────────────────────────┐
    │ [Fix login ✕]  [Add tests ✕]  (blocked: orange dot) │
    │ Search tasks…                               │
    └─────────────────────────────────────────────┘

  Behavior:
    - Pick: focus the input (or type to filter), click a row or
      press Enter → append the task id, clear the filter.
    - Remove: click the chip's ✕ → drop the id, emit update.
    - Backspace on an EMPTY input removes the LAST chip.
    - The task itself is never offered (filtered via selfTaskId).
    - Already-chosen tasks are hidden from the dropdown.
    - Chips render the task NAME (id is the value); ids with no
      known task fall back to the raw id.
    - Incomplete deps (ids in `blockedIds`) get an orange dot +
      "Not completed" title so the blocker set is visible.

  Public API:
    props:
      modelValue    string[]   (v-model — chosen dependency ids)
      tasks         {id,name}[] (candidate tasks of the same board)
      selfTaskId?   string     (the edited task — never offered)
      blockedIds?   string[]   (incomplete dep ids, marked distinctly)
      testId?       string     (data-testid prefix for testing)
    emits:
      update:modelValue [ids: string[]]
-->
<script setup lang="ts">
import { ref, computed } from 'vue'

export interface DependsCandidate {
  id: string
  name: string
}

const props = withDefaults(
  defineProps<{
    modelValue: string[]
    tasks: DependsCandidate[]
    selfTaskId?: string
    blockedIds?: string[]
    testId?: string
  }>(),
  {
    selfTaskId: '',
    blockedIds: () => [],
    testId: 'kanban-depends-input',
  },
)

const emit = defineEmits<{
  'update:modelValue': [ids: string[]]
}>()

// Free-text filter for the dropdown. Local state — picking is a
// discrete event, same as KanbanTagsInput's draftInput.
const filter = ref('')
const isFocused = ref(false)
const highlightedIndex = ref(-1)

// Name lookup for chip labels. Unknown ids (stale edges) fall
// back to the raw id so the chip still renders + can be removed.
const nameById = computed<Record<string, string>>(() => {
  const map: Record<string, string> = {}
  for (const t of props.tasks) map[t.id] = t.name
  return map
})
const labelFor = (id: string): string => nameById.value[id] ?? id
const isBlocked = (id: string): boolean => props.blockedIds.includes(id)

// Dropdown rows: other tasks of the board, minus self and minus
// already-chosen, filtered by case-insensitive name substring.
const dropdownRows = computed<DependsCandidate[]>(() => {
  const chosen = new Set(props.modelValue)
  const q = filter.value.trim().toLowerCase()
  return props.tasks.filter((t) => {
    if (t.id === props.selfTaskId) return false
    if (chosen.has(t.id)) return false
    if (q && !t.name.toLowerCase().includes(q)) return false
    return true
  })
})

const showDropdown = computed<boolean>(() => isFocused.value && dropdownRows.value.length > 0)

function pick(id: string): void {
  if (props.modelValue.includes(id)) {
    filter.value = ''
    return
  }
  emit('update:modelValue', [...props.modelValue, id])
  filter.value = ''
  highlightedIndex.value = -1
}

function removeDep(idx: number): void {
  const next = props.modelValue.slice()
  next.splice(idx, 1)
  emit('update:modelValue', next)
}

function onFocus(): void {
  isFocused.value = true
  highlightedIndex.value = -1
}

function onBlur(): void {
  // Same 150ms delayed close as KanbanTagsInput so a row click
  // lands before the dropdown unmounts.
  setTimeout(() => {
    isFocused.value = false
    highlightedIndex.value = -1
  }, 150)
}

function moveHighlight(direction: 1 | -1): void {
  const max = dropdownRows.value.length - 1
  if (max < 0) return
  if (highlightedIndex.value === -1) {
    highlightedIndex.value = direction === 1 ? 0 : max
  } else {
    const next = highlightedIndex.value + direction
    highlightedIndex.value = Math.max(0, Math.min(max, next))
  }
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Enter') {
    event.preventDefault()
    const hi = highlightedIndex.value
    const row = hi >= 0 ? dropdownRows.value[hi] : dropdownRows.value[0]
    if (row) pick(row.id)
  } else if (
    event.key === 'Backspace' &&
    filter.value.length === 0 &&
    props.modelValue.length > 0
  ) {
    removeDep(props.modelValue.length - 1)
  } else if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveHighlight(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveHighlight(-1)
  } else if (event.key === 'Escape') {
    isFocused.value = false
    highlightedIndex.value = -1
  }
}
</script>

<template>
  <div class="relative">
    <div
      class="flex flex-wrap items-center gap-1.5 px-2 py-1.5 rounded-lg border border-(--color-border)"
      style="background-color: var(--semantic-sidebar-bg)"
      :data-testid="`${props.testId}-container`"
    >
      <span
        v-for="(depId, idx) in props.modelValue"
        :key="`${depId}-${idx}`"
        class="inline-flex items-center gap-1 text-meta px-1.5 py-0.5 rounded font-medium"
        :class="isBlocked(depId) ? 'border border-orange-500/50' : ''"
        style="background-color: rgba(245, 158, 11, 0.12); color: var(--semantic-text)"
        :title="isBlocked(depId) ? `${labelFor(depId)} — not completed` : labelFor(depId)"
        :data-testid="`${props.testId}-chip-${depId}`"
      >
        <span
          v-if="isBlocked(depId)"
          class="inline-block w-1.5 h-1.5 rounded-full shrink-0"
          style="background-color: rgb(249, 115, 22)"
          aria-hidden="true"
          :data-testid="`${props.testId}-chip-blocked-dot-${depId}`"
        />
        {{ labelFor(depId) }}
        <button
          type="button"
          @click="removeDep(idx)"
          class="inline-flex items-center justify-center w-3 h-3 rounded-full hover:bg-black/20 focus:outline-none"
          :aria-label="`Remove dependency ${labelFor(depId)}`"
          :data-testid="`${props.testId}-remove-${depId}`"
        >
          <svg class="w-2 h-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="3"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </span>
      <input
        v-model="filter"
        @keydown="onKeydown"
        @focus="onFocus"
        @blur="onBlur"
        type="text"
        :placeholder="props.modelValue.length === 0 ? 'Search tasks…' : ''"
        :data-testid="`${props.testId}-field`"
        class="flex-1 min-w-[120px] bg-transparent outline-none text-body"
        style="color: var(--semantic-text)"
      />
    </div>
    <div
      v-if="showDropdown"
      class="absolute z-50 mt-1 w-full rounded-lg shadow-lg overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      :data-testid="`${props.testId}-suggestions`"
    >
      <ul class="max-h-48 overflow-y-auto py-1">
        <li
          v-for="(row, idx) in dropdownRows"
          :key="row.id"
          class="px-3 py-1.5 cursor-pointer text-body transition-colors duration-100 flex items-center gap-2"
          :class="idx === highlightedIndex ? 'bg-violet-500/20' : ''"
          :style="{ color: 'var(--semantic-text)' }"
          :data-testid="`${props.testId}-suggestion-${row.id}`"
          @mousedown.prevent="pick(row.id)"
          @mouseenter="highlightedIndex = idx"
        >
          <span class="truncate">{{ row.name }}</span>
        </li>
      </ul>
    </div>
  </div>
</template>
