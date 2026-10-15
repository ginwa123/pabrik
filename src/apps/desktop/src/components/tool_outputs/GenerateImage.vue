<!--
  GenerateImage — tool output component for the `generate_image` agent tool.

  Renders the XML envelope produced by `execute_generate_image` in
  `src/modules/agent/tools/generate_image.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation. The
  actual image rendering happens in the NEXT tool call (`present_files`
  with `files=[{path=<image.path>}]`), which the agent
  invokes immediately after a successful generation. This card's job is
  just to show "what was generated" at-a-glance in the chat bubble —
  prompt + model + size + saved paths + (optional) revised_prompt.

  Two response shapes are possible:
    Success:
      <generate_image>
        <status>generated</status>
        <count>1</count>
        <model>dall-e-3</model>
        <size>1024x1024</size>
        <images>
          <image index="0" path="/cwd/.../img_xxx.png" bytes="12345" mime="image/png"/>
        </images>
        <revised_prompt>...</revised_prompt>   [DALL-E 3 / gpt-image-1 only]
      </generate_image>
    Error:
      <generate_image><error>HTTP 400: ...</error></generate_image>

  Header (always visible):
    `generate_image → <prompt (truncated)> · <model> <size> · <count>× ✓` (success)
    `generate_image → <error_message> ✗`                            (failure)

  Expanded body (click header to toggle):
    Success:
      - Per-image row: index + path (clickable copy) + bytes + mime
      - revised_prompt (if present) — shown verbatim so the user sees
        what OpenAI actually generated, not just what they asked for
    Error: red error block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (KanbanMove, Search, ReadFile): monospace, rounded-md, border + soft
  card bg, violet tool-name, ✗/✓ status indicators, expand/collapse `+`/`−`
  toggle on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import {
  normalizeToolContent,
  parseGenerateImage,
  type ParsedGenerateImage,
} from '@/components/tool_outputs/_shared/toolOutputParser'
import ToolParameters from './_shared/ToolParameters.vue'

const props = defineProps<{
  /** The inner `<data>` XML from the generate_image tool's `<tool>` envelope (already unwrapped by
   * the parent's `tryUnwrapToolOutput` pipeline). */
  /** Always XML — never JSON — because the backend's `wrapToolOutput` always wraps the impl's
   * `<generate_image>...</generate_image>` response verbatim. */
  content: unknown
  /**    * The JSON-stringified tool-call arguments (e.g. `'{"prompt":"a cat",...}'`). Used to display the
   * prompt in the header for at-a-glance context — the agent asked for "X" and the card shows "X"
   * without the user having to expand. */
  parameters?: string
  /** Whether the row is already expanded in the parent chat (the
   * "tool call loading placeholder" optimization — see AGENTS.md). */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ─── Inner-envelope parsing (typed) ─────────────────────────────────────── Pulled from the
// project-wide parser in `_shared/toolOutputParser.ts` so the same regexes don't drift between the
// parser test and the component. Always XML — never JSON.

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed<ParsedGenerateImage>(() => {
  const p = parseGenerateImage(normalized.value.data)
  if (normalized.value.error) {
    return { ...p, error: normalized.value.error }
  }
  return p
})

// ─── Parameter parsing (header context) ───────────────────────────────────

interface GenerateImageArgs {
  prompt?: string
  model?: string
  size?: string
  n?: number
}

const args = computed<GenerateImageArgs>(() => {
  try {
    const parsed = JSON.parse(props.parameters ?? '{}')
    if (parsed && typeof parsed === 'object') return parsed as GenerateImageArgs
  } catch {
    /* fall through — JSON.parse fails on XML-shaped legacy rows */
  }
  return {}
})

// ─── Derived display values ───────────────────────────────────────────────

const isSuccess = computed(() => parsed.value.error === null && parsed.value.status === 'generated')

const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

// Header label: parameter prompt (truncated) on success, "error" on failure. Fall back to the
// envelope's count + model when the prompt is missing (e.g. legacy row without parameters).
// When falling back, only show the `× count` suffix when count > 1 — mirrors `rightMeta` below so
// the header doesn't say "1× dall-e-3" when there's only one image.
const headerLabel = computed(() => {
  if (!isSuccess.value) return parsed.value.error ?? 'error'
  const prompt = args.value.prompt
  if (prompt && prompt.length > 0) {
    return prompt.length > 80 ? `${prompt.slice(0, 77)}…` : prompt
  }
  const count = parsed.value.count ?? 0
  const model = parsed.value.model ?? 'image'
  if (count > 1) return `${count}× ${model}`
  return model
})

// Right meta: "<model> <size> · <count>×" on success, nothing on failure.
const rightMeta = computed(() => {
  if (!isSuccess.value) return null
  const parts: string[] = []
  if (parsed.value.model) parts.push(parsed.value.model)
  if (parsed.value.size) parts.push(parsed.value.size)
  if (parsed.value.count !== null && parsed.value.count > 1) {
    parts.push(`${parsed.value.count}×`)
  }
  return parts.length > 0 ? parts.join(' ') : null
})

// Hover title: prompt + first image path so power users can see
// "what was asked" and "where it was saved" in one hover.
const headerTitle = computed(() => {
  if (!isSuccess.value) return parsed.value.error ?? ''
  const prompt = args.value.prompt ?? ''
  const firstPath = parsed.value.images[0]?.path ?? ''
  return firstPath ? `${prompt}\n→ ${firstPath}` : prompt
})

// ─── Event handlers ───────────────────────────────────────────────────────

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyPath = async (e: Event, path: string) => {
  e.stopPropagation()
  if (!path) return
  try {
    await navigator.clipboard.writeText(path)
  } catch {
    // ignore — clipboard may be blocked in jsdom tests / older browsers
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess }"
    :data-testid="`generate-image-card`"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">generate_image</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>

      <!-- Right meta -->
      <span v-if="rightMeta" class="text-[var(--semantic-text-muted)] text-dense">
        {{ rightMeta }}
      </span>

      <!-- Status indicator -->
      <span class="text-dense font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Success path: image rows + optional revised_prompt -->
      <template v-if="isSuccess">
        <!-- Per-image rows -->
        <div
          v-for="img in parsed.images"
          :key="img.path"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          :data-testid="`generate-image-row-${img.index}`"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">
            #{{ img.index }}
          </span>
          <span class="flex-1 truncate font-mono text-[var(--semantic-text)]" :title="img.path">
            {{ img.path }}
          </span>
          <span class="shrink-0 text-[var(--semantic-text-muted)]">
            {{ (img.bytes / 1024).toFixed(1) }} KB · {{ img.mime }}
          </span>
          <button
            class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
            title="Copy path"
            :data-testid="`generate-image-copy-${img.index}`"
            @click="(e) => copyPath(e, img.path)"
          >
            ⎘
          </button>
        </div>

        <!-- revised_prompt (DALL-E 3 / gpt-image-1 only) -->
        <div
          v-if="parsed.revisedPrompt"
          class="flex gap-2 px-2 py-1.5 text-dense"
          :data-testid="`generate-image-revised-prompt`"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">
            Revised prompt:
          </span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">
            {{ parsed.revisedPrompt }}
          </span>
        </div>
      </template>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
