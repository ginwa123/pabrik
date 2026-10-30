<script setup lang="ts">
import { computed } from 'vue'
import type { GitFileChange } from '../../../api'
import EmptyState from '../../pabrik/EmptyState.vue'
import DiffCounts from './DiffCounts.vue'
import type { DiffCounts as DiffCountsMap } from './sidebarDiffLists'
import { worktreeCountsFor } from './sidebarDiffLists'
import {
  chipForFile,
  filterRows,
  isFilterActive,
  pathParts,
  showsFilter,
} from './sidebarDiffRows'

const props = defineProps<{
  stagedFiles: GitFileChange[]
  unstagedFiles: GitFileChange[]
  untrackedFiles: GitFileChange[]
  fileFilter: string
  commitMessage: string
  canCommit: boolean
  isCommitting: boolean
  commitError: string
  isStaging: boolean
  selectedPath: string | null
  selectedStaged: boolean
  diffCounts: DiffCountsMap
}>()

const emit = defineEmits<{
  'update:filter': [value: string]
  'update:commit-message': [value: string]
  commit: []
  stage: [file: GitFileChange]
  unstage: [file: GitFileChange]
  'file-click': [event: MouseEvent, file: GitFileChange, staged: boolean]
  'row-aux-click': [event: MouseEvent, path: string]
  'row-context-menu': [event: MouseEvent, path: string]
}>()

const filteredStagedFiles = computed(() => filterRows(props.stagedFiles, props.fileFilter))
const filteredUnstagedFiles = computed(() => filterRows(props.unstagedFiles, props.fileFilter))
const filteredUntrackedFiles = computed(() => filterRows(props.untrackedFiles, props.fileFilter))
const changedFileTotal = computed(
  () => props.stagedFiles.length + props.unstagedFiles.length + props.untrackedFiles.length,
)
const showWorktreeFilter = computed(() => showsFilter(changedFileTotal.value))
const fileFilterActive = computed(() => isFilterActive(props.fileFilter))
const worktreeHits = computed(
  () =>
    filteredStagedFiles.value.length +
    filteredUnstagedFiles.value.length +
    filteredUntrackedFiles.value.length,
)

const countsFor = (path: string, staged: boolean): { added: number; removed: number } | null =>
  worktreeCountsFor(props.diffCounts, path, staged)

const setFilter = (value: string) => emit('update:filter', value)
const setCommitMessage = (value: string) => emit('update:commit-message', value)
const commitStaged = () => emit('commit')
const stageFile = (file: GitFileChange) => emit('stage', file)
const unstageFile = (file: GitFileChange) => emit('unstage', file)
const onFileRowClick = (event: MouseEvent, file: GitFileChange, staged: boolean) =>
  emit('file-click', event, file, staged)
const onFileRowAuxClick = (event: MouseEvent, path: string) => emit('row-aux-click', event, path)
const onFileRowContextMenu = (event: MouseEvent, path: string) =>
  emit('row-context-menu', event, path)
