<!--
  SkillList — the list half of the Skills settings panel.

  One list, from `GET /workspaces/:id/skills`: the Global / Local split and
  the per-row path both belonged to the two-directory layout and are gone.
  Load failure travels in the Effect's error channel and renders in its own
  block, so a backend outage is never read as "this workspace has no
  skills".
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import ListSkeleton from '../shell/ListSkeleton.vue'
import SkillAutoImproveToggle from '../ui/SkillAutoImproveToggle.vue'
import { Effect } from 'effect'
import { getSkills, type Skill } from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  selectedSkillName: string | null
  /** Explicit workspace binding. When set, the list reads this workspace's
   * skills instead of the active workspace's — the workspace settings page
   * binds the route workspace, which may differ from the active one.
   * Absent = previous behaviour (active workspace). */
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

const openSkillDetail = (skill: Skill) => {
  emit('selectSkill', skill.name)
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

defineExpose({
  refresh: loadSkills,
})
</script>

<template>
  <div class="skill-list" :data-workspace="workspaceId ?? ''">
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

    <!-- Skills List -->
    <div v-else class="space-y-2">
      <div
        v-for="skill in skills"
        :key="skill.name"
        class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90 mb-2"
        :class="{ 'ring-2': props.selectedSkillName === skill.name }"
        :style="
          props.selectedSkillName === skill.name
            ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);'
            : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'
        "
        @click="openSkillDetail(skill)"
        :data-skill-name="skill.name"
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
            <SkillAutoImproveToggle
              v-if="workspaceId"
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
