<script setup lang="ts">
import { computed } from 'vue'
import { forgeWording } from '../../../helpers/forgeWording'
import ListSkeleton from '../../shell/ListSkeleton.vue'
import SpinnerIcon from '../../shell/SpinnerIcon.vue'
import EmptyState from '../../pabrik/EmptyState.vue'
import ForgeIcon from '../../git/ForgeIcon.vue'
import type { SplitDiffFile } from './parseUnifiedDiff'

const props = defineProps<{
  isLoadingPr: boolean
  prFiles: SplitDiffFile[]
  prError: string | null
  prStatusError: string
  prProvider?: string
}>()

const emit = defineEmits<{ retry: [] }>()

const forge = computed(() => forgeWording(props.prProvider))
const retryPr = () => emit('retry')
</script>
<template>
        <!-- First-load skeleton holds the file list's height; a centered
             spinner on a refresh, where the previous rows are on screen. -->
        <ListSkeleton
          v-if="isLoadingPr && prFiles.length === 0"
          :rows="8"
          row-height="h-7"
          test-id="sidebar-pr-files-skeleton"
        />
        <div v-else-if="isLoadingPr" class="flex items-center justify-center py-8">
          <SpinnerIcon size-class="w-5 h-5" />
        </div>
        <!-- The error states stay bespoke rather than going through
             EmptyState: each carries a testid on the element that holds the
             server's own words, and EmptyState owns neither its heading nor
             its CTA button. -->
        <div v-else-if="prError" class="flex flex-col items-center justify-center p-4 text-center">
          <span class="text-title-lg mb-2" style="color: var(--semantic-error)" aria-hidden="true"
            >!</span
          >
          <p
            class="text-dense break-words"
            style="color: var(--semantic-error); white-space: pre-wrap"
            data-testid="sidebar-pr-error"
          >
            {{ prError }}
          </p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-dense rounded-md"
            style="background: var(--color-green); color: var(--color-bg)"
            data-testid="sidebar-pr-retry"
            @click="retryPr"
          >
            Retry
          </button>
        </div>
        <template v-else-if="prFiles.length === 0">
          <EmptyState
            class="m-2"
            glyph="⌗"
            :title="`No ${forge.short} changes found`"
            :description="`This ${forge.noun} on ${forge.forge} has no file changes to show.`"
          >
            <template #glyph>
              <ForgeIcon :provider="prProvider" size-class="w-7 h-7" />
            </template>
          </EmptyState>
          <p
            v-if="prStatusError"
            class="mx-2 mt-2 px-2 py-1.5 rounded-md text-dense break-words"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-error);
              white-space: pre-wrap;
            "
            :title="prStatusError"
            data-testid="sidebar-pr-status-error"
          >
            {{ forge.short }} status unavailable — {{ prStatusError }}
          </p>
        </template>
        <template v-else><slot /></template>
</template>
