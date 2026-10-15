<!--
  KanbanTaskDetailDialog — DEPRECATED modal wrapper.

  The form itself lives in KanbanTaskDetail.vue (inline side-panel,
  no Teleport/backdrop). This file keeps the old modal chrome
  (Teleport + backdrop + centered card) for backward compatibility
  with the existing test suite, which mounts this path directly.
  New code (KanbanView) uses KanbanTaskDetail inline — do not add
  new callers here.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import KanbanTaskDetail from './KanbanTaskDetail.vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    mode?: 'edit' | 'create'
    task: Task | null
    column?: KanbanColumn | null
    errorMessage?: string | null
    cwd?: string
    workspaceId?: string
    availableColumns?: KanbanColumn[]
    creating?: boolean
    // NEW (kanban task dependencies). Same-board candidates for
    // the dependency picker. Forwarded to the inner detail panel.
    tasks?: Task[]
  }>(),
  {
    mode: 'edit',
    column: null,
    errorMessage: null,
    cwd: '',
    workspaceId: '',
    availableColumns: (): KanbanColumn[] => [],
    creating: false,
    tasks: (): Task[] => [],
  },
)

const emit = defineEmits<{
  'update:show': [value: boolean]
  close: []
  save: [payload: { mode: 'edit'; name: string; description: string; tags: string[]; depends_on?: string[] }]
  create: [payload: Record<string, unknown>]
  'create-and-run': [payload: Record<string, unknown>]
  'column-change': [columnId: string]
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
  'update-cwd': [payload: { cwd: string }]
  'start-agent': [payload: { taskId: string }]
}>()

const isCreateMode = computed(() => props.mode === 'create')

const forwardClose = () => {
  emit('update:show', false)
  emit('close')
}

// Test seam: two specs drive the cwd picker via
// `wrapper.vm.selectCwd(path)` on this wrapper. Delegate to the
// inner inline panel (which owns cwdSession + the update-cwd emit).
const innerDetail = ref<{ selectCwd: (path: string) => void } | null>(null)
defineExpose({
  selectCwd: (path: string) => innerDetail.value?.selectCwd(path),
})
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-task-detail-modal">
      <div
        v-if="show && (task || isCreateMode)"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="forwardClose"
        role="dialog"
        aria-modal="true"
        data-testid="kanban-task-detail-dialog"
      >
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="forwardClose"
        />
        <div
          class="relative w-full max-w-2xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            max-height: min(80vh, calc(100vh - 2rem));
          "
        >
          <KanbanTaskDetail
            ref="innerDetail"
            :show="true"
            :mode="mode"
            :task="task"
            :column="column"
            :error-message="errorMessage"
            :cwd="cwd"
            :workspace-id="workspaceId"
            :available-columns="availableColumns"
            :creating="creating"
            :tasks="tasks"
            @update:show="forwardClose"
            @close="forwardClose"
            @save="(p) => emit('save', p)"
            @create="(p) => emit('create', p)"
            @create-and-run="(p) => emit('create-and-run', p)"
            @column-change="(id) => emit('column-change', id)"
            @update-unattended="(p) => emit('update-unattended', p)"
            @update-cwd="(p) => emit('update-cwd', p)"
            @start-agent="(p) => emit('start-agent', p)"
          />
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.kanban-task-detail-modal-enter-active,
.kanban-task-detail-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-task-detail-modal-enter-from,
.kanban-task-detail-modal-leave-to {
  opacity: 0;
}
</style>
