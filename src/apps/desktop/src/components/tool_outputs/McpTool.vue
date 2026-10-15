<!--
  McpTool — universal renderer for ANY `mcp_*` agent tool.

  The registry name is `mcp_<server>_<tool>` (see
  `prompts_build_messages_for_agent_prompt.zig::convertMcpToolsToAgentTools`):
  e.g. `mcp_graphify_graph_stats`, `mcp_db_query`. One component serves all
  servers — no per-server card needed.

  Backend wire shape (`handle_tool.zig`):
    success: RAW server text (NOT a `<tool>` envelope) — e.g. plain text or JSON.
    failure: `wrapToolOutput(..., success=false, err, "")` envelope.
  `ChatView.innerToolData` passes the inner `<data>` on envelope success and
  falls back to full content otherwise, so this component receives EITHER the
  raw output OR a full error envelope. `parseMcp` tolerates both (see
  `toolOutputParser.ts`).

  Header (always visible, via ToolCardHeader):
    `mcp_graphify_graph_stats → graphify · graph_stats · 3L ✓`
    `mcp_db_query → error ✗` (failure)

  Expanded body (click header to toggle):
    Success: `<pre>` with JSON-pretty output when parseable, else raw text.
    Failure: red error block.
    Non-empty JSON args render via shared ToolParameters below the output.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseMcp } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  toolName: string
  parameters?: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  // MCP results are raw server text on success (not a JSON envelope), so strings pass through
  // verbatim — only JSON-envelope strings/objects go through the normalizer. `parseMcp` handles raw
  // text, bare data objects, and full envelope objects.
  const c = props.content
  let input: unknown = c
  if (typeof c === 'string') {
    const t = c.trim()
    if (t.startsWith('{')) {
      try {
        const p: unknown = JSON.parse(t)
        if (typeof p === 'object' && p !== null) input = p
      } catch {
        input = c
      }
    }
  } else {
    input = normalized.value.data
  }
  const p = parseMcp(props.toolName, input)
  if (typeof input === 'object' && input !== null && normalized.value.error) {
    return { ...p, success: false, error: normalized.value.error }
  }
  return p
})

const primary = computed(() => {
  const { server, subTool } = parsed.value
  if (server && subTool) return `${server} · ${subTool}`
  if (subTool) return subTool
  if (server) return server
  return props.toolName
})

const rightMeta = computed(() => {
  if (!parsed.value.success) return 'Error'
  const lines = parsed.value.lineCount
  return `${lines}L`
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
  >
    <ToolCardHeader
      :tool-name="props.toolName"
      :primary="primary"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :show-open-in-editor="false"
      :copy-value="parsed.prettyOutput"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="!parsed.success" class="flex gap-2 px-2 py-1.5 text-red-500 text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error || 'unknown error' }}</span>
      </div>
      <pre
        v-else
        class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-violet-500/5"
        data-testid="mcp-tool-output"
        >{{ parsed.prettyOutput || '(empty)' }}</pre>
      <ToolParameters :parameters="props.parameters" />
    </div>
  </div>
</template>
