<script setup lang="ts">
import { computed } from 'vue'
import { highlightLinesForFile, type Token } from '@/helpers/codeHighlight'
import type { SplitRow } from './pairSplitRows'

/**
 * The side-by-side (split) render of a parsed unified diff.
 *
 * Five columns: `old# · old code │ new# · new code`. A row that exists on
 * only one side (`oldText === null` or `newText === null`) renders the other
 * side as a striped FILLER cell — an empty box, never a duplicated line, so a
 * pure insertion cannot be mistaken for an unchanged line.
 *
 * Presentational: rows in, clicks out. The review-thread rows are NOT owned
 * here — the parent renders them through the `threads` scoped slot so the
 * thread markup (mini-chat, edit/delete) has exactly one home.
 */
const props = defineProps<{
  rows: SplitRow[]
  /** Path of the file under review — drives the token language. */
  path: string
}>()

// Token spans per side, computed once per diff rather than once per render.
// A side that has no line here (`null`) tokenizes to a single empty plain
// token, which the filler cell never renders (see the `v-if`s below).
const tokensForSide = (pick: (row: SplitRow) => string | null): Token[][] =>
  highlightLinesForFile(
    props.rows.map((row) => pick(row) ?? ''),
    props.path,
  )

const oldTokens = computed(() => tokensForSide((row) => row.oldText))
const newTokens = computed(() => tokensForSide((row) => row.newText))

const emit = defineEmits<{
  /** A change line was clicked. `sourceIndex` indexes the caller's parsed
   * `ParsedDiffLine[]`, which is what a review thread anchors to. */
  comment: [payload: { event: MouseEvent; sourceIndex: number }]
}>()

const onRowClick = (event: MouseEvent, row: SplitRow) => {
  // Mirrors the unified table: only changed lines are comment targets.
  if (!row.isChanged) return
  const first = row.sourceIndexes[0]
  if (first === undefined) return
  emit('comment', { event, sourceIndex: first })
}
</script>

<template>
  <div data-testid="sidebar-diff-split">
    <div class="split-heads">
      <div>Before (old)</div>
      <div>After (new)</div>
    </div>
    <table class="split-table">
      <colgroup>
        <col style="width: 42px" />
        <col />
        <col style="width: 1px" />
        <col style="width: 42px" />
        <col />
      </colgroup>
      <tbody>
        <template v-for="(row, idx) in props.rows" :key="idx">
          <tr v-if="row.kind === 'hunk'" class="split-hunk">
            <td colspan="5" data-testid="split-hunk">{{ row.text ?? '' }}</td>
          </tr>
          <tr
            v-else
            :data-row="idx"
            :data-changed="row.isChanged ? 'true' : 'false'"
            :style="row.isChanged ? { cursor: 'pointer' } : {}"
            @click="onRowClick($event, row)"
          >
            <!-- old side -->
            <td
              class="split-ln"
              :class="{ 'split-blank': row.oldText === null }"
              :style="
                row.isChanged && row.oldText !== null
                  ? { background: 'color-mix(in srgb, var(--color-red) 15%, transparent)' }
                  : {}
              "
            >
              {{ row.oldLineNum ?? '' }}
            </td>
            <td
              class="split-code"
              :class="{ 'split-blank': row.oldText === null }"
              :style="
                row.isChanged && row.oldText !== null
                  ? {
                      background: 'color-mix(in srgb, var(--color-red) 15%, transparent)',
                      borderLeft: '3px solid var(--color-red)',
                    }
                  : {}
              "
              :data-side="'old'"
            >
              <span v-if="row.isChanged && row.oldText !== null" class="split-sign remove">−</span>
              <template v-if="row.oldText !== null">
                <span
                  v-for="(tok, tIdx) in oldTokens[idx]"
                  :key="tIdx"
                  :class="`tok-${tok.type}`"
                  >{{ tok.text || '\u00a0' }}</span
                >
              </template>
            </td>
            <td class="split-sep"></td>
            <!-- new side -->
            <td
              class="split-ln"
              :class="{ 'split-blank': row.newText === null }"
              :style="
                row.isChanged && row.newText !== null
                  ? { background: 'color-mix(in srgb, var(--color-green) 15%, transparent)' }
                  : {}
              "
            >
              {{ row.newLineNum ?? '' }}
            </td>
            <td
              class="split-code"
              :class="{ 'split-blank': row.newText === null }"
              :style="
                row.isChanged && row.newText !== null
                  ? {
                      background: 'color-mix(in srgb, var(--color-green) 15%, transparent)',
                      borderLeft: '3px solid var(--color-green)',
                    }
                  : {}
              "
              :data-side="'new'"
            >
              <span v-if="row.isChanged && row.newText !== null" class="split-sign add">+</span>
              <template v-if="row.newText !== null">
                <span
                  v-for="(tok, tIdx) in newTokens[idx]"
                  :key="tIdx"
                  :class="`tok-${tok.type}`"
                  >{{ tok.text || '\u00a0' }}</span
                >
              </template>
            </td>
          </tr>
          <slot name="threads" :row-index="idx" />
        </template>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
/*
 * `table-layout: fixed` + an explicit <colgroup> is deliberate. A first row
 * with `colspan="5"` (the hunk header) otherwise defines the column widths
 * under `table-layout: fixed`, and every column — including the two 42px
 * gutters — ends up 1/5 of the table. The colgroup wins over the first row.
 */
.split-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-size: var(--text-dense);
  line-height: 20px;
  color: var(--semantic-text);
}
.split-heads {
  display: flex;
  border-bottom: 1px solid var(--color-border);
  background: var(--color-bg-p1);
}
.split-heads div {
  flex: 1 1 0;
  min-width: 0;
  padding: 2px 8px;
  font-size: var(--text-micro);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-weight: 600;
  color: var(--color-red);
}
.split-heads div:last-child {
  color: var(--color-green);
  border-left: 1px solid var(--color-border);
}
.split-hunk td {
  padding: 2px 8px;
  background: rgba(139, 164, 176, 0.1);
  color: var(--color-blue);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
.split-ln {
  padding: 0 8px;
  text-align: right;
  color: var(--semantic-text-dim);
  user-select: none;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  vertical-align: top;
}
.split-code {
  padding: 0 8px 0 6px;
  vertical-align: top;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  color: var(--semantic-text);
}
.split-sep {
  padding: 0;
  background: var(--color-border);
}
/* A side with no line here: striped, so it never reads as "an unchanged line". */
.split-blank {
  background: repeating-linear-gradient(
    135deg,
    transparent 0 5px,
    rgba(255, 255, 255, 0.022) 5px 10px
  );
}
.split-sign {
  font-weight: bold;
  margin-right: 2px;
}
.split-sign.remove {
  color: var(--color-red);
}
.split-sign.add {
  color: var(--color-green);
}
</style>
