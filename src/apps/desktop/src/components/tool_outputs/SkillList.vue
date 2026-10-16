<!--
  SkillList — the list half of the Skills settings panel.

  One list, from `GET /workspaces/:id/skills`: the Global / Local split and
  the per-row path both belonged to the two-directory layout and are gone.
  Load failure travels in the Effect's error channel and renders in its own
  block, so a backend outage is never read as "this workspace has no
  skills".

  Finding one skill used to mean reading 41 descriptions. The search box,
  the two facet chips and the sort menu narrow that to a keystroke, and
  the count beside the box says how many rows are left. All three live in
  the URL (`?q=`, `?facet=`, `?sort=`) so a filtered view survives a
  refresh and can be shared — the same rule the kanban board applies to
  `?sorts=` and `?layout=`.

  The auto-improve checkbox moved off every row. It was 41 checkboxes for
  one flag, each a PATCH on click, and it was the loudest thing on screen.
  It now appears on the row you are pointing at and in the detail pane,
  which is where a decision about one skill belongs.
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import UiIcon from '../ui/UiIcon.vue'
import ListSkeleton from '../shell/ListSkeleton.vue'
import SkillAutoImproveToggle from '../ui/SkillAutoImproveToggle.vue'
import { Effect } from 'effect'
import { getSkills, type Skill } from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'
import {
  countVisible,
  decodeSkillFilter,
  EMPTY_FILTER_STATE,
  encodeSkillFilter,
  isFilterActive,
  selectVisibleSkills,
  type SkillFacet,
  type SkillFilterState,
  type SkillSort,
} from '../../helpers/skillFilter'

const props = defineProps<{
  selectedSkillName: string | null
  /**    * Explicit workspace binding. When set, the list reads this workspace's skills instead of the
   * active workspace's — the workspace settings page binds the route workspace, which may differ
   * from the active one. Absent = previous behaviour (active workspace). */
  workspaceId?: string | null
}>()

// The RESOLVED workspace, not the raw `activeWorkspaceId` ref (see
// DocumentsView.vue). An explicit prop wins over the store so a page can
// show a non-active workspace without switching context.
const workspacesStore = useWorkspacesStore()
const workspaceId = computed(() => props.workspaceId ?? workspacesStore.activeWorkspace?.id ?? null)

const skills = ref<Skill[]>([])
const isLoading = ref(true)
const error = ref<string | null>(null)

const emit = defineEmits<{
  selectSkill: [skillName: string]
  error: [message: string]
}>()

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const loadSkills = async () => {
  const ws = workspaceId.value
  if (!ws) {
    skills.value = []
    error.value = null
    isLoading.value = false
    return
  }

  isLoading.value = true
  error.value = null

  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => getSkills(ws),
      catch: (e) => new SyncRemoteError({ op: 'skills.settings.load', reason: fail(e) }),
    }),
    'skills.settings.load',
  )

  isLoading.value = false
  if (result.ok) {
    skills.value = Array.isArray(result.value?.skills) ? result.value.skills : []
  } else {
    skills.value = []
    error.value = result.reason
  }
}

const reportError = (message: string) => {
  emit('error', message)
}

// Reload when the resolved workspace changes: mount covers the initial
// load, prev-id guard on update covers workspace switches. The
// data-workspace binding below keeps this component's own render effect
// subscribed to the store workspace (row content alone would not
// re-render us on a switch) — that render is what fires the guard.
const prevWorkspaceId = ref<string | null>(workspaceId.value)
onMounted(() => {
  prevWorkspaceId.value = workspaceId.value
  void loadSkills()
})
onUpdated(() => {
  if (workspaceId.value !== prevWorkspaceId.value) {
    prevWorkspaceId.value = workspaceId.value
    void loadSkills()
  }
})

// ─── Filter, sort, count ────────────────────────────────────────────────
//
// The state is seeded from the URL and written back on every change, so a
// filtered view is a link. `router.replace`, not `push`: typing in the
// search box must not bury the previous five keystrokes under Back.
const route = useRoute()
const router = useRouter()

// `route?.query` rather than `route.query`: a unit test that mounts this
// component without a router leaves `route` undefined, and the read must
// degrade to "no filter" rather than throw during setup.
const filterState = ref<SkillFilterState>(
  decodeSkillFilter((route?.query as Record<string, unknown> | undefined) ?? {}),
)

/** Every other query param on this page, so a write never drops `section`. */
function flatQuery(): Record<string, string> {
  const out: Record<string, string> = {}
  const src = (route?.query as Record<string, unknown> | undefined) ?? {}
  for (const [k, v] of Object.entries(src)) {
    if (typeof v === 'string') out[k] = v
    else if (Array.isArray(v)) {
      const first = v.find((x): x is string => typeof x === 'string')
      if (first !== undefined) out[k] = first
    }
  }
  return out
}

