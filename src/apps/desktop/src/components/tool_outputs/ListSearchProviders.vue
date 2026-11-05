<!--
  ListSearchProviders — tool output component for the
  `list_web_search_providers` agent tool.

  Renders the envelope produced by `execListWebSearchProviders`
  (`src/agentic_loop/tools_exec_list_web_search_providers.zig`):

    {"providers":[{"name":"tinyfish","url":"https://api.search.tinyfish.ai",
                   "description":"…","curl":"curl 'https://…?key={key}'"}]}

  The `curl` is a TEMPLATE (D14): it carries the literal text `{key}` where
  the credential belongs, and the backend stores it that way, so there is
  nothing secret in the listing and this card can show the template verbatim.
  The caption says so, because a user reading `{key}` in a card otherwise
  assumes something is missing.

  This is the discovery call the model makes before its first `web_search`;
  the card's job is to make the configured providers — and the exact curl to
  edit — readable at a glance.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseListWebSearchProviders } from './_shared/toolOutputParser'

const props = defineProps<{
  /** The tool row's payload — the inner `data`, or the full envelope on failure. */
  content: unknown
  /** The JSON-stringified tool-call arguments. The tool takes none, so usually `{}`. */
  parameters?: string
  /** Whether the row is already expanded in the parent chat. */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

const normalized = computed(() => normalizeToolContent(props.content))

const parsed = computed(() => parseListWebSearchProviders(normalized.value.data))

const providers = computed(() => parsed.value.providers)

const success = computed(() => normalized.value.error === null)

const errorText = computed(() => normalized.value.error)

const rightMeta = computed(() => {
  if (!success.value) return null
  const n = providers.value.length
  return n === 1 ? '1 provider' : `${n} providers`
})

const primary = computed(() => {
  if (!success.value) return errorText.value ?? 'error'
  const n = providers.value.length
  return n === 0 ? 'none configured' : `${n} configured`
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-[var(--tint-error-border)] opacity-90': !success }"
    data-testid="list-search-providers-card"
  >
    <ToolCardHeader
      tool-name="list_web_search_providers"
      :primary="primary"
      :success="success"
      :expanded="isExpanded"
      :expandable="true"
      :show-open-in-editor="false"
      :show-copy="false"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-[var(--semantic-wash)]">
      <div
        v-if="!success"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense border-b border-dashed border-[var(--color-border)]"
        data-testid="list-search-providers-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorText }}</span>
      </div>

      <div
        v-else-if="providers.length === 0"
        class="px-2 py-1.5 text-[var(--semantic-text-muted)] text-dense"
        data-testid="list-search-providers-empty"
      >
        No search providers are configured. Add one in Settings → Web Search.
      </div>

      <div
        v-for="provider in providers"
        :key="provider.name"
        class="flex flex-col gap-1 px-2 py-1.5 border-b border-dashed border-[var(--color-border)]"
        :data-testid="`search-provider-${provider.name}`"
      >
        <div class="flex gap-2 min-w-0">
          <span class="font-semibold text-[var(--color-violet)] shrink-0">{{ provider.name }}</span>
          <span class="truncate text-[var(--semantic-text-dim)]" :title="provider.url">{{
            provider.url
          }}</span>
        </div>
        <p
          v-if="provider.description"
          class="m-0 whitespace-pre-wrap break-words text-[var(--semantic-text)] text-dense"
          data-testid="search-provider-description"
        >
          {{ provider.description }}
        </p>
        <div class="flex flex-col gap-0.5">
          <span class="text-[var(--semantic-text-dim)] text-micro"
            >curl — put the key where {key} is</span
          >
          <pre
            class="p-1.5 m-0 whitespace-pre-wrap break-words max-w-full min-w-0 overflow-x-auto rounded-sm bg-[var(--semantic-wash)] text-[var(--semantic-text)] text-dense"
            data-testid="search-provider-curl"
            >{{ provider.curl }}</pre
          >
        </div>
      </div>

      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
