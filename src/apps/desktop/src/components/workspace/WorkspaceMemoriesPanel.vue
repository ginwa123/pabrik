<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Effect } from 'effect'
import EmptyState from '../pabrik/EmptyState.vue'
import WorkspaceMemoryRow from './WorkspaceMemoryRow.vue'
import WorkspaceMemoryCreateForm from './WorkspaceMemoryCreateForm.vue'
import {
  createWorkspaceMemory,
  deleteWorkspaceMemory,
  listWorkspaceMemories,
  type WorkspaceMemory,
} from '../../api'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  workspaceId: string
  itemName?: string
  showHeading?: boolean
}>()

const showHeading = computed(() => props.showHeading !== false)

const memories = ref<WorkspaceMemory[]>([])
const totalCount = ref(0)
const isLoading = ref(false)
const isLoaded = ref(false)
const error = ref<string | null>(null)

const searchInput = ref('')
const appliedQuery = ref('')

const expandedId = ref<string | null>(null)
const isCreating = ref(false)
const isSaving = ref(false)
const deletingId = ref<string | null>(null)
const formError = ref<string | null>(null)

let searchTimer: ReturnType<typeof setTimeout> | undefined

const hasWorkspace = computed(() => props.workspaceId.length > 0)
const isSearching = computed(() => appliedQuery.value.length > 0)

const countLabel = computed(() => {
  if (!isLoaded.value) return ''
  if (isSearching.value) {
    const n = memories.value.length
    return n === 1 ? '1 match' : `${n} matches`
  }
  return String(totalCount.value)
})

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const remote = <A,>(op: string, run: () => Promise<A>) =>
  runSyncResult(
    Effect.tryPromise({ try: run, catch: (e) => new SyncRemoteError({ op, reason: fail(e) }) }),
    op,
  )

async function load(): Promise<void> {
  if (!hasWorkspace.value) {
    memories.value = []
    totalCount.value = 0
    isLoaded.value = true
    return
  }
  isLoading.value = true
  error.value = null
  const result = await remote('memories.list', () =>
    listWorkspaceMemories(props.workspaceId, { query: appliedQuery.value, limit: 200 }),
  )
  isLoading.value = false
  if (!result.ok) {
    error.value = result.reason
    return
  }
  memories.value = result.value.memories ?? []
  totalCount.value = result.value.total_count ?? 0
  isLoaded.value = true
}

function onSearchInput(): void {
  if (searchTimer) clearTimeout(searchTimer)
  searchTimer = setTimeout(() => {
    appliedQuery.value = searchInput.value.trim()
    void load()
  }, 250)
}

function clearSearch(): void {
  if (searchTimer) clearTimeout(searchTimer)
  searchInput.value = ''
  appliedQuery.value = ''
  void load()
}

function toggle(id: string): void {
  expandedId.value = expandedId.value === id ? null : id
}

function startCreate(): void {
  isCreating.value = true
  expandedId.value = null
  formError.value = null
}

function cancelCreate(): void {
  isCreating.value = false
  formError.value = null
}

async function saveCreate(payload: { content: string; tags: string[] }): Promise<void> {
  isSaving.value = true
  formError.value = null
  const result = await remote('memories.create', () =>
    createWorkspaceMemory(props.workspaceId, payload.content, payload.tags),
  )
  isSaving.value = false
  if (!result.ok) {
    formError.value = result.reason
    return
  }
  isCreating.value = false
  expandedId.value = result.value.memory?.id ?? null
  await load()
}

async function remove(id: string): Promise<void> {
  deletingId.value = id
  error.value = null
  const result = await remote('memories.delete', () => deleteWorkspaceMemory(props.workspaceId, id))
  deletingId.value = null
  if (!result.ok) {
    error.value = result.reason
    return
  }
  if (expandedId.value === id) expandedId.value = null
  await load()
}

onMounted(() => void load())
onBeforeUnmount(() => {
  if (searchTimer) clearTimeout(searchTimer)
})
</script>

