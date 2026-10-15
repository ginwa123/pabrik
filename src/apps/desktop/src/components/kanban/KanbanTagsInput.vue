<!--
  KanbanTagsInput — chip input for free-form task tags.

  Visual layout:
    ┌─────────────────────────────────────────────┐
    │ [bug ✕]  [urgent ✕]  [frontend ✕]           │
    │ Add tags (letters, digits, hyphens)...      │
    └─────────────────────────────────────────────┘

  Behavior:
    - Add a tag: type in the input, press Enter OR comma
      → append chip, clear input.
    - Remove a tag: click the chip's ✕
      → remove chip, emit update.
    - Backspace on an EMPTY input: remove the LAST chip
      → emit update.
    - Duplicate prevention (case-insensitive): typing an
      existing tag is a silent no-op.
    - Char whitelist: typing a forbidden char (space, slash,
      punctuation) shows a brief error and refuses the input.
    - Length cap: tags over 50 chars are refused.
    - Color: deterministic via djb2 hash of the lowercase tag
      → 1 of 6 colors. Same tag = same color across views.

  Autocomplete dropdown (plan: 2026-07-30-kanban-task-tags-autocomplete.md):
    - When focused, the input shows a dropdown of suggestions
      drawn from the parent's pre-fetched list.
    - The dropdown filters by case-insensitive prefix on the
      draft input.
    - Suggestions already on the task (modelValue) are hidden.
    - Keyboard: ArrowDown / ArrowUp to move highlight, Enter
      to commit the highlighted suggestion, Escape to close
      the dropdown without committing.
    - Click a suggestion to commit it.
    - When parent passes `hasMore=true`, a scroll sentinel at
      the bottom of the dropdown is observed via
      IntersectionObserver; becoming visible calls `onLoadMore`.

  Public API:
    props:
      modelValue    string[]   (v-model — current tag list)
      testId?       string     (data-testid prefix for testing)
      suggestions?  string[]   (pre-fetched tag name suggestions)
      hasMore?      boolean    (server has more pages)
      loadingMore?  boolean    (next-page fetch in flight)
      onLoadMore?   () => void (fired when scroll sentinel visible)
    emits:
      update:modelValue [tags: string[]]
-->
<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount, onUpdated } from 'vue'

const props = withDefaults(
  defineProps<{
    modelValue: string[]
    testId?: string
    suggestions?: string[]
    hasMore?: boolean
    loadingMore?: boolean
    onLoadMore?: () => void
  }>(),
  {
    testId: 'kanban-tags-input',
    suggestions: () => [],
    hasMore: false,
    loadingMore: false,
    onLoadMore: undefined,
  },
)

const emit = defineEmits<{
  'update:modelValue': [tags: string[]]
}>()

// What the user is typing. Local state — we don't v-model the inner
// input itself (chip add/remove is a discrete event).
const draftInput = ref<string>('')
// Transient error message (char whitelist / length cap / duplicate).
const errorMessage = ref<string | null>(null)

// Autocomplete dropdown state.
const isFocused = ref(false)
const highlightedIndex = ref<number>(-1)

// Allowed chars: a-z, A-Z, 0-9, underscore, hyphen. Matches the
// backend's tags_validation.zig whitelist.
const TAG_CHAR_WHITELIST = /^[a-zA-Z0-9_-]$/
const TAG_LENGTH_CAP = 50

// 6-color palette indexed by deterministic djb2 hash of the
// lowercase tag. Same algorithm as WorkspaceItemTaskCard so the
// dialog chips and card chips share colors.
const TAG_PALETTE = [
  { bg: 'rgba(139, 92, 246, 0.18)', border: 'rgba(139, 92, 246, 0.45)', text: '#a78bfa' },
  { bg: 'rgba(59, 130, 246, 0.18)', border: 'rgba(59, 130, 246, 0.45)', text: '#60a5fa' },
  { bg: 'rgba(34, 197, 94, 0.18)', border: 'rgba(34, 197, 94, 0.45)', text: '#4ade80' },
  { bg: 'rgba(245, 158, 11, 0.18)', border: 'rgba(245, 158, 11, 0.45)', text: '#fbbf24' },
  { bg: 'rgba(249, 115, 22, 0.18)', border: 'rgba(249, 115, 22, 0.45)', text: '#fb923c' },
  { bg: 'rgba(239, 68, 68, 0.18)', border: 'rgba(239, 68, 68, 0.45)', text: '#f87171' },
] as const

function tagColor(tag: string): { bg: string; border: string; text: string } {
  let hash = 5381
  for (const c of tag.toLowerCase()) {
    hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
  }
  // The `% TAG_PALETTE.length` keeps the index in range; the explicit fallback guards against the
  // empty-palette case (which never happens because PALETTE is a const array, but TS's strict mode
  // flags the indexed access as `T | undefined`).
  const idx = hash % TAG_PALETTE.length
  return TAG_PALETTE[idx] ?? TAG_PALETTE[0]
}

