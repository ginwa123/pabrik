<script setup lang="ts">
import { computed } from 'vue'
import { highlightLinesForFile } from '@/helpers/codeHighlight'
import type { DiffMode } from '@/stores/diffModePreference'
import { pairSplitRows } from './chat_right_sidebar/pairSplitRows'
import SplitDiffTable from './chat_right_sidebar/SplitDiffTable.vue'
import type { ParsedDiffLine } from './chat_right_sidebar/parseUnifiedDiff'

const props = defineProps<{
  lines: ParsedDiffLine[]
  /** The file under change — decides the token language and the split table's grammar. */
  path: string
  mode: DiffMode
}>()

const splitRows = computed(() => pairSplitRows(props.lines))

/** One token row per rendered line, computed once per diff rather than once per render. A hunk
 * header is diff metadata, not code — tokenizing `@@ -1,2 +1,2 @@` would paint its numbers over the
 * row's own hunk colour, so it stays plain like every other unified surface. */
const unifiedTokens = computed(() => {
  const tokens = highlightLinesForFile(
    props.lines.map((line) => line.content),
    props.path,
  )
  return props.lines.map((line, i) =>
    line.type === 'hunk' ? [{ text: line.content, type: 'plain' }] : tokens[i]!,
  )
})

const signFor = (type: string): string => {
  if (type === 'add') return '+'
  if (type === 'remove') return '-'
  if (type === 'context' || type === 'empty') return ' '
  return ''
}

const rowClass = (type: string): string => {
  if (type === 'add') return 'diff-row-add'
  if (type === 'remove') return 'diff-row-remove'
  if (type === 'hunk') return 'diff-row-hunk'
  return ''
}
</script>

<template>
  <SplitDiffTable v-if="mode === 'split'" :rows="splitRows" :path="path" />
  <div
    v-else
    data-testid="code-diff-view"
    class="diff-view"
    style="font-size: var(--text-dense); line-height: 20px"
  >
    <div v-for="(line, idx) in lines" :key="idx" class="diff-row" :class="rowClass(line.type)">
      <span class="diff-old">{{ line.oldLineNum ?? '' }}</span>
      <span class="diff-new">{{ line.newLineNum ?? '' }}</span>
      <span class="diff-text"
        >{{ signFor(line.type)
        }}<span
          v-for="(token, tIdx) in unifiedTokens[idx]"
          :key="tIdx"
          :class="`tok-${token.type}`"
          >{{ token.text || '\u00a0' }}</span
        ></span
      >
    </div>
  </div>
</template>

<style scoped>
.diff-view {
  white-space: pre-wrap;
  word-break: break-word;
  /* The code view gets its colour from `td.code-content`; the Diff view has no such cell, so the
     row colour is set here — `.tok-plain` inherits it instead of falling back to the initial value. */
  color: var(--semantic-text);
}
.diff-row {
  display: flex;
  gap: 8px;
  padding: 0 12px 0 0;
}
.diff-old,
.diff-new {
  width: 3rem;
  flex-shrink: 0;
  text-align: right;
  color: var(--semantic-text-dim);
  opacity: 0.55;
  user-select: none;
}
/* `--tint-success` is a 5% wash — too faint to read as "this line was added" next to a syntax
   palette. The diff rows carry their own, stronger tint; SplitDiffTable uses the same values so the
   two layouts agree. */
.diff-row-add {
  background-color: color-mix(in srgb, var(--color-green) 18%, transparent);
}
.diff-row-remove {
  background-color: color-mix(in srgb, var(--color-red) 18%, transparent);
}
.diff-row-hunk {
  color: var(--color-blue);
  background-color: var(--tint-info);
}
</style>
