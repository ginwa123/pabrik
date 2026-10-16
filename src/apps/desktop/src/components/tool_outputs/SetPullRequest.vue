<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { normalizeToolContent, parseSetPullRequest } from './_shared/toolOutputParser'
import ToolParameters from './_shared/ToolParameters.vue'
import { forgeWording } from '../../helpers/forgeWording'

/** `set_pull_request` result card — the sibling of `SetGitWorktree.vue`. Without this card the tool
 * fell into ChatView's generic fallback, where the collapsed pill printed the raw envelope data:
 * `set_pull_request ✓ {"session_id":"task_…","attached":true,"url":"https://…"}`. */
const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Threaded for
   *  uniformity with the other cards; the result carries everything shown. */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the error state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseSetPullRequest(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

const isRunning = computed(() => isEmptyContent(props.content))

// `pr_provider` is empty on every session predating GitLab support, so an
// empty provider is GitHub far more often than not — never render blank.
const forge = computed(() => forgeWording(parsed.value.provider ?? undefined))

// Header label: the change request's own id ("#922"), "(cleared)", or "error".
const headerLabel = computed(() => {
  if (parsed.value.cleared) return '(cleared)'
  if (!parsed.value.success) return 'error'
  if (parsed.value.number) return `#${parsed.value.number}`
  if (parsed.value.url) return parsed.value.url.replace(/\/+$/, '').split('/').slice(-2).join('/')
  return 'attached'
})

const providerLabel = computed(() => {
  const p = parsed.value.provider
  if (!p || p === 'generic') return p ?? ''
  return forge.value.forge.toLowerCase()
})

const handleToggle = (next: boolean) => {
  // always allow expansion so the user can see the full URL + refs
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success && !isRunning }"
    data-testid="set-pull-request"
  >
    <ToolCardHeader
      tool-name="set_pull_request"
      :primary="headerLabel"
      :primary-title="parsed.url ?? ''"
      :success="parsed.success"
      :right-meta="providerLabel || null"
      :expanded="isExpanded"
      :expandable="true"
      :show-copy="!!parsed.url"
      :show-open-in-editor="false"
      :running="isRunning"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <div
        v-if="parsed.url"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]"
          >{{ forge.label }}:</span
        >
        <a
          :href="parsed.url"
          target="_blank"
          rel="noopener noreferrer"
          class="whitespace-pre-wrap break-all text-[var(--color-violet)] hover:underline"
          :title="parsed.url"
          data-testid="set-pull-request-url"
          >{{ parsed.url }}</a
        >
      </div>

      <div
        v-if="parsed.provider"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Provider:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
          parsed.provider
        }}</span>
      </div>

      <div
        v-if="parsed.attached"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Verified:</span>
        <span
          class="whitespace-pre-wrap break-all"
          :class="parsed.verified ? 'text-[var(--semantic-text)]' : 'text-[var(--color-orange)]'"
          data-testid="set-pull-request-verified"
          >{{ parsed.verified ? 'yes' : 'no — bound without a forge CLI check' }}</span
        >
      </div>

      <div
        v-if="parsed.warning"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Warning:</span>
        <span
          class="whitespace-pre-wrap break-all text-[var(--color-orange)]"
          data-testid="set-pull-request-warning"
          >{{ parsed.warning }}</span
        >
      </div>

      <div
        v-if="parsed.base || parsed.head"
        class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Refs:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]"
          >{{ parsed.base ?? '?' }} ← {{ parsed.head ?? '?' }}</span
        >
      </div>

      <div v-if="parsed.sessionId" class="flex gap-2 px-2 py-1.5 text-dense">
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Session:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{
          parsed.sessionId
        }}</span>
      </div>

      <div
        v-if="parsed.cleared"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span>{{ forge.label }} binding removed from this session.</span>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
