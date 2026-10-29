<script setup lang="ts">
import { ref } from 'vue'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  agentsLoading,
  availableAgents,
  cwdPickerStyle,
  cwdSession,
  isAgentPickerOpen,
  isCreateMode,
  isCwdPickerOpen,
  loadFoldersForCwdPicker,
  props,
  selectAgent,
  selectCwd,
  selectedAgent,
  setCwdPickerEl,
  toggleAgentPicker,
  toggleCwdPicker,
} = useTaskDetailContext()
const agentPickerRef = ref<HTMLElement | null>(null)
</script>

<template>
          <div class="ktd-rail-group" data-testid="kanban-task-detail-settings-section">
            <!-- Per-task cwd picker. Same trigger pattern as the
                     agent picker (button toggle + click-outside
                     close + ▾ caret). Pre-populated from the parent
                     kanban's path in create mode, or the task's
                     persisted `cwd` field in edit mode. Plan:
                     docs/superpowers/plans/2026-08-14-kanban-task-
                     detail-edit-cwd.md -->
            <div :ref="setCwdPickerEl">
              <button
                type="button"
                @click.stop="toggleCwdPicker"
                class="ktd-picker w-full text-dense flex items-center gap-1.5 transition-opacity duration-200"
                :style="cwdPickerStyle"
                :title="
                  cwdSession
                    ? `Project root: ${cwdSession}`
                    : isCreateMode
                      ? 'No project root (optional)'
                      : 'No project root. Click to set a per-task cwd.'
                "
                data-testid="kanban-task-detail-cwd-picker"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  class="w-3.5 h-3.5 shrink-0"
                  aria-hidden="true"
                  data-testid="kanban-task-detail-cwd-picker-icon"
                >
                  <path
                    d="M2 5a2 2 0 012-2h4.586a1 1 0 01.707.293L11 5h5a2 2 0 012 2v8a2 2 0 01-2 2H4a2 2 0 01-2-2V5z"
                  />
                </svg>
                <span class="font-medium">Project root</span>
                <span
                  class="font-mono truncate max-w-[200px] inline-block align-middle"
                  style="color: var(--semantic-text-muted)"
                >
                  {{ cwdSession ? cwdSession : '(none)' }}
                </span>
                <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)">▾</span>
              </button>
              <div
                v-if="isCwdPickerOpen"
                class="absolute z-30 mt-1 left-0"
                data-testid="kanban-task-detail-cwd-picker-dropdown"
              >
                <FilePickerDialog
                  v-model="isCwdPickerOpen"
                  mode="folder"
                  :load-items="loadFoldersForCwdPicker"
                  :key-for="(e: any) => e.path as string"
                  :path-for="(e: any) => e.path as string"
                  :is-expandable="(e: any) => e.is_directory as boolean"
                  :label-for="(e: any) => e.name as string"
                  :close-on-select="true"
                  :initial-path="cwdSession || props.cwd || '/'"
                  :selected-path="cwdSession || props.cwd || ''"
                  title="Select Per-Task Project Root"
                  :enable-recent-history="true"
                  @select="selectCwd"
                />
              </div>
            </div>

            <!-- Agent picker (create mode only). Same chip-style
                     trigger as the cwd picker so they read as siblings. -->
            <div v-if="isCreateMode" ref="agentPickerRef">
              <button
                type="button"
                @click.stop="toggleAgentPicker"
                class="ktd-picker w-full text-dense flex items-center gap-1.5 transition-opacity duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                :title="
                  selectedAgent
                    ? `Using agent: ${selectedAgent}`
                    : 'Using default (top-level config)'
                "
                data-testid="kanban-task-detail-agent-picker"
              >
                <UiIcon name="robot" />
                <span class="font-medium">Agent</span>
                <span style="color: var(--semantic-text-muted)">{{
                  selectedAgent || 'Default'
                }}</span>
                <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)">▾</span>
              </button>
              <div
                v-if="isAgentPickerOpen"
                class="ktd-list mt-1"
                data-testid="kanban-task-detail-agent-picker-dropdown"
                @click.stop
              >
                <button
                  type="button"
                  @click="selectAgent('')"
                  class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center justify-between"
                  style="color: var(--semantic-text)"
                  data-testid="kanban-task-detail-agent-picker-item"
                >
                  <span class="font-medium">Default (top-level config)</span>
                  <span v-if="selectedAgent === ''">✓</span>
                </button>
                <button
                  v-for="p in availableAgents"
                  :key="p.name"
                  type="button"
                  @click="selectAgent(p.name)"
                  class="w-full text-left px-3 py-2 text-dense hover:opacity-80"
                  style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
                  data-testid="kanban-task-detail-agent-picker-item"
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium">{{ p.name }}</span>
                    <span v-if="selectedAgent === p.name">✓</span>
                  </div>
                  <div class="text-micro mt-0.5" style="color: var(--semantic-text-muted)">
                    {{ p.model }} · {{ p.base_url }}
                  </div>
                </button>
                <div
                  v-if="!agentsLoading && availableAgents.length === 0"
                  class="px-3 py-2 text-dense"
                  style="color: var(--semantic-text-muted)"
                  data-testid="kanban-task-detail-agent-picker-empty"
                >
                  No agents configured. Add one in Settings.
                </div>
              </div>
            </div>
          </div>
</template>

<style scoped>
.ktd-rail-group {
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
}


.ktd-picker {
  min-height: 30px;
  padding: 5px 8px;
  border-radius: 6px;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
}


.ktd-list {
  border-radius: 8px;
  overflow: hidden;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
}
</style>