function writeFilterToUrl(): void {
  const query = flatQuery()
  const encoded = encodeSkillFilter(filterState.value)
  for (const key of ['q', 'facet', 'sort'] as const) {
    if (encoded[key] !== undefined) query[key] = encoded[key]
    else delete query[key]
  }
  // replace, not push: typing in the search box must not bury the previous
  // five keystrokes under Back.
  router?.replace({ path: route?.path ?? '', query })
}

const visibleSkills = computed(() => selectVisibleSkills(skills.value, filterState.value))
const visibleCount = computed(() => countVisible(skills.value, filterState.value))
const filterActive = computed(() => isFilterActive(filterState.value))

// ─── Keyboard navigation ───────────────────────────────────────────────
//
// The rows were plain click targets, so the list was unreachable without
// a mouse. Arrow keys move a cursor, Enter opens it, and `/` focuses the
// search box from anywhere on the page.
const cursorIndex = ref(-1)
const searchInputRef = ref<HTMLInputElement | null>(null)

const focusSearch = () => {
  searchInputRef.value?.focus()
  searchInputRef.value?.select()
}

const onQueryInput = (event: Event) => {
  filterState.value = { ...filterState.value, query: (event.target as HTMLInputElement).value }
  writeFilterToUrl()
  cursorIndex.value = -1
}

const clearQuery = () => {
  filterState.value = { ...filterState.value, query: '' }
  writeFilterToUrl()
  cursorIndex.value = -1
}

const onQueryKeyDown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    event.preventDefault()
    clearQuery()
  }
}

const toggleFacet = (facet: SkillFacet) => {
  const has = filterState.value.facets.includes(facet)
  const facets = has
    ? filterState.value.facets.filter((f) => f !== facet)
    : [...filterState.value.facets, facet]
  filterState.value = { ...filterState.value, facets }
  writeFilterToUrl()
  // The cursor indexes the OLD list; keeping it would make Enter open a
  // different skill than the one the reader is looking at.
  cursorIndex.value = -1
}

const setSort = (sort: SkillSort) => {
  filterState.value = { ...filterState.value, sort }
  writeFilterToUrl()
  cursorIndex.value = -1
}

const clearFilters = () => {
  filterState.value = { ...EMPTY_FILTER_STATE }
  writeFilterToUrl()
  cursorIndex.value = -1
}

const onListKeyDown = (event: KeyboardEvent) => {
  const rows = visibleSkills.value
  if (rows.length === 0) return
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault()
    const step = event.key === 'ArrowDown' ? 1 : -1
    const next = cursorIndex.value + step
    // Clamp rather than wrap: with 41 rows, wrapping from the bottom to
    // the top loses the reader's place entirely.
    cursorIndex.value = Math.max(0, Math.min(rows.length - 1, next))
    return
  }
  if (event.key === 'Enter') {
    const row = rows[cursorIndex.value]
    if (row) {
      event.preventDefault()
      emit('selectSkill', row.name)
    }
    return
  }
  if (event.key === 'Home') {
    event.preventDefault()
    cursorIndex.value = 0
    return
  }
  if (event.key === 'End') {
    event.preventDefault()
    cursorIndex.value = rows.length - 1
  }
}

const openSkillDetail = (skill: Skill) => {
  emit('selectSkill', skill.name)
}

defineExpose({
  refresh: loadSkills,
  focusSearch,
})
</script>

