<script setup lang="ts">
/** GitBaseBranchSelect — searchable ref picker for the kanban "New task" dialog's git-worktree
 * block. Why a dedicated component: a real repo has hundreds of refs (this one has ~770), so a
 * plain <select> is unusable. */
import { computed, nextTick, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'

import { listGitBranches, type GitBranchEntry } from '@/api'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(
  defineProps<{
    modelValue: string
    /**      * Absolute path of the repo whose refs are listed. Empty = the dialog could not resolve a
     * project root; the picker then shows an empty list and relies on hand-typed input. */
    repoPath?: string
    disabled?: boolean
  }>(),
  { repoPath: '', disabled: false },
)

const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const open = ref(false)
const search = ref('')
const loading = ref(false)
const branches = ref<GitBranchEntry[]>([])
/**  * Cache key: the repo path the current `branches` were loaded for, so re-opening the same dropdown
 * does not refetch but switching project roots does. */
const loadedFor = ref<string | null>(null)
/** True once a load has completed (successfully or not) for `loadedFor`.
 *  Drives the "no branches found" message so it is not shown mid-load. */
const loadAttempted = ref(false)
const rootRef = ref<HTMLElement | null>(null)
const searchRef = ref<HTMLInputElement | null>(null)
/** Index into `filtered` for keyboard navigation (-1 = nothing active). */
const activeIndex = ref(-1)

const filtered = computed<GitBranchEntry[]>(() => {
  const q = search.value.trim().toLowerCase()
  if (q === '') return branches.value
  return branches.value.filter((b) => b.name.toLowerCase().includes(q))
})

/** Typed ref that is not (yet) in the listed branches. Offering it lets the user name a ref the
 * picker cannot see — e.g. an `origin/<branch>` that has not been fetched, or a tag. */
const customRef = computed(() => {
  const q = search.value.trim()
  if (q === '') return ''
  return branches.value.some((b) => b.name === q) ? '' : q
})

const selected = computed(() => props.modelValue.trim())

const ensureLoaded = async () => {
  const path = (props.repoPath ?? '').trim()
  if (path === '') {
    branches.value = []
    loadedFor.value = null
    loadAttempted.value = true
    return
  }
  if (loadedFor.value === path && loadAttempted.value) return
  loading.value = true
  loadAttempted.value = false
  try {
    const resp = await listGitBranches(path)
    branches.value = resp.branches ?? []
    loadedFor.value = path
    loadAttempted.value = true
  } finally {
    loading.value = false
  }
}

const toggleOpen = async () => {
  if (props.disabled) return
  open.value = !open.value
  if (!open.value) return
  search.value = ''
  activeIndex.value = -1
  void ensureLoaded()
  await nextTick()
  searchRef.value?.focus()
}

const close = () => {
  open.value = false
  search.value = ''
  activeIndex.value = -1
}

const select = (name: string) => {
  emit('update:modelValue', name)
  close()
}

/** Wrap-around cursor movement over `filtered`. */
const move = (delta: number) => {
  const n = filtered.value.length
  if (n === 0) return
  const base = activeIndex.value
  activeIndex.value = base < 0 ? (delta > 0 ? 0 : n - 1) : (base + delta + n) % n
}

const commitActive = () => {
  const idx = activeIndex.value
  const branch = idx >= 0 ? filtered.value[idx] : undefined
  if (branch) {
    select(branch.name)
    return
  }
  // Nothing highlighted: Enter on a typed-but-unlisted ref commits it.
  if (customRef.value !== '') select(customRef.value)
}

const onSearchKeydown = (event: KeyboardEvent) => {
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    move(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    move(-1)
  } else if (event.key === 'Enter') {
    event.preventDefault()
    commitActive()
  } else if (event.key === 'Escape') {
    event.preventDefault()
    close()
  }
}

/** mousedown (not click) so the close runs before any focus juggling. */
const onDocumentMouseDown = (event: MouseEvent) => {
  if (!open.value) return
  const target = event.target as Node | null
  if (rootRef.value && target && !rootRef.value.contains(target)) close()
}

onMounted(() => document.addEventListener('mousedown', onDocumentMouseDown))
onBeforeUnmount(() => document.removeEventListener('mousedown', onDocumentMouseDown))

// A new project root invalidates the cache; the next open refetches.
// Runs on update with a prev-value guard instead of a watcher.
const prevRepoPath = ref(props.repoPath)
onUpdated(() => {
  if (props.repoPath !== prevRepoPath.value) {
    prevRepoPath.value = props.repoPath
    loadedFor.value = null
    loadAttempted.value = false
    branches.value = []
  }
})
</script>

<template>
  <div ref="rootRef" class="relative" data-testid="git-base-branch-select">
    <button
      type="button"
      :disabled="disabled"
      :title="
        selected
          ? `New worktree branches from: ${selected}`
          : 'New worktree branches from the repo HEAD'
      "
      class="px-2.5 py-1 rounded-md text-dense hover:opacity-80 inline-flex items-center gap-1.5 transition-opacity duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
      :style="{
        backgroundColor: 'var(--semantic-sidebar-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      data-testid="git-base-branch-select-trigger"
      @click.stop="toggleOpen"
    >
      <UiIcon name="leaf" />
      <span class="font-medium">Base branch</span>
      <span
        class="font-mono truncate max-w-[200px] inline-block align-middle"
        style="color: var(--semantic-text-muted)"
      >
        {{ selected || 'HEAD (default)' }}
      </span>
      <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)">▾</span>
    </button>

    <div
      v-if="open"
      class="absolute top-full mt-1 left-0 w-[320px] max-w-[80vw] rounded-lg shadow-lg z-30 overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="git-base-branch-select-dropdown"
      @click.stop
    >
      <div class="p-2" style="border-bottom: 1px solid var(--color-border)">
        <input
          ref="searchRef"
          type="text"
          v-model="search"
          placeholder="Search branches…"
          class="w-full px-2 py-1 rounded-md text-dense font-mono"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          data-testid="git-base-branch-select-search"
          @keydown="onSearchKeydown"
        />
      </div>

      <div class="max-h-[260px] overflow-y-auto">
        <button
          type="button"
          class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between gap-2"
          style="color: var(--semantic-text)"
          data-testid="git-base-branch-select-clear"
          @click="select('')"
        >
          <span class="font-medium">Follow HEAD (no Base line)</span>
          <span v-if="selected === ''">✓</span>
        </button>

        <div
          v-if="loading"
          class="px-3 py-2 text-dense"
          style="color: var(--semantic-text-muted)"
          data-testid="git-base-branch-select-loading"
        >
          Loading branches…
        </div>

        <template v-else>
          <button
            v-if="customRef !== ''"
            type="button"
            class="w-full text-left px-3 py-2 text-dense font-mono hover:opacity-80 flex items-center gap-2"
            style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
            data-testid="git-base-branch-select-custom"
            @click="select(customRef)"
          >
            <span class="truncate">Use "{{ customRef }}"</span>
          </button>

          <button
            v-for="(branch, idx) in filtered"
            :key="branch.name"
            type="button"
            class="w-full text-left px-3 py-1.5 text-dense font-mono hover:opacity-80 flex items-center justify-between gap-2"
            :style="{
              color: 'var(--semantic-text)',
              borderTop: '1px solid var(--color-border)',
              backgroundColor: idx === activeIndex ? 'var(--semantic-sidebar-bg)' : 'transparent',
            }"
            data-testid="git-base-branch-select-item"
            @click="select(branch.name)"
          >
            <span class="truncate">
              {{ branch.name }}
              <span v-if="branch.is_default" style="color: var(--semantic-text-dim)"
                >· default</span
              >
              <span v-else-if="branch.is_current" style="color: var(--semantic-text-dim)"
                >· current</span
              >
            </span>
            <span v-if="selected === branch.name">✓</span>
          </button>

          <div
            v-if="filtered.length === 0"
            class="px-3 py-2 text-dense"
            style="color: var(--semantic-text-muted)"
            data-testid="git-base-branch-select-empty"
          >
            {{
              branches.length === 0
                ? 'No branches listed (no project root, or the path is not a git repo). Type a ref to use it anyway.'
                : 'No branch matches that search. Type a ref to use it anyway.'
            }}
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