<template>
  <div class="flex h-full min-h-0 flex-col gap-3" data-testid="workspace-memories-panel">
    <div class="flex items-start justify-between gap-3 shrink-0">
      <div v-if="showHeading" class="min-w-0">
        <div class="flex items-center gap-2">
          <h3 class="text-lead font-semibold truncate" style="color: var(--semantic-text)">
            {{ itemName ? `${itemName} memories` : 'Memories' }}
          </h3>
          <span
            v-if="countLabel"
            class="text-micro font-semibold px-1.5 py-0.5 rounded-full tabular-nums"
            style="background-color: var(--semantic-wash); color: var(--semantic-text-muted)"
            data-testid="workspace-memories-count"
            >{{ countLabel }}</span
          >
        </div>
        <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
          Notes the agent saved with <code>save_memory</code>, scoped to this workspace.
        </p>
      </div>
      <div v-else class="flex items-center gap-2 min-w-0">
        <span
          v-if="countLabel"
          class="text-micro font-semibold px-1.5 py-0.5 rounded-full tabular-nums"
          style="background-color: var(--semantic-wash); color: var(--semantic-text-muted)"
          data-testid="workspace-memories-count"
          >{{ countLabel }}</span
        >
        <span class="text-dense truncate" style="color: var(--semantic-text-dim)">
          saved by the agent
        </span>
      </div>
      <button
        type="button"
        data-testid="workspace-memories-new"
        class="px-3 h-8 rounded-md text-dense font-medium border shrink-0 transition-colors duration-150 disabled:opacity-50"
        style="
          border-color: var(--color-violet);
          color: var(--color-violet);
          background-color: transparent;
        "
        :disabled="!hasWorkspace || isCreating"
        @click="startCreate"
      >
        + New memory
      </button>
    </div>

    <div v-if="hasWorkspace" class="flex items-center gap-2 shrink-0">
      <div class="relative flex-1 min-w-0">
        <input
          v-model="searchInput"
          type="search"
          data-testid="workspace-memories-search"
          aria-label="Search memories"
          placeholder="Search bodies and tags…"
          class="w-full px-3 h-8 rounded-md text-dense"
          style="
            background-color: var(--semantic-wash);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
          "
          @input="onSearchInput"
        />
        <button
          v-if="searchInput"
          type="button"
          data-testid="workspace-memories-search-clear"
          aria-label="Clear search"
          class="absolute right-1 top-1 h-6 w-6 rounded text-dense"
          style="color: var(--semantic-text-dim); background-color: transparent"
          @click="clearSearch"
        >
          ×
        </button>
      </div>
      <button
        type="button"
        data-testid="workspace-memories-refresh"
        class="px-3 h-8 rounded-md text-dense border shrink-0 transition-colors duration-150 disabled:opacity-50"
        style="
          border-color: var(--color-border);
          color: var(--semantic-text-muted);
          background-color: transparent;
        "
        :disabled="isLoading"
        @click="load"
      >
        {{ isLoading ? 'Loading…' : 'Refresh' }}
      </button>
    </div>

    <div
      v-if="error"
      data-testid="workspace-memories-error"
      class="px-4 py-3 rounded-md flex items-start justify-between gap-4 shrink-0"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-red)"
    >
      <p class="text-dense" style="color: var(--color-red)">{{ error }}</p>
      <button
        type="button"
        class="px-3 h-7 rounded-md text-dense border shrink-0"
        style="
          border-color: var(--color-border);
          color: var(--semantic-text-muted);
          background-color: transparent;
        "
        @click="load"
      >
        Retry
      </button>
    </div>

    <div
      v-if="!hasWorkspace"
      class="text-dense px-4 py-3 rounded-md"
      style="
        color: var(--semantic-text-muted);
        background-color: var(--semantic-content-bg);
        border: 1px dashed var(--color-border);
      "
      data-testid="workspace-memories-no-workspace"
    >
      Memories are scoped to a workspace — open this panel from a workspace to see them.
    </div>

    <div v-else class="flex-1 min-h-0 overflow-y-auto">
      <WorkspaceMemoryCreateForm
        v-if="isCreating"
        :saving="isSaving"
        :error="formError"
        @save="saveCreate"
        @cancel="cancelCreate"
      />
      <div v-if="isLoading && !isLoaded" class="space-y-2" data-testid="workspace-memories-loading">
        <div
          v-for="w in ['100%', '92%', '78%']"
          :key="w"
          class="h-16 rounded-md animate-pulse"
          :style="{ width: w, backgroundColor: 'var(--semantic-wash)' }"
        />
      </div>

      <EmptyState
        v-else-if="isLoaded && memories.length === 0 && !error"
        glyph="◍"
        :title="isSearching ? 'No memory matches that search' : 'No memories yet'"
        :description="
          isSearching
            ? 'Try a shorter word, or clear the search to see every note this workspace holds.'
            : 'The agent writes here with save_memory — preferences, conventions, decisions worth keeping. You can add one yourself too.'
        "
        :cta-label="isSearching ? undefined : '+ New memory'"
        :cta-action="isSearching ? undefined : startCreate"
      />

      <ul v-else class="space-y-2" data-testid="workspace-memories-list">
        <WorkspaceMemoryRow
          v-for="memory in memories"
          :key="memory.id"
          :memory="memory"
          :expanded="expandedId === memory.id"
          :deleting="deletingId === memory.id"
          @toggle="toggle(memory.id)"
          @delete="remove(memory.id)"
        />
      </ul>
    </div>
  </div>
</template>
