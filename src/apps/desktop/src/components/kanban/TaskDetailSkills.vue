<script setup lang="ts">
import { ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  availableSkills,
  clearSkills,
  filteredSkills,
  isCreateMode,
  isSkillPickerOpen,
  selectedSkillCount,
  selectedSkills,
  skillLabel,
  skillSearch,
  skillsLoading,
  toggleSkill,
  toggleSkillPicker,
} = useTaskDetailContext()
const skillPickerRef = ref<HTMLElement | null>(null)
</script>

<template>
          <div v-if="isCreateMode" ref="skillPickerRef">
            <button
              type="button"
              @click.stop="toggleSkillPicker"
              class="ktd-picker w-full text-dense flex items-center gap-1.5 transition-opacity duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :title="
                selectedSkillCount > 0
                  ? `Agent will use: ${selectedSkills.join(', ')}`
                  : 'No skill - the agent discovers one itself if needed'
              "
              data-testid="kanban-task-detail-skill-picker"
            >
              <UiIcon name="clipboard" />
              <span class="font-medium">Skills</span>
              <span style="color: var(--semantic-text-muted)">{{ skillLabel }}</span>
              <span
                v-if="selectedSkillCount > 0"
                class="shrink-0 text-micro px-1.5 rounded-full"
                style="background-color: rgba(137, 146, 167, 0.24)"
                data-testid="kanban-task-detail-skill-picker-count"
                >{{ selectedSkillCount }}</span
              >
              <span class="text-micro shrink-0" style="color: var(--semantic-text-dim)"
                >&#9662;</span
              >
            </button>
            <div
              v-if="isSkillPickerOpen"
              class="ktd-list mt-1"
              data-testid="kanban-task-detail-skill-picker-dropdown"
              @click.stop
            >
              <div
                class="flex items-center gap-2 px-3 py-2"
                style="border-bottom: 1px solid var(--color-border)"
              >
                <input
                  v-model="skillSearch"
                  type="text"
                  placeholder="Search skills..."
                  class="flex-1 min-w-0 bg-transparent outline-none text-dense"
                  style="color: var(--semantic-text)"
                  data-testid="kanban-task-detail-skill-picker-search"
                />
                <button
                  type="button"
                  @click="clearSkills"
                  class="text-micro shrink-0 hover:opacity-80"
                  style="color: var(--semantic-link)"
                  data-testid="kanban-task-detail-skill-picker-clear"
                >
                  Clear all
                </button>
              </div>
              <div class="max-h-[300px] overflow-y-auto">
                <button
                  v-for="sk in filteredSkills"
                  :key="sk.name"
                  type="button"
                  @click="toggleSkill(sk.name)"
                  class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-start gap-2"
                  style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
                  data-testid="kanban-task-detail-skill-picker-item"
                >
                  <input
                    type="checkbox"
                    class="mt-0.5 shrink-0"
                    :checked="selectedSkills.includes(sk.name)"
                    tabindex="-1"
                    aria-hidden="true"
                    data-testid="kanban-task-detail-skill-picker-check"
                  />
                  <span class="min-w-0">
                    <span class="font-medium block truncate">{{ sk.name }}</span>
                    <span
                      v-if="sk.description"
                      class="text-micro block line-clamp-2"
                      style="color: var(--semantic-text-muted)"
                    >
                      {{ sk.description }}
                    </span>
                  </span>
                </button>
                <div
                  v-if="!skillsLoading && availableSkills.length === 0"
                  class="px-3 py-2 text-dense"
                  style="color: var(--semantic-text-muted)"
                  data-testid="kanban-task-detail-skill-picker-empty"
                >
                  No skills installed. Add one in Settings.
                </div>
                <div
                  v-else-if="filteredSkills.length === 0"
                  class="px-3 py-2 text-dense"
                  style="color: var(--semantic-text-muted)"
                  data-testid="kanban-task-detail-skill-picker-no-match"
                >
                  No skill matches "{{ skillSearch }}".
                </div>
              </div>
            </div>
          </div>

          <!-- The picked skills as removable chips, so the set stays visible
               after the dropdown closes. -->
          <div
            v-if="isCreateMode && selectedSkillCount > 0"
            class="w-full flex flex-wrap items-center gap-1.5 mt-1"
            data-testid="kanban-task-detail-skill-chips"
          >
            <span
              v-for="name in selectedSkills"
              :key="name"
              class="inline-flex items-center gap-1 text-meta px-1.5 py-0.5 rounded font-medium"
              style="background-color: rgba(137, 146, 167, 0.16); color: var(--semantic-text)"
              :data-testid="`kanban-task-detail-skill-chip-${name}`"
            >
              {{ name }}
              <button
                type="button"
                @click="toggleSkill(name)"
                class="inline-flex items-center justify-center w-3 h-3 rounded-full hover:bg-black/20"
                :aria-label="`Remove skill ${name}`"
                :data-testid="`kanban-task-detail-skill-chip-remove-${name}`"
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
          </div>
</template>

<style scoped>
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
