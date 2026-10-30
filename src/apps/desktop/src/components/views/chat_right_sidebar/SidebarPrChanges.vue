<script setup lang="ts">
import { computed } from 'vue'
import { forgeWording } from '../../../helpers/forgeWording'
import EmptyState from '../../pabrik/EmptyState.vue'
import DiffCounts from './DiffCounts.vue'
import type { SplitDiffFile } from './parseUnifiedDiff'
import { prCountsFor, prDiffCountsOf } from './sidebarDiffLists'
import {
  chipFor,
  filterRows,
  isFilterActive,
  pathParts,
  previewFor,
  showsFilter,
} from './sidebarDiffRows'

const props = defineProps<{
  prFiles: SplitDiffFile[]
  prConflictFiles: string[]
  conflictsOnly: boolean
  fileFilter: string
  selectedPath: string | null
  previewPath: string | null
  prProvider?: string
}>()

const emit = defineEmits<{
  'update:filter': [value: string]
  'pr-file-click': [event: MouseEvent, file: SplitDiffFile]
  'row-aux-click': [event: MouseEvent, path: string]
  'row-context-menu': [event: MouseEvent, path: string]
}>()

const forge = computed(() => forgeWording(props.prProvider))
const conflictPathSet = computed(() => new Set(props.prConflictFiles))
const visiblePrFiles = computed(() =>
  props.conflictsOnly
    ? props.prFiles.filter((f) => conflictPathSet.value.has(f.path))
    : props.prFiles,
)
const filteredPrFiles = computed(() => filterRows(visiblePrFiles.value, props.fileFilter))
const fileFilterActive = computed(() => isFilterActive(props.fileFilter))
const showPrFilter = computed(() => showsFilter(props.prFiles.length))
const prDiffCounts = computed(() => prDiffCountsOf(props.prFiles))
const preview = computed(() => previewFor(props.prFiles, props.previewPath))

const countsFor = (path: string): { added: number; removed: number } | null =>
  prCountsFor(prDiffCounts.value, path)

const setFilter = (value: string) => emit('update:filter', value)
const onPrFileRowClick = (event: MouseEvent, file: SplitDiffFile) =>
  emit('pr-file-click', event, file)
const onFileRowAuxClick = (event: MouseEvent, path: string) => emit('row-aux-click', event, path)
const onFileRowContextMenu = (event: MouseEvent, path: string) =>
  emit('row-context-menu', event, path)
</script>
<template>
          <div v-if="showPrFilter" class="px-2 pt-2">
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
                {{ prFiles.length }}
              </span>
            </label>
          </div>
          <div v-if="fileFilterActive && filteredPrFiles.length === 0" class="px-2 pt-2">
            <EmptyState
              class="m-0"
              glyph="⌕"
              title="No files match"
              :description="`Nothing in this ${forge.short} matches “${fileFilter.trim()}”.`"
            />
          </div>
          <div v-else class="py-1">
            <div
              class="flex items-center gap-1.5 px-3 h-7 text-micro font-semibold uppercase tracking-wide"
              style="color: var(--color-violet)"
            >
              {{ forge.short }} files ({{ filteredPrFiles.length
              }}<template v-if="conflictsOnly"> of {{ prFiles.length }}</template
              >)
            </div>
            <div v-for="file in filteredPrFiles" :key="'pr-' + file.path">
              <div
                role="button"
                tabindex="0"
                class="flex items-center gap-2 px-3 h-7 cursor-pointer hover:opacity-80"
                :style="{
                  backgroundColor:
                    selectedPath === file.path ? 'var(--semantic-active-bg)' : 'transparent',
                  boxShadow:
                    selectedPath === file.path ? 'inset 2px 0 0 0 var(--color-violet)' : 'none',
                }"
                :data-testid="`sidebar-pr-file-${file.path}`"
                :title="file.path"
                @click="onPrFileRowClick($event, file)"
                @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
                @auxclick="onFileRowAuxClick($event, file.path)"
              >
                <span
                  class="w-4 h-4 shrink-0 rounded flex items-center justify-center text-micro font-bold"
                  :style="{
                    backgroundColor: chipFor(file.status).bg,
                    color: chipFor(file.status).fg,
                  }"
                  :title="chipFor(file.status).title"
                  aria-hidden="true"
                  >{{ chipFor(file.status).letter }}</span
                >
                <span class="text-dense truncate flex-1 min-w-0" :title="file.path">
                  <span style="color: var(--semantic-text-dim)">{{ pathParts(file.path).dir }}</span
                  ><span style="color: var(--semantic-text)">{{ pathParts(file.path).name }}</span>
                </span>
                <DiffCounts
                  :added="countsFor(file.path)?.added ?? null"
                  :removed="countsFor(file.path)?.removed ?? null"
                />
              </div>
              <!-- The before/after of the file you clicked, under its own row. -->
              <div
                v-if="preview && previewPath === file.path"
                class="px-3 pb-2"
                data-testid="sidebar-pr-file-preview"
              >
                <div
                  class="rounded overflow-hidden font-mono"
                  style="
                    border: 1px solid var(--color-border);
                    background-color: var(--color-bg-m1);
                    font-size: var(--text-dense);
                    line-height: 16px;
                  "
                >
                  <div
                    v-for="line in preview.lines"
                    :key="line.key"
                    class="flex gap-1.5 px-1.5"
                    :style="{ backgroundColor: line.background }"
                    data-testid="sidebar-pr-file-preview-line"
                  >
                    <span class="shrink-0" :style="{ color: line.color }">{{ line.sign }}</span>
                    <span
                      class="min-w-0"
                      style="color: var(--semantic-text); white-space: pre-wrap; word-break: break-word"
                      >{{ line.content }}</span
                    >
                  </div>
                </div>
                <p
                  v-if="preview.hidden > 0"
                  class="text-micro mt-1 px-0.5"
                  style="color: var(--semantic-text-dim)"
                  data-testid="sidebar-pr-file-preview-more"
                >
                  … {{ preview.hidden }} more line{{ preview.hidden === 1 ? '' : 's' }} in this file
                </p>
              </div>
            </div>
          </div>
</template>
