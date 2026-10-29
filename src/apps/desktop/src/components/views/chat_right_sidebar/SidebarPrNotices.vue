<script setup lang="ts">
import { computed } from 'vue'
import { forgeWording } from '../../../helpers/forgeWording'
import { prStatusLabelOf } from './sidebarDiffPrView'
import { pathParts } from './sidebarDiffRows'

const props = defineProps<{
  hasPrConflict: boolean
  prConflictFiles: string[]
  prConflictsUrl: string
  prConflictLoaded: boolean
  prConflictError: string
  prConflictBase: string
  prConflictTruncated: boolean
  prConflictUnreproduced: boolean
  conflictsOnly: boolean
  prStatus: string
  prStatusError: string
  prTruncated: boolean
  selectedPath: string | null
  prProvider?: string
}>()

const emit = defineEmits<{
  'conflicts-only': [on: boolean]
  'conflict-file-click': [path: string]
  'row-context-menu': [event: MouseEvent, path: string]
}>()

const forge = computed(() => forgeWording(props.prProvider))
const prStatusLabel = computed(() => prStatusLabelOf(props.prStatus))

const setConflictsOnly = (on: boolean) => emit('conflicts-only', on)
const onConflictFileClick = (path: string) => emit('conflict-file-click', path)
const onFileRowContextMenu = (event: MouseEvent, path: string) =>
  emit('row-context-menu', event, path)