</script>
<template>
          <!-- Commit box: message input + Commit button for the staged
               index. Sits above the file groups (VSCode order) so the
               message is typed where the changes are listed. -->
          <div class="px-2 pt-2">
            <div
              class="rounded-md p-2 flex flex-col gap-2"
              style="background-color: var(--color-bg-m1); border: 1px solid var(--color-border)"
            >
              <textarea
                :value="commitMessage"
                rows="2"
                placeholder="Commit message…"
                class="w-full bg-transparent outline-none text-dense resize-y min-h-8"
                style="color: var(--semantic-text)"
                data-testid="sidebar-commit-message"
                @input="setCommitMessage(($event.target as HTMLTextAreaElement).value)"
                @keydown.ctrl.enter="commitStaged"
                @keydown.meta.enter="commitStaged"
              />
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="px-3 h-7 text-dense rounded-md font-medium transition-opacity disabled:opacity-40"
                  style="background: var(--color-green); color: var(--color-bg)"
                  data-testid="sidebar-commit-button"
                  :disabled="!canCommit"
                  :title="
                    stagedFiles.length === 0
                      ? 'Stage files first — commit only takes what is staged'
                      : 'Commit staged changes (Ctrl+Enter)'
                  "
                  @click="commitStaged"
                >
                  {{ isCommitting ? 'Committing…' : 'Commit' }}
                </button>
                <span
                  v-if="stagedFiles.length === 0"
                  class="text-micro truncate"
                  style="color: var(--semantic-text-dim)"
                  data-testid="sidebar-commit-hint"
                >
                  Stage files to enable commit
                </span>
              </div>
              <p
                v-if="commitError"
                class="text-dense break-words"
                style="color: var(--semantic-error); white-space: pre-wrap"
                data-testid="sidebar-commit-error"
              >
                {{ commitError }}
              </p>
            </div>
          </div>
          <div v-if="showWorktreeFilter" class="px-2 pt-2">
            <label
              class="flex items-center gap-2 h-8 px-2 rounded-md"
              style="background-color: var(--color-bg-m1); border: 1px solid var(--color-border)"
            >
              <span aria-hidden="true" style="color: var(--semantic-text-dim)">⌕</span>
              <input
                :value="fileFilter"
                type="text"
                placeholder="Filter files…"
                class="flex-1 min-w-0 bg-transparent outline-none text-dense"
                style="color: var(--semantic-text)"
                data-testid="sidebar-file-filter"
                @input="setFilter(($event.target as HTMLInputElement).value)"
              />
              <span class="shrink-0 text-micro" style="color: var(--semantic-text-dim)">
                {{ changedFileTotal }}
              </span>
            </label>
          </div>
          <div v-if="fileFilterActive && worktreeHits === 0" class="px-2 pt-2">
            <EmptyState
              class="m-0"
              glyph="⌕"
              title="No files match"
              :description="`Nothing in this working tree matches “${fileFilter.trim()}”.`"
            />
          </div>
          <template v-else>
            <div v-if="filteredStagedFiles.length > 0" class="py-1">
              <div
                class="px-3 py-1 text-micro font-semibold uppercase tracking-wide"
                style="color: var(--color-green)"
              >
                Staged Changes ({{ filteredStagedFiles.length }})
              </div>
              <div
                v-for="file in filteredStagedFiles"
                :key="'staged-' + file.path"
                role="button"
                tabindex="0"
                class="flex items-center gap-2 px-3 h-7 cursor-pointer hover:opacity-80"
                :style="{
                  backgroundColor:
                    selectedPath === file.path && selectedStaged
                      ? 'var(--semantic-active-bg)'
                      : 'transparent',
                  boxShadow:
                    selectedPath === file.path && selectedStaged
                      ? 'inset 2px 0 0 0 var(--color-violet)'
                      : 'none',
                }"
                :data-testid="`sidebar-diff-file-staged-${file.path}`"
                :title="file.path"
                @click="onFileRowClick($event, file, true)"
                @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
                @auxclick="onFileRowAuxClick($event, file.path)"
              >
                <span
                  class="w-4 h-4 shrink-0 rounded flex items-center justify-center text-micro font-bold"
                  :style="{ backgroundColor: chipForFile(file).bg, color: chipForFile(file).fg }"
                  :title="chipForFile(file).title"
                  aria-hidden="true"
                  >{{ chipForFile(file).letter }}</span
                >
                <span class="text-dense truncate flex-1 min-w-0" :title="file.path">
                  <span style="color: var(--semantic-text-dim)">{{ pathParts(file.path).dir }}</span
                  ><span style="color: var(--semantic-text)">{{ pathParts(file.path).name }}</span>
                </span>
                <DiffCounts
                  :added="countsFor(file.path, true)?.added ?? null"
                  :removed="countsFor(file.path, true)?.removed ?? null"
                />
                <button
                  type="button"
                  class="w-5 h-5 shrink-0 rounded text-dense flex items-center justify-center hover:opacity-70"
                  style="color: var(--semantic-text-dim)"
                  title="Unstage file"
                  :disabled="isStaging"
                  @click.stop="unstageFile(file)"
                >
                  −
                </button>
              </div>
            </div>

            <div v-if="filteredUnstagedFiles.length > 0" class="py-1">
              <div
                class="px-3 py-1 text-micro font-semibold uppercase tracking-wide"
                style="color: var(--color-orange)"
              >
                Changes ({{ filteredUnstagedFiles.length }})
              </div>
              <div
                v-for="file in filteredUnstagedFiles"
                :key="'unstaged-' + file.path"
                role="button"
                tabindex="0"
                class="flex items-center gap-2 px-3 h-7 cursor-pointer hover:opacity-80"
                :style="{
                  backgroundColor:
                    selectedPath === file.path && !selectedStaged
                      ? 'var(--semantic-active-bg)'
                      : 'transparent',
                  boxShadow:
                    selectedPath === file.path && !selectedStaged
                      ? 'inset 2px 0 0 0 var(--color-violet)'
                      : 'none',
                }"
                :data-testid="`sidebar-diff-file-unstaged-${file.path}`"
                :title="file.path"
                @click="onFileRowClick($event, file, false)"
                @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
                @auxclick="onFileRowAuxClick($event, file.path)"
              >
                <span
                  class="w-4 h-4 shrink-0 rounded flex items-center justify-center text-micro font-bold"
                  :style="{ backgroundColor: chipForFile(file).bg, color: chipForFile(file).fg }"
                  :title="chipForFile(file).title"
                  aria-hidden="true"
                  >{{ chipForFile(file).letter }}</span
                >
                <span class="text-dense truncate flex-1 min-w-0" :title="file.path">
                  <span style="color: var(--semantic-text-dim)">{{ pathParts(file.path).dir }}</span
                  ><span style="color: var(--semantic-text)">{{ pathParts(file.path).name }}</span>
                </span>
                <DiffCounts
                  :added="countsFor(file.path, false)?.added ?? null"
                  :removed="countsFor(file.path, false)?.removed ?? null"
                />
                <button
                  type="button"
                  class="w-5 h-5 shrink-0 rounded text-dense flex items-center justify-center hover:opacity-70"
                  style="color: var(--semantic-text-dim)"
                  title="Stage file"
                  :disabled="isStaging"
                  @click.stop="stageFile(file)"
                >
                  +
                </button>
              </div>
            </div>

            <div v-if="filteredUntrackedFiles.length > 0" class="py-1">
              <div
                class="px-3 py-1 text-micro font-semibold uppercase tracking-wide"
                style="color: var(--semantic-text-dim)"
              >
                Untracked ({{ filteredUntrackedFiles.length }})
              </div>
              <div
                v-for="file in filteredUntrackedFiles"
                :key="'untracked-' + file.path"
                role="button"
                tabindex="0"
                class="flex items-center gap-2 px-3 h-7 cursor-pointer hover:opacity-80"
                :style="{
                  backgroundColor:
                    selectedPath === file.path && !selectedStaged
                      ? 'var(--semantic-active-bg)'
                      : 'transparent',
                  boxShadow:
                    selectedPath === file.path && !selectedStaged
                      ? 'inset 2px 0 0 0 var(--color-violet)'
                      : 'none',
                }"
                :data-testid="`sidebar-diff-file-untracked-${file.path}`"
                :title="file.path"
                @click="onFileRowClick($event, file, false)"
                @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
                @auxclick="onFileRowAuxClick($event, file.path)"
              >
                <span
                  class="w-4 h-4 shrink-0 rounded flex items-center justify-center text-micro font-bold"
                  style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim)"
                  title="Untracked"
                  aria-hidden="true"
                  >?</span
                >
                <span class="text-dense truncate flex-1 min-w-0" :title="file.path">
                  <span style="color: var(--semantic-text-dim)">{{ pathParts(file.path).dir }}</span
                  ><span style="color: var(--semantic-text)">{{ pathParts(file.path).name }}</span>
                </span>
                <DiffCounts
                  :added="countsFor(file.path, false)?.added ?? null"
                  :removed="countsFor(file.path, false)?.removed ?? null"
                />
                <button
                  type="button"
                  class="w-5 h-5 shrink-0 rounded text-dense flex items-center justify-center hover:opacity-70"
                  style="color: var(--semantic-text-dim)"
                  title="Stage file"
                  :disabled="isStaging"
                  @click.stop="stageFile(file)"
                >
                  +
                </button>
              </div>
            </div>
          </template>
</template>