function tagChipStyle(tag: string): Record<string, string> {
  const c = tagColor(tag)
  return {
    backgroundColor: c.bg,
    border: `1px solid ${c.border}`,
    color: c.text,
  }
}

// Sanitize the draft: strip leading/trailing whitespace. Returns
// the cleaned string (NOT mutate draftInput).
function cleanDraft(): string {
  return draftInput.value.replace(/^\s+|\s+$/g, '')
}

// Validate a tag string against the project's rules. Returns null
// when valid, or a short error string otherwise.
function validateTag(raw: string): string | null {
  const tag = raw.trim()
  if (tag.length === 0) return 'Tag cannot be empty.'
  if (tag.length > TAG_LENGTH_CAP) {
    return `Tag too long (max ${TAG_LENGTH_CAP} characters).`
  }
  for (const c of tag) {
    if (!TAG_CHAR_WHITELIST.test(c)) {
      return 'Only letters, digits, underscores, and hyphens allowed.'
    }
  }
  return null
}

function clearDraftError(): void {
  if (errorMessage.value !== null) errorMessage.value = null
}

function commitDraft(): void {
  clearDraftError()
  const tag = cleanDraft()
  if (!tag) {
    draftInput.value = ''
    return
  }
  const err = validateTag(tag)
  if (err) {
    errorMessage.value = err
    return
  }
  // Case-insensitive duplicate check.
  const tagLower = tag.toLowerCase()
  if (props.modelValue.some((t) => t.toLowerCase() === tagLower)) {
    // Silent no-op — duplicates are common UX for chip inputs.
    draftInput.value = ''
    return
  }
  emit('update:modelValue', [...props.modelValue, tag])
  draftInput.value = ''
}

function removeTag(idx: number): void {
  clearDraftError()
  const next = props.modelValue.slice()
  next.splice(idx, 1)
  emit('update:modelValue', next)
}

function onInput(): void {
  // Live-clear the error as the user types (re-enables the Submit
  // affordance without forcing them to dismiss the message).
  if (errorMessage.value !== null) clearDraftError()
}

// Autocomplete dropdown — filtered suggestions exposed to the
// template. Filters by the trimmed lowercase draft prefix (case
// insensitive) and excludes tags already on the task.
const filteredSuggestions = computed<string[]>(() => {
  if (!isFocused.value) return []
  const draft = draftInput.value.trim().toLowerCase()
  const filtered = props.suggestions.filter((s) => {
    if (!draft) return true
    return s.toLowerCase().startsWith(draft)
  })
  const modelLower = new Set(props.modelValue.map((t) => t.toLowerCase()))
  return filtered.filter((s) => !modelLower.has(s.toLowerCase()))
})

// The dropdown stays open as long as the input is focused AND the
// parent has provided at least one suggestion to filter from. The
// `filteredSuggestions` computed drives what shows inside the
// dropdown; this `showDropdown` only controls the wrapper
// visibility so an unmatched draft (e.g. "partial" with no
// "partial*" suggestions) keeps the dropdown open — the user
// can backspace to reveal matches, and Escape closes it without
// committing the draft.
const showDropdown = computed<boolean>(() => isFocused.value && props.suggestions.length > 0)

function onFocus(): void {
  isFocused.value = true
  highlightedIndex.value = -1
}

function onBlur(): void {
  // Delay closing so click events on dropdown items can fire first.
  // 150ms is the value in the plan; long enough to outlast a mousedown
  // event on a suggestion but short enough to feel snappy.
  setTimeout(() => {
    isFocused.value = false
    highlightedIndex.value = -1
  }, 150)
  commitDraft()
}

function commitSuggestion(suggestion: string): void {
  emit('update:modelValue', [...props.modelValue, suggestion])
  draftInput.value = ''
  highlightedIndex.value = -1
  // KEEP the dropdown open so the user can pick multiple tags without re-focusing the input.
  // Pre-fix, this line set `isFocused.value = false`, which collapsed the dropdown after every pick
  // — user feedback 2026-08-06: "after enter select dropdown, the dropdown not show up agai, it
  // should show up".
  // The suggestion's @mousedown.prevent stops the input from blurring, so isFocused stays true
  // naturally; the suggestion's row is filtered out of `filteredSuggestions` because the new tag is
  // now in modelValue, leaving the remaining picks visible.
}

function moveHighlight(direction: 1 | -1): void {
  const max = filteredSuggestions.value.length - 1
  if (max < 0) return
  if (highlightedIndex.value === -1) {
    highlightedIndex.value = direction === 1 ? 0 : max
  } else {
    const next = highlightedIndex.value + direction
    highlightedIndex.value = Math.max(0, Math.min(max, next))
  }
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Enter' || event.key === ',') {
    event.preventDefault()
    const hi = highlightedIndex.value
    const sugg = hi >= 0 ? filteredSuggestions.value[hi] : undefined
    if (hi >= 0 && sugg) {
      commitSuggestion(sugg)
    } else {
      commitDraft()
    }
  } else if (
    event.key === 'Backspace' &&
    draftInput.value.length === 0 &&
    props.modelValue.length > 0
  ) {
    removeTag(props.modelValue.length - 1)
  } else if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveHighlight(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveHighlight(-1)
  } else if (event.key === 'Escape') {
    if (showDropdown.value) {
      event.preventDefault()
      isFocused.value = false
      highlightedIndex.value = -1
    }
  }
}

