<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'
import { normalizeToolContent } from '../tool_outputs/_shared/toolOutputParser'
import ToolParameters from '../tool_outputs/_shared/ToolParameters.vue'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const normalized = computed(() => normalizeToolContent(props.content))

const dataRecord = computed<Record<string, unknown>>(() => {
  const d = normalized.value.data
  if (typeof d === 'string') {
    const t = d.trim()
    if (t === '') return {}
    try {
      const p: unknown = JSON.parse(t)
      if (typeof p === 'object' && p !== null && !Array.isArray(p))
        return p as Record<string, unknown>
    } catch {
      // fall through
    }
    return {}
  }
  if (typeof d === 'object' && d !== null && !Array.isArray(d)) return d as Record<string, unknown>
  return {}
})

function strField(key: string): string {
  const v = dataRecord.value[key]
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

function strOrNull(key: string): string | null {
  const v = dataRecord.value[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

function boolField(key: string): boolean {
  const v = dataRecord.value[key]
  if (typeof v === 'boolean') return v
  if (typeof v === 'string') return v.trim() === 'true' || v.trim() === '1'
  if (typeof v === 'number') return v !== 0
  return false
}

// Skill name from the JSON payload
const skillName = computed(() => {
  const v = strOrNull('skill_name')
  return v && v.trim() !== '' ? v : null
})

// In-progress fallback: prefer payload, fall back to tool-call parameters. The call is `{ name }`,
// so `skill_name` is only present on a transcript recorded before that rename — reading it alone
// left every in-flight `use_skill` card reading "unknown" until the payload landed.
const displaySkillName = computed(
  () =>
    skillName.value ??
    extractParam(props.parameters, 'skill_name') ??
    extractParam(props.parameters, 'name'),
)
const isRunning = computed(
  () =>
    normalized.value.data === null &&
    normalized.value.error === null &&
    displaySkillName.value !== null,
)

// Loaded status from the JSON payload
const isLoaded = computed(() => boolField('loaded'))

// Error message: envelope error wins, then payload error
const errorMessage = computed(() => normalized.value.error ?? strOrNull('error'))

// Skill content from the JSON payload
const skillContent = computed(() => strField('content'))

// Available skills (when skill not found)
const availableSkills = computed((): string[] => {
  const v = dataRecord.value['available_skills']
  if (!Array.isArray(v)) return []
  return v.filter((s): s is string => typeof s === 'string' && s.trim() !== '')
})

// Has available skills list (skill not found)
const hasAvailableSkills = computed(() => availableSkills.value.length > 0)

// Status indicator
const statusIndicator = computed(() => (isLoaded.value ? '✓' : '✗'))

const toggle = () => {
  if (!isLoaded.value || errorMessage.value || hasAvailableSkills.value || skillContent.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copySkillName = async (e: Event) => {
  e.stopPropagation()
  if (displaySkillName.value) {
    await navigator.clipboard.writeText(displaySkillName.value)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !isLoaded }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{
        'cursor-default': isLoaded && !errorMessage && !hasAvailableSkills && !skillContent,
      }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">use_skill</span>
      <span
        class="flex-1 truncate text-left text-[var(--color-violet)] font-medium"
        :title="displaySkillName || ''"
      >
        {{ displaySkillName || 'unknown' }}
      </span>
      <span
        v-if="isRunning"
        data-testid="use-skill-running"
        class="text-micro text-yellow-500 animate-pulse"
        >running…</span
      >

      <!-- Status indicator -->
      <span class="text-dense font-semibold" :class="isLoaded ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Available skills count badge -->
      <span v-if="hasAvailableSkills" class="text-[var(--semantic-text-muted)] text-micro">
        {{ availableSkills.length }} available
      </span>

      <!-- Copy button -->
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
        @click="copySkillName"
        title="Copy skill name"
      >
        ⎘
      </button>

      <!-- Toggle indicator -->
      <span
        v-if="!isLoaded || errorMessage || hasAvailableSkills || skillContent"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-body"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <!-- Error message -->
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Available skills list -->
      <div
        v-if="hasAvailableSkills"
        class="py-1 border-b border-dashed border-[var(--color-border)]"
      >
        <div
          class="px-2 py-0.5 text-micro text-[var(--semantic-text-muted)] font-medium bg-black/[0.02]"
        >
          Available skills
        </div>
        <div class="px-2 py-1 flex flex-wrap gap-1">
          <span
            v-for="(skill, idx) in availableSkills"
            :key="idx"
            class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-micro"
          >
            {{ skill }}
          </span>
        </div>
      </div>

      <!-- Skill content -->
      <div v-if="skillContent" class="flex-1 min-h-0 flex flex-col overflow-hidden">
        <div
          class="px-2 py-0.5 text-micro text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] shrink-0"
        >
          Content
          <span class="ml-1">{{ skillContent.split('\n').length }}L</span>
        </div>
        <pre
          class="flex-1 p-2 m-0 whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-dense overflow-auto"
          >{{ skillContent }}</pre>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
