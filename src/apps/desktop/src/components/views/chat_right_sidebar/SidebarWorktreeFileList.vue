<script setup lang="ts">
import ListSkeleton from '../../shell/ListSkeleton.vue'
import SpinnerIcon from '../../shell/SpinnerIcon.vue'
import EmptyState from '../../pabrik/EmptyState.vue'

defineProps<{
  isLoadingGit: boolean
  changeCount: number
  gitError: string | null
  isGitRepo: boolean
  cwd: string
  displayBranch: string
}>()

const emit = defineEmits<{ retry: [] }>()

const loadGitStatus = () => emit('retry')
</script>
<template>
        <!-- First-load skeleton — holds the file list's height instead of
             collapsing the panel to one centered icon. On a REFRESH the
             previous rows stay visible (the flag is only set on the
             initial load), so a 30s PR-status poll no longer blanks the
             whole list. -->
        <ListSkeleton
          v-if="isLoadingGit && changeCount === 0"
          :rows="8"
          row-height="h-7"
          test-id="sidebar-diff-files-skeleton"
        />
        <div v-else-if="isLoadingGit" class="flex items-center justify-center py-8">
          <SpinnerIcon size-class="w-5 h-5" />
        </div>

        <div v-else-if="gitError" class="flex flex-col items-center justify-center p-4 text-center">
          <span class="text-title-lg mb-2" style="color: var(--semantic-error)" aria-hidden="true"
            >!</span
          >
          <p class="text-dense break-words" style="color: var(--semantic-error)">{{ gitError }}</p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-dense rounded-md"
            style="background: var(--color-green); color: var(--color-bg)"
            data-testid="sidebar-diff-retry"
            @click="loadGitStatus"
          >
            Retry
          </button>
        </div>

        <div v-else-if="!isGitRepo" class="px-2 py-4">
          <EmptyState
            class="m-0"
            glyph="⌗"
            :title="!cwd ? 'Select a workspace' : 'Not a git repository'"
            :description="
              !cwd
                ? 'Pick a workspace to see its git status.'
                : 'This folder is not a git repository, so there is nothing to diff.'
            "
          >
            <template #glyph>
              <svg
                class="w-7 h-7"
                style="color: var(--semantic-text-dim)"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path
                  d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
                />
              </svg>
            </template>
          </EmptyState>
        </div>

        <div v-else-if="changeCount === 0" class="px-2 py-4">
          <EmptyState
            class="m-0"
            glyph="✓"
            title="Working tree clean"
            :description="`Nothing staged, modified or untracked on ${displayBranch || 'this branch'}.`"
          />
        </div>

        <template v-else><slot /></template>
</template>
