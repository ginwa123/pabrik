<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { normalizeToolContent, parseSetGitWorktree } from './_shared/toolOutputParser'
import ToolParameters from './_shared/ToolParameters.vue'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Accepted so the
   *  dispatcher can thread call args uniformly; the worktree result
   *  carries no "unknown" fallback that needs it today. */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseSetGitWorktree(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

// Running: result envelope is still empty (neither created nor cleared,
// no error yet).
const isRunning = computed(() => isEmptyContent(props.content))

const pathBasename = (p: string): string => {
  const parts = p.split('/').filter(Boolean)
  return parts.length > 0 ? (parts[parts.length - 1] ?? p) : p
}

// Header label: basename for SET, "(cleared)" for CLEAR, "error" otherwise
const headerLabel = computed(() => {
  if (parsed.value.cleared) return '(cleared)'
  if (parsed.value.path) return pathBasename(parsed.value.path)
  return 'error'
})

const handleToggle = (next: boolean) => {
  // always allow expansion so the user can see full path + branch
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-[var(--tint-error-border)] opacity-80': !parsed.success && !isRunning }"
    data-testid="set-git-worktree"
  >
    <ToolCardHeader
      tool-name="set_git_worktree"
      :primary="headerLabel"
      :primary-title="parsed.path ?? ''"
      :primary-class="'text-[var(--semantic-text-dim)]'"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :show-copy="!!parsed.path"
      :show-open-in-editor="false"
      :running="isRunning"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-[var(--semantic-wash)] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <div
        v-if="parsed.path"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--color-violet)]" :title="parsed.path">{{ parsed.path }}</span>
      </div>

      <div
        v-if="parsed.branch"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Branch:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)] font-mono">{{ parsed.branch }}</span>
      </div>

      <div
        v-if="parsed.cleared"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-dense"
      >
        <span>Worktree binding removed and directory deleted.</span>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>