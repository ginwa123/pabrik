<!--
  RightSideBarSkillList — the skills list in the right sidebar.

  ONE list, fed by `GET /workspaces/:id/skills`. It used to be two
  collapsible sections (global + local) because a skill was a file in one
  of two directories; a skill is now a row scoped to one workspace, so
  there is nothing to split on and nothing to show a path for — the
  detail panel names the skill instead.

  The three states the pane can be in are kept distinct on purpose:
  loading, failed, and genuinely empty. A failed load used to land on
  "No skills available", which is the exact empty-vs-unavailable
  confusion this surface must not reintroduce, so the failure travels in
  the Effect's error channel and the template renders it.
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import { Effect } from 'effect'
import UiIcon from '../ui/UiIcon.vue'
import { getSkills, type Skill } from '../../api'
import { useSidebarStore } from '../../stores/sidebar'
import { useWorkspacesStore } from '../../stores/workspaces'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const emit = defineEmits<{
  'skill-click': [skill: Skill]
}>()

// The RESOLVED workspace, not the raw `activeWorkspaceId` ref — same reason DocumentsView.vue reads
// it this way.
const workspacesStore = useWorkspacesStore()
const workspaceId = computed(() => workspacesStore.activeWorkspace?.id ?? null)

const skills = ref<Skill[]>([])
const isLoading = ref(false)
/** Rendered in its own block — a failure is never rendered as an empty list. */
const error = ref<string | null>(null)

const hasSkills = computed(() => skills.value.length > 0)

// Skills expand/collapse state (persisted in useSidebarStore)
const sidebarStore = useSidebarStore()

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

// Load skills for the active workspace.
const loadSkills = async () => {
  const ws = workspaceId.value
  if (!ws) {
    // No scope to read from. Say nothing about emptiness — there is a
    // dedicated branch in the template for this.
    skills.value = []
    error.value = null
    return
  }

  isLoading.value = true
  error.value = null

  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => getSkills(ws),
      catch: (e) => new SyncRemoteError({ op: 'skills.load', reason: fail(e) }),
    }),
    'skills.load',
  )

  isLoading.value = false
  if (result.ok) {
    // Only the backend's own empty array means "no skills". A missing or
    // non-array field is tolerated to zero rows rather than throwing —
    // a real failure is the other branch, and it renders its reason.
    skills.value = Array.isArray(result.value?.skills) ? result.value.skills : []
  } else {
    skills.value = []
    error.value = result.reason
  }
}

// Handle skill click
const handleSkillClick = (skill: Skill) => {
  emit('skill-click', skill)
}

// Refresh skills
const refreshSkills = () => {
  loadSkills()
}

// Reload on workspace change. `immediate` covers the first load, so the
// old mount-plus-immediate-watch double fetch is gone: mount loads once,
// and the prev-value guard below reloads only when the id moves.
let prevSkillListWorkspaceId: string | null = workspaceId.value
onMounted(() => {
  prevSkillListWorkspaceId = workspaceId.value
  loadSkills()
})
onUpdated(() => {
  if (workspaceId.value === prevSkillListWorkspaceId) return
  prevSkillListWorkspaceId = workspaceId.value
  loadSkills()
})
</script>

<template>
  <div class="flex flex-col h-full" data-testid="skills-list-pane">
    <!-- Skills content (scrollable) -->
    <div class="flex-1 overflow-y-auto">
      <!-- Loading -->
      <div v-if="isLoading" class="flex-1 flex items-center justify-center">
        <svg
          class="animate-spin w-5 h-5"
          style="color: var(--color-aqua)"
          viewBox="0 0 24 24"
          fill="none"
        >
          <circle
            class="opacity-25"
            cx="12"
            cy="12"
            r="10"
            stroke="currentColor"
            stroke-width="4"
          />
          <path
            class="opacity-75"
            fill="currentColor"
            d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
          />
        </svg>
      </div>

      <!-- Error state. Distinct from the empty state on purpose. -->
      <div
        v-else-if="error"
        class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        data-testid="skills-list-error"
      >
        <span class="text-title-lg mb-2">⚠️</span>
        <p class="text-dense" style="color: var(--semantic-text-dim)">
          {{ error }}
        </p>
        <button
          @click="refreshSkills"
          class="mt-3 px-3 py-1.5 rounded text-dense transition-colors"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >
          Retry
        </button>
      </div>

      <!-- No workspace to scope the list to. -->
      <div
        v-else-if="!workspaceId"
        class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        data-testid="skills-list-no-workspace"
      >
        <UiIcon name="brain" size-class="w-6 h-6" class="mb-3" />
        <p class="text-dense" style="color: var(--semantic-text-dim)">
          Select a workspace to see its skills
        </p>
      </div>

      <!-- Empty state: the workspace really has no skills. -->
      <div
        v-else-if="!hasSkills"
        class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        data-testid="skills-list-empty"
      >
        <UiIcon name="brain" size-class="w-6 h-6" class="mb-3" />
        <p class="text-dense" style="color: var(--semantic-text-dim)">No skills available</p>
      </div>

      <!-- One section: the workspace's skills -->
      <div v-else class="py-1">
        <button
          type="button"
          class="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-dense font-semibold uppercase tracking-wide transition-colors hover:opacity-80 text-left"
          style="color: var(--semantic-text-muted)"
          @click="sidebarStore.toggleSkillsExpanded"
          data-testid="skills-list-section-toggle"
        >
          <UiIcon name="brain" /> Skills ({{ skills.length }})
          <svg
            class="w-3 h-3 shrink-0 transition-transform duration-200"
            :class="{ 'rotate-90': sidebarStore.skillsExpanded }"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 5l7 7-7 7"
            />
          </svg>
        </button>
        <div v-show="sidebarStore.skillsExpanded">
          <button
            v-for="skill in skills"
            :key="skill.name"
            class="w-full flex flex-col items-start gap-1 px-3 py-2 text-body transition-colors hover:opacity-80 text-left"
            @click="handleSkillClick(skill)"
            :data-skill-name="skill.name"
          >
            <span class="font-medium" style="color: var(--semantic-text)">
              {{ skill.name }}
            </span>
            <span class="text-dense line-clamp-2" style="color: var(--semantic-text-dim)">
              {{ skill.description }}
            </span>
          </button>
        </div>
      </div>
    </div>

    <!-- Footer -->
    <div
      class="h-8 flex items-center justify-between px-3 shrink-0 text-dense"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim)"
    >
      <span data-testid="skills-list-count">{{ skills.length }} skills</span>
      <button
        @click="refreshSkills"
        class="p-1 rounded hover:opacity-70 transition-opacity"
        title="Refresh skills"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
          />
        </svg>
      </button>
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
