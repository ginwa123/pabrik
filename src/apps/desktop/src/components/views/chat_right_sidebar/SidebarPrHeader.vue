<script setup lang="ts">
import { computed } from 'vue'
import type { GitPrStatus } from '../../../api'
import { forgeWording } from '../../../helpers/forgeWording'
import ForgeIcon from '../../git/ForgeIcon.vue'
import type { SplitDiffFile } from './parseUnifiedDiff'
import type { PanelTab } from './sidebarDiffUrl'
import {
  failedChecksOf,
  prAuthorOf,
  prBaseRefOf,
  prHeadRefOf,
  prStatusLabelOf,
  prStatusStyleOf,
  prTitleOf,
  reviewChipOf,
} from './sidebarDiffPrView'

const props = defineProps<{
  prUrl?: string
  prProvider?: string
  prLabel: string
  prStatus: string
  prStatusTitle: string
  prStatusData: GitPrStatus | null
  hasPrConflict: boolean
  prConflictFiles: string[]
  prFiles: SplitDiffFile[]
  prBase: string
  prHead: string
}>()

const emit = defineEmits<{ select: [tab: PanelTab] }>()

const setActiveTab = (tab: PanelTab) => emit('select', tab)

const forge = computed(() => forgeWording(props.prProvider))
const prStatusLabel = computed(() => prStatusLabelOf(props.prStatus))
const prStatusStyle = computed(() => prStatusStyleOf(props.prStatus))
const prTitle = computed(() => prTitleOf(props.prStatusData, props.prStatusTitle))
const prAuthor = computed(() => prAuthorOf(props.prStatusData))
const prHeadRef = computed(() => prHeadRefOf(props.prStatusData, props.prHead))
const prBaseRef = computed(() => prBaseRefOf(props.prStatusData, props.prBase))
const failedChecksCount = computed(() => failedChecksOf(props.prStatusData))
const reviewChip = computed(() => reviewChipOf(props.prStatusData))
</script>
<template>
    <div
      class="px-3 py-2 shrink-0"
      style="background-color: var(--color-bg-m1); border-bottom: 1px solid var(--color-border)"
      data-testid="sidebar-pr-header"
    >
      <div class="flex items-center gap-2 min-w-0">
        <ForgeIcon
          :provider="prProvider"
          class="shrink-0"
          style="color: var(--semantic-text-dim)"
          :title="`${forge.forge} ${forge.noun}`"
          data-testid="sidebar-pr-forge-icon"
        />
        <a
          :href="prUrl"
          target="_blank"
          rel="noopener"
          class="font-mono text-dense font-semibold truncate hover:underline"
          style="color: var(--semantic-text)"
          :title="prUrl"
          data-testid="sidebar-pr-link"
        >
          {{ prLabel }}
        </a>
        <span
          v-if="prStatusLabel"
          class="px-1.5 rounded-full text-micro font-semibold shrink-0"
          :style="prStatusStyle"
          :title="prStatusTitle || prStatusLabel"
          data-testid="sidebar-pr-status"
        >
          {{ prStatusLabel }}
        </span>
        <span
          v-if="hasPrConflict"
          class="px-1.5 rounded-full text-micro font-semibold shrink-0"
          style="background-color: var(--semantic-error); color: var(--color-bg)"
          :title="
            prConflictFiles.length > 0
              ? `This ${forge.noun} has merge conflicts in ${prConflictFiles.length} file(s)`
              : `This ${forge.noun} has merge conflicts that must be resolved`
          "
          data-testid="sidebar-pr-conflict-badge"
        >
          ⚠ Merge conflicts<span v-if="prConflictFiles.length > 0">
            ({{ prConflictFiles.length }})</span
          >
        </span>
        <span
          v-if="prFiles.length > 0"
          class="ml-auto shrink-0 px-1.5 rounded-full text-micro font-semibold"
          style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
          data-testid="sidebar-pr-count"
        >
          {{ prFiles.length }}
        </span>
      </div>
      <div
        v-if="prTitle"
        class="mt-1 text-dense font-semibold leading-snug"
        style="
          color: var(--semantic-text);
          display: -webkit-box;
          -webkit-line-clamp: 2;
          -webkit-box-orient: vertical;
          overflow: hidden;
        "
        :title="prTitle"
        data-testid="sidebar-pr-title"
      >
        {{ prTitle }}
      </div>
      <div
        v-if="prAuthor || prBaseRef || prHeadRef"
        class="mt-0.5 text-micro truncate"
        style="color: var(--semantic-text-dim)"
        :title="`${prBaseRef}…${prHeadRef}`"
        data-testid="sidebar-pr-refs"
      >
        <template v-if="prAuthor">{{ prAuthor }} · </template>{{ prBaseRef }}…{{ prHeadRef }}
      </div>
      <div
        v-if="failedChecksCount > 0 || reviewChip"
        class="mt-1.5 flex items-center gap-1.5 flex-wrap"
        data-testid="sidebar-pr-chips"
      >
        <button
          v-if="failedChecksCount > 0"
          type="button"
          class="px-1.5 rounded text-micro font-semibold"
          style="
            background-color: color-mix(in srgb, var(--semantic-error) 16%, transparent);
            color: var(--semantic-error);
          "
          :title="`${failedChecksCount} CI check(s) failed`"
          data-testid="sidebar-pr-chip-checks"
          @click="setActiveTab('checks')"
        >
          {{ failedChecksCount }} check{{ failedChecksCount === 1 ? '' : 's' }} failed ›
        </button>
        <button
          v-if="reviewChip"
          type="button"
          class="px-1.5 rounded text-micro font-semibold"
          style="
            background-color: color-mix(in srgb, var(--color-yellow) 16%, transparent);
            color: var(--color-yellow);
          "
          :title="reviewChip.title"
          data-testid="sidebar-pr-chip-review"
          @click="setActiveTab('conversation')"
        >
          {{ reviewChip.label }} ›
        </button>
      </div>
    </div>
</template>