</script>
<template>
          <!-- Notices are one-line strips: glyph, truncated text (the full
               string stays in `title`), action on the right. Six stacked
               prose boxes became a tidy rail stack. -->
          <div
            v-if="hasPrConflict"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            :title="
              prConflictFiles.length > 0
                ? `This ${forge.noun} has merge conflicts in ${prConflictFiles.length} file(s)`
                : `This ${forge.noun} has merge conflicts that must be resolved`
            "
            data-testid="sidebar-pr-conflict-notice"
          >
            <span aria-hidden="true" style="color: var(--semantic-error)">⚠</span>
            <span class="flex-1 min-w-0 truncate"
              >This branch has conflicts that must be resolved. Use the</span
            >
            <a
              v-if="prConflictsUrl"
              :href="prConflictsUrl"
              target="_blank"
              rel="noopener"
              class="shrink-0 hover:underline"
              style="color: var(--semantic-link)"
              >web editor</a
            ><span v-else class="shrink-0" style="color: var(--semantic-link)">web editor</span>
          </div>
          <!-- Which files, not just "there is a conflict". Computed locally by
               `git merge-tree` over the same base ref the PR diff used, so it
               works for GitHub, GitLab and generic providers alike. Rendered
               only under the badge above, so a clean PR is byte-identical to
               before this feature existed. -->
          <div
            v-if="
              hasPrConflict && prConflictLoaded && !prConflictError && prConflictFiles.length > 0
            "
            data-testid="sidebar-pr-conflict-files"
          >
            <div class="flex items-center gap-2 px-3 pt-2 pb-1">
              <span
                class="text-micro font-semibold uppercase tracking-wide"
                style="color: var(--semantic-error)"
              >
                Conflicting files ({{ prConflictFiles.length }})
              </span>
              <button
                type="button"
                class="text-micro px-1.5 py-0.5 rounded-full shrink-0 hover:opacity-80"
                :style="
                  conflictsOnly
                    ? { backgroundColor: 'var(--color-violet)', color: 'var(--color-bg)' }
                    : { color: 'var(--semantic-text-dim)', backgroundColor: 'var(--color-bg-p1)' }
                "
                :aria-pressed="conflictsOnly"
                :title="conflictsOnly ? 'Show all changed files' : 'Show only conflicting files'"
                data-testid="sidebar-pr-conflicts-only"
                @click="setConflictsOnly(!conflictsOnly)"
              >
                ⚠ Conflicts only<span v-if="conflictsOnly"> ✓</span>
              </button>
            </div>
            <div
              v-for="path in prConflictFiles"
              :key="'pr-conflict-' + path"
              role="button"
              tabindex="0"
              class="flex items-center gap-2 px-3 h-7 cursor-pointer hover:opacity-80"
              :style="{
                backgroundColor:
                  selectedPath === path ? 'var(--semantic-active-bg)' : 'transparent',
                boxShadow: selectedPath === path ? 'inset 2px 0 0 0 var(--color-violet)' : 'none',
              }"
              :data-testid="`sidebar-pr-conflict-file-${path}`"
              :title="path"
              @click="onConflictFileClick(path)"
              @contextmenu.prevent="onFileRowContextMenu($event, path)"
            >
              <span
                class="w-4 h-4 shrink-0 rounded flex items-center justify-center text-micro font-bold"
                style="
                  background-color: color-mix(in srgb, var(--semantic-error) 18%, transparent);
                  color: var(--semantic-error);
                "
                aria-hidden="true"
                >⚠</span
              >
              <span class="text-dense truncate flex-1 min-w-0" :title="path">
                <span style="color: var(--semantic-text-dim)">{{ pathParts(path).dir }}</span
                ><span style="color: var(--semantic-text)">{{ pathParts(path).name }}</span>
              </span>
            </div>
            <div
              v-if="prConflictTruncated"
              class="px-3 py-1 text-micro"
              style="color: var(--semantic-text-dim)"
              data-testid="sidebar-pr-conflict-files-truncated"
            >
              List truncated — some conflicting files are not shown
            </div>
            <div
              v-if="prConflictBase"
              class="px-3 py-1 text-micro"
              style="color: var(--semantic-text-dim)"
              data-testid="sidebar-pr-conflict-base"
            >
              Computed from your local {{ prConflictBase }}
            </div>
          </div>
          <!-- Forge says CONFLICTING, our local merge says clean. Almost
               always a stale local base ref — say so instead of showing an
               empty list beside a red badge. -->
          <div
            v-if="prConflictUnreproduced"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            :title="`Could not reproduce these conflicts locally from ${prConflictBase}`"
            data-testid="sidebar-pr-conflict-unreproduced"
          >
            <span aria-hidden="true" style="color: var(--semantic-error)">⚠</span>
            <span class="flex-1 min-w-0 truncate"
              >Could not reproduce these conflicts locally<span v-if="prConflictBase">
                from {{ prConflictBase }}</span
              >. Run <code>git fetch</code> and refresh — the forge may be comparing against a newer
              base branch.</span
            >
          </div>
          <div
            v-else-if="hasPrConflict && prConflictError"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            :title="`Could not list conflicting files — ${prConflictError}`"
            data-testid="sidebar-pr-conflict-error"
          >
            <span aria-hidden="true" style="color: var(--semantic-error)">⚠</span>
            <span class="flex-1 min-w-0 truncate"
              >Could not list conflicting files — {{ prConflictError }}</span
            >
          </div>
          <div
            v-if="!prStatusLabel && prStatusError"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            :title="prStatusError"
            data-testid="sidebar-pr-status-error"
          >
            <span aria-hidden="true" style="color: var(--semantic-error)">⚠</span>
            <span class="flex-1 min-w-0 truncate"
              >{{ forge.short }} status unavailable — {{ prStatusError }}</span
            >
          </div>
          <div
            v-if="prStatus === 'merged'"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--color-violet) 15%, transparent);
              color: var(--semantic-text);
            "
            :title="`Merged — this ${forge.short} was merged on ${forge.forge}. The diff below is the final state.`"
            data-testid="sidebar-pr-merged-notice"
          >
            <span aria-hidden="true" style="color: var(--color-violet)">✓</span>
            <span class="flex-1 min-w-0 truncate"
              >Merged — this {{ forge.short }} was merged on {{ forge.forge }}. The diff below is
              the final state.</span
            >
          </div>
          <div
            v-else-if="prStatus === 'closed'"
            class="mx-2 mt-2 h-8 px-2 rounded-md flex items-center gap-2 text-dense shrink-0"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            :title="`Closed — this ${forge.short} was closed on ${forge.forge} without merging.`"
            data-testid="sidebar-pr-closed-notice"
          >
            <span aria-hidden="true" style="color: var(--semantic-error)">⊘</span>
            <span class="flex-1 min-w-0 truncate"
              >Closed — this {{ forge.short }} was closed on {{ forge.forge }} without
              merging.</span
            >
          </div>
          <div
            v-if="prTruncated"
            class="px-3 py-1 text-micro"
            style="color: var(--semantic-text-dim)"
          >
            Diff truncated at 1MB — showing first files
          </div>
</template>