// Whether the input shows an error style (red border). Drives the
// `aria-invalid` attr and the red border class.
const hasError = computed(() => errorMessage.value !== null)

// IntersectionObserver lifecycle — lazily load the next page of suggestions when the scroll
// sentinel at the bottom of the dropdown becomes visible. The sentinel is rendered only when
// `hasMore` is true, so the observer is attached/detached as the dropdown opens/closes.
const scrollSentinel = ref<HTMLLIElement | null>(null)
let observer: IntersectionObserver | null = null

function attachObserver(): void {
  if (!scrollSentinel.value || observer) return
  // Lazy-load the next page when the sentinel scrolls into view. `rootMargin: 0px 0px 100px 0px`
  // triggers ~100px BEFORE the sentinel reaches the bottom of the visible area, so the next page
  // arrives by the time the user hits the very bottom.
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          props.onLoadMore?.()
        }
      }
    },
    { rootMargin: '0px 0px 100px 0px' },
  )
  observer.observe(scrollSentinel.value)
}

function detachObserver(): void {
  if (observer) {
    observer.disconnect()
    observer = null
  }
}

// The sentinel mounts/unmounts with the dropdown (v-if on hasMore, and the dropdown itself
// opens/closes), so re-attach whenever the ref element changes: mount covers the initial render,
// prev-element guard on update covers focus-open and hasMore flips.
let prevSentinel: HTMLLIElement | null = null
onMounted(() => {
  prevSentinel = scrollSentinel.value
  attachObserver()
})
onUpdated(() => {
  if (scrollSentinel.value !== prevSentinel) {
    prevSentinel = scrollSentinel.value
    detachObserver()
    attachObserver()
  }
})

onBeforeUnmount(() => {
  detachObserver()
})

// Expose commitDraft so the host (KanbanTaskDetailDialog) can call it imperatively right before
// reading the modelValue.
// Without this, a draft tag typed just before Save (no Enter/comma pressed) is silently dropped —
// `commitDraft` is only triggered by Enter/comma (and `@blur` since the auto-commit addition
// below).
defineExpose({ commitDraft })
</script>

<template>
  <div class="relative">
    <div
      class="flex flex-wrap items-center gap-1.5 px-2 py-1.5 rounded-lg"
      :class="hasError ? 'border border-red-500/60' : 'border border-[--color-border]'"
      style="background-color: var(--semantic-sidebar-bg)"
      :data-testid="`${props.testId}-container`"
    >
      <span
        v-for="(tag, idx) in props.modelValue"
        :key="`${tag}-${idx}`"
        class="inline-flex items-center gap-1 text-meta px-1.5 py-0.5 rounded font-medium"
        :style="tagChipStyle(tag)"
        :data-testid="`${props.testId}-chip-${tag}`"
      >
        {{ tag }}
        <button
          type="button"
          @click="removeTag(idx)"
          class="inline-flex items-center justify-center w-3 h-3 rounded-full hover:bg-black/20 focus:outline-none"
          :aria-label="`Remove tag ${tag}`"
          :data-testid="`${props.testId}-remove-${tag}`"
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
        v-model="draftInput"
        @keydown="onKeydown"
        @focus="onFocus"
        @blur="onBlur"
        @input="onInput"
        type="text"
        :placeholder="props.modelValue.length === 0 ? 'Add tags (letters, digits, hyphens)…' : ''"
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
          v-for="(suggestion, idx) in filteredSuggestions"
          :key="suggestion"
          class="px-3 py-1.5 cursor-pointer text-body transition-colors duration-100"
          :class="idx === highlightedIndex ? 'bg-violet-500/20' : ''"
          :style="{ color: 'var(--semantic-text)' }"
          :data-testid="`${props.testId}-suggestion-${suggestion}`"
          @mousedown.prevent="commitSuggestion(suggestion)"
          @mouseenter="highlightedIndex = idx"
        >
          {{ suggestion }}
        </li>
        <li
          v-if="props.hasMore"
          ref="scrollSentinel"
          :data-testid="`${props.testId}-suggestions-sentinel`"
          class="h-px"
        />
      </ul>
      <div
        v-if="props.loadingMore"
        class="px-3 py-1.5 text-dense text-center"
        style="color: var(--semantic-text-dim)"
        :data-testid="`${props.testId}-suggestions-loading`"
      >
        Loading more…
      </div>
    </div>
    <div
      v-if="hasError"
      class="mt-1 text-meta"
      style="color: rgb(248, 113, 113)"
      :data-testid="`${props.testId}-error`"
      role="alert"
    >
      {{ errorMessage }}
    </div>
  </div>
</template>
