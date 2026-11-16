<!--
  ToolParameters — shared Arguments block for tool-output cards.

  Extracted from McpTool.vue (hasArgs/prettyArgs + Arguments details markup)
  so every tool card renders parameters identically. Guard: trim in '',
  '{}' -> render nothing. pretty: try JSON.parse -> stringify null,2,
  else raw string (XML params display raw, matching McpTool behavior).

  `exclude` optionally hides noisy keys (e.g. text_replace's old_str/new_str
  which are already visualized as a DiffView). Filtering applies only when
  parameters parse as a JSON object; raw/XML payloads pass through untouched.
-->
<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  parameters?: string
  exclude?: string[]
}>()

// Strip excluded keys so cards that already visualize a param (diff, file content) don't repeat the same huge blob as raw JSON in Arguments.
const filtered = computed(() => {
  const p = (props.parameters ?? '').trim()
  if (!p) return ''
  const exclude = props.exclude ?? []
  if (exclude.length === 0) return p
  try {
    const obj = JSON.parse(p) as unknown
    if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) return p
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      if (!exclude.includes(k)) out[k] = v
    }
    return JSON.stringify(out)
  } catch {
    return p
  }
})

const hasArgs = computed(() => {
  const p = filtered.value.trim()
  return p !== '' && p !== '{}'
})

const pretty = computed(() => {
  const p = filtered.value.trim()
  if (!p) return ''
  try {
    return JSON.stringify(JSON.parse(p), null, 2)
  } catch {
    return p
  }
})
</script>

<template>
  <details v-if="hasArgs" class="px-2 py-1.5 border-t border-[var(--color-border)]">
    <summary
      class="cursor-pointer select-none text-[var(--semantic-text-dim)] hover:opacity-100 opacity-70"
    >
      Arguments
    </summary>
    <pre
      class="mt-1 p-2 m-0 whitespace-pre-wrap break-words max-w-full min-w-0 overflow-x-auto text-[var(--semantic-text-dim)] text-dense"
      >{{ pretty }}</pre>
  </details>
</template>
