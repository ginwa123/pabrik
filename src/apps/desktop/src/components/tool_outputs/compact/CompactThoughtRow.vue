<script setup lang="ts">
/** CompactThoughtRow — the thought an agent had between two calls, as ONE line
 * inside the chain: a quiet marker and the first line of the reasoning. */
import { computed, ref } from 'vue'

const props = defineProps<{
  /** The reasoning, as the model wrote it. */
  text: string
}>()

const open = ref(false)

const firstLine = computed(() => {
  const line = props.text.split('\n').find((candidate) => candidate.trim() !== '') ?? ''
  return line.trim()
})

const lineCount = computed(() => props.text.split('\n').filter((l) => l.trim() !== '').length)

function toggle(): void {
  open.value = !open.value
}
</script>

<template>
  <div class="px-2 py-0.5" data-testid="compact-thought-row">
    <div
      class="flex items-center gap-2 cursor-pointer select-none rounded hover:bg-violet-500/5"
      role="button"
      tabindex="0"
      :aria-expanded="open"
      data-testid="compact-thought-head"
      @click="toggle"
      @keydown.enter.prevent="toggle"
      @keydown.space.prevent="toggle"
    >
      <span
        class="shrink-0 text-micro uppercase tracking-wider text-[var(--semantic-text-muted)]"
        data-testid="compact-thought-label"
        >thought</span
      >
      <span
        class="min-w-0 flex-1 truncate text-dense text-[var(--semantic-text-dim)]"
        :title="firstLine"
        data-testid="compact-thought-preview"
        >{{ firstLine }}</span
      >
      <span
        v-if="lineCount > 1"
        class="shrink-0 text-micro text-[var(--semantic-text-muted)]"
        data-testid="compact-thought-lines"
        >{{ lineCount }} lines</span
      >
      <span class="w-4 shrink-0 text-center text-body text-[var(--semantic-text-muted)]">{{
        open ? '−' : '+'
      }}</span>
    </div>
    <div
      v-if="open"
      class="mt-1 ml-2 whitespace-pre-wrap border-l-2 pl-3 text-dense leading-relaxed text-[var(--semantic-text-dim)]"
      style="border-color: var(--color-border)"
      data-testid="compact-thought-body"
    >
      {{ text }}
    </div>
  </div>
</template>