<template>
  <div class="skill-list" :data-workspace="workspaceId ?? ''">
    <!-- Search + facets. Hidden while loading and on error, because a
         search box over a skeleton or a failure message invites typing
         into something that cannot answer. -->
    <template v-if="!isLoading && !error && skills.length > 0">
      <div class="relative flex items-center mb-2">
        <UiIcon
          name="search"
          class="absolute left-2 w-3.5 h-3.5 pointer-events-none"
          style="color: var(--semantic-text-dim)"
        />
        <input
          ref="searchInputRef"
          :value="filterState.query"
          @input="onQueryInput"
          @keydown="onQueryKeyDown"
          type="text"
          placeholder="Search skills…"
          aria-label="Search skills by name or description"
          class="w-full pl-7 pr-7 py-1 rounded text-dense outline-none focus:ring-1"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          data-testid="skill-search-input"
        />
        <button
          v-if="filterState.query"
          type="button"
          @click="clearQuery"
          class="absolute right-1 w-5 h-5 flex items-center justify-center rounded hover:opacity-80"
          style="color: var(--semantic-text-dim)"
          aria-label="Clear search"
          data-testid="skill-search-clear"
        >
          <span aria-hidden="true">✕</span>
        </button>
      </div>

      <!-- Facets + count. One row, because three separate rows of controls
           above a 41-item list is more chrome than content. -->
      <div class="flex items-center gap-2 flex-wrap mb-2">
        <button
          type="button"
          :aria-pressed="filterState.facets.includes('auto_improve')"
          class="px-2 py-0.5 rounded-full text-dense border transition-colors"
          :style="
            filterState.facets.includes('auto_improve')
              ? 'background-color: var(--color-violet); border-color: var(--color-violet); color: var(--color-bg);'
              : 'background-color: transparent; border-color: var(--color-border); color: var(--semantic-text-muted);'
          "
          @click="toggleFacet('auto_improve')"
          data-testid="skill-facet-auto-improve"
        >
          Editable
        </button>
        <button
          type="button"
          :aria-pressed="filterState.facets.includes('pinned')"
          class="px-2 py-0.5 rounded-full text-dense border transition-colors"
          :style="
            filterState.facets.includes('pinned')
              ? 'background-color: var(--color-yellow); border-color: var(--color-yellow); color: var(--color-bg);'
              : 'background-color: transparent; border-color: var(--color-border); color: var(--semantic-text-muted);'
          "
          @click="toggleFacet('pinned')"
          data-testid="skill-facet-pinned"
        >
          Pinned
        </button>

        <span
          class="text-dense ml-auto"
          style="color: var(--semantic-text-dim)"
          data-testid="skill-count"
        >
          {{ visibleCount }} of {{ skills.length }}
        </span>
      </div>

      <div class="flex items-center gap-2 mb-3">
        <label class="text-dense" for="skill-sort" style="color: var(--semantic-text-dim)"
          >Sort</label
        >
        <select
          id="skill-sort"
          :value="filterState.sort"
          @change="setSort(($event.target as HTMLSelectElement).value as SkillSort)"
          class="px-2 py-1 rounded text-dense outline-none focus:ring-1"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          data-testid="skill-sort-select"
        >
          <option value="name">Name</option>
          <option value="updated">Recently updated</option>
          <option value="auto_improve">Editable first</option>
        </select>
        <button
          v-if="filterActive"
          type="button"
          class="text-dense ml-auto hover:opacity-80"
          style="color: var(--semantic-text-dim)"
          @click="clearFilters"
          data-testid="skill-clear-filters"
        >
          Clear filters
        </button>
      </div>
    </template>

    <!-- Loading State — skeleton holds the card list's height instead of
         collapsing the panel to one centered row. -->
    <ListSkeleton v-if="isLoading" :rows="5" row-height="h-16" test-id="skill-list-skeleton" />

    <!-- Error State -->
    <div v-else-if="error" class="text-center py-8" data-testid="skill-list-error">
      <p class="text-body" style="color: var(--color-red)">{{ error }}</p>
      <button
        @click="loadSkills"
        class="mt-3 px-4 py-2 rounded-lg text-body transition-colors duration-200"
        style="
          background-color: var(--semantic-card-bg);
          color: var(--semantic-text-muted);
          border: 1px solid var(--color-border);
        "
      >
        Retry
      </button>
    </div>

    <!-- Empty State -->
    <div v-else-if="skills.length === 0" class="text-center py-8" data-testid="skill-list-empty">
      <p class="text-body" style="color: var(--semantic-text-muted)">No skills available</p>
    </div>

    <!-- No match for the current filter. Distinct from the empty state:
         one means "this workspace has no skills", the other means "your
         search found none", and only the second offers a way out. -->
    <div
      v-else-if="visibleSkills.length === 0"
      class="text-center py-8"
      data-testid="skill-list-no-match"
    >
      <p class="text-body" style="color: var(--semantic-text-muted)">No skills match your search</p>
      <button
        @click="clearFilters"
        class="mt-3 px-4 py-2 rounded-lg text-body transition-colors duration-200"
        style="
          background-color: var(--semantic-card-bg);
          color: var(--semantic-text-muted);
          border: 1px solid var(--color-border);
        "
        data-testid="skill-list-no-match-clear"
      >
        Clear filters
      </button>
    </div>

    <!-- Skills List -->
    <div
      v-else
      class="space-y-2"
      role="listbox"
      aria-label="Skills"
      tabindex="0"
      @keydown="onListKeyDown"
      data-testid="skill-list"
    >
      <div
        v-for="(skill, index) in visibleSkills"
        :key="skill.name"
        class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90 mb-2"
        :class="{ 'ring-2': props.selectedSkillName === skill.name }"
        :style="
          props.selectedSkillName === skill.name
            ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);'
            : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'
        "
        @click="openSkillDetail(skill)"
        @mouseenter="cursorIndex = index"
        :data-skill-name="skill.name"
        :data-cursor="cursorIndex === index ? 'true' : undefined"
        role="option"
        :aria-selected="props.selectedSkillName === skill.name"
      >
        <div class="flex items-start gap-3">
          <UiIcon name="brain" class="w-5 h-5 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h3 class="text-body font-medium truncate" style="color: var(--semantic-text)">
              {{ skill.name }}
            </h3>
            <p class="text-dense mt-1 line-clamp-2" style="color: var(--semantic-text-muted)">
              {{ skill.description }}
            </p>
            <!-- The auto-improve flag, on the row you are pointing at.
                 It is a decision about one skill, so it belongs beside the
                 name rather than repeated 41 times down the list. -->
            <SkillAutoImproveToggle
              v-if="workspaceId && cursorIndex === index"
              class="mt-2"
              :workspace-id="workspaceId"
              :skill-name="skill.name"
              :checked="skill.is_can_auto_improve"
              @changed="loadSkills"
              @error="reportError"
            />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>
