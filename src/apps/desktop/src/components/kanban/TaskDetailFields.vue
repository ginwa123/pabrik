<script setup lang="ts">
import KanbanDependsInput from './KanbanDependsInput.vue'
import KanbanDescriptionEditor from './KanbanDescriptionEditor.vue'
import KanbanTagsInput from './KanbanTagsInput.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  blockedDepIds,
  cwd,
  dependsCandidates,
  dependsOn,
  description,
  filteredTagSuggestions,
  imageUrls,
  isCreateMode,
  isMediaLoading,
  openImagePopup,
  props,
  setDescriptionEditorEl,
  setTagsInputEl,
  tagSuggestions,
  tags,
} = useTaskDetailContext()
</script>

<template>

          <!-- Description — editor in both modes. The editor owns its own
                 textarea, paperclip, char counter, @-trigger file picker
                 and image previews; the dialog passes the v-model + cwd. -->
          <div>
            <div class="mb-1">
              <label
                for="kanban-task-detail-description"
                class="block text-dense font-medium"
                style="color: var(--semantic-text-muted)"
              >
                Description
              </label>
            </div>
            <p class="text-meta mb-2" style="color: var(--semantic-text-muted)">
              Markdown supported. Type <span class="font-mono">@</span> to link a file. Paste or
              attach images.
            </p>

            <!-- Migration 069 — kanban image urls gallery. Reads
                   from task.imageUrls (set by the create-mode host
                   flow OR loaded from the row on edit-mode open).
                   Each image is a `data:image/<mime>;base64,...`
                   URL (from the `||`-delimited column string split
                   by the store's normalizeTaskTags). The editor
                   handles add/remove via its existing
                   `pendingFiles` mechanism; this gallery is the
                   read-only display of what's currently persisted.
                   Plan: docs/superpowers/plans/2026-08-06-kanban-
                   image-urls-column.md. -->
            <div
              v-if="imageUrls.length > 0"
              class="mb-3 flex flex-wrap gap-2"
              data-testid="kanban-task-detail-image-gallery"
            >
              <img
                v-for="(url, idx) in imageUrls"
                :key="idx"
                :src="url"
                :alt="`Task image ${idx + 1}`"
                class="w-24 h-24 object-cover rounded border cursor-pointer transition-opacity hover:opacity-80"
                style="border-color: var(--color-border)"
                :data-testid="`kanban-task-detail-image-${idx}`"
                @click="openImagePopup(url)"
              />
            </div>
            <div
              v-else-if="isMediaLoading"
              class="mb-3 text-meta"
              style="color: var(--semantic-text-muted)"
              data-testid="kanban-task-detail-media-loading"
            >
              Loading media…
            </div>

            <!-- Editor: shown in BOTH create + edit modes. The
                   previous "Preview" toggle button (which flipped to
                   <MarkdownDescription>) was removed per user
                   feedback — the dialog stays focused on the editor.
                   Plan: 2026-08-06-kanban-no-base64-in-desc. -->
            <KanbanDescriptionEditor
              :ref="setDescriptionEditorEl"
              v-model="description"
              :cwd="cwd"
              :task-id="props.task?.id ?? ''"
              :max-length="undefined"
              :test-id="
                isCreateMode
                  ? 'kanban-task-detail-create-description'
                  : 'kanban-task-detail-description'
              "
              data-testid="kanban-task-detail-description-editor"
            />
          </div>

          <!-- Tags (Migration 067 — kanban task tags feature).
                 Free-form chip input. Always shown (create + edit
                 modes). The KanbanTagsInput component handles all
                 validation + dedupe + color rendering. -->
          <div class="mt-4">
            <label
              for="kanban-task-detail-tags"
              class="block text-dense font-medium mb-1"
              style="color: var(--semantic-text-muted)"
            >
              Tags
            </label>
            <p class="text-meta mb-2" style="color: var(--semantic-text-muted)">
              Optional. Press Enter or comma to add. Letters, digits, underscores, hyphens.
            </p>
            <KanbanTagsInput
              :ref="setTagsInputEl"
              v-model="tags"
              :suggestions="filteredTagSuggestions"
              :has-more="tagSuggestions.hasMore.value"
              :loading-more="tagSuggestions.loading.value"
              :on-load-more="tagSuggestions.loadNextPage"
              :test-id="isCreateMode ? 'kanban-task-detail-create-tags' : 'kanban-task-detail-tags'"
            />
          </div>

          <!-- Dependencies (kanban task dependencies feature). Edit mode
             only: a new task has no id yet, so there is nothing to
             point an edge at until it is created. Same save path as
             tags — the picker v-models `dependsOn`, handleSave
             forwards it only when changed. -->
          <div v-if="!isCreateMode && dependsCandidates.length > 0" class="mt-4">
            <label
              for="kanban-task-detail-depends"
              class="block text-dense font-medium mb-1"
              style="color: var(--semantic-text-muted)"
            >
              Depends on
            </label>
            <p class="text-meta mb-2" style="color: var(--semantic-text-muted)">
              Blocked until every dependency reaches a completing column. Orange dot = not completed
              yet.
            </p>
            <KanbanDependsInput
              v-model="dependsOn"
              :tasks="dependsCandidates"
              :self-task-id="props.task?.id ?? ''"
              :blocked-ids="blockedDepIds"
              test-id="kanban-task-detail-depends"
            />
          </div>
</template>
