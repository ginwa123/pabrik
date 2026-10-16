<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { extractSections } from '../../helpers/skillBody'
import {
  formatBytes,
  formatSkillCost,
  splitSkillEnvelope,
  type InvokedSkill,
} from '../../helpers/skillEnvelope'

/** How much of a body a row shows before "Show all" — enough to recognise the
 * skill, short enough that three invocations still fit on one screen. */
const PREVIEW_LINES = 12

const props = defineProps<{ content: string }>()

const split = computed(() => splitSkillEnvelope(props.content))
const open = ref(false)
const openRows = ref<number[]>([])
const fullRows = ref<number[]>([])
const copiedRow = ref<number | null>(null)
let copiedTimer: ReturnType<typeof setTimeout> | null = null

const totalLines = computed(() => split.value.skills.reduce((sum, skill) => sum + skill.lines, 0))

const toggleCard = () => {
  open.value = !open.value
}

const isRowOpen = (index: number) => openRows.value.includes(index)

const toggleRow = (index: number) => {
  openRows.value = isRowOpen(index)
    ? openRows.value.filter((n) => n !== index)
    : [...openRows.value, index]
}

const isFullRow = (index: number) => fullRows.value.includes(index)

const toggleFull = (index: number) => {
  fullRows.value = isFullRow(index)
    ? fullRows.value.filter((n) => n !== index)
    : [...fullRows.value, index]
}

const outlineOf = (skill: InvokedSkill) => extractSections(skill.body)

const previewOf = (skill: InvokedSkill, showFull: boolean): string => {
  if (showFull) return skill.body
  const lines = skill.body.split('\n')
  if (lines.length <= PREVIEW_LINES) return skill.body
  return `${lines.slice(0, PREVIEW_LINES).join('\n')}\n…`
}

const copyBody = async (skill: InvokedSkill, index: number) => {
  await navigator.clipboard.writeText(skill.body)
  copiedRow.value = index
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => {
    copiedRow.value = null
  }, 1500)
}

onUnmounted(() => {
  if (copiedTimer) clearTimeout(copiedTimer)
})
</script>

<template>
  <div class="skill-invocation-card" data-testid="skill-invocation-card">
    <!-- The parse can decline (a tag that is not a trailing envelope, a body
         carrying a closing tag); then the human's words render verbatim. -->
    <template v-if="split.hasEnvelope">
      <div v-if="split.text.trim() !== ''" class="sic-human" data-testid="sic-human">
        {{ split.text }}
      </div>
      <div class="sic-card">
        <div
          class="sic-head"
          role="button"
          tabindex="0"
          data-testid="sic-head"
          :aria-expanded="open"
          @click="toggleCard"
          @keydown.enter.prevent="toggleCard"
          @keydown.space.prevent="toggleCard"
        >
          <span class="sic-chev" aria-hidden="true">{{ open ? '▾' : '▸' }}</span>
          <UiIcon name="brain" size-class="w-3.5 h-3.5" />
          <span class="sic-title">Skills loaded for this turn</span>
          <span class="sic-badge sic-count" data-testid="sic-count"
            >{{ split.skills.length }} skill{{ split.skills.length === 1 ? '' : 's' }}</span
          >
          <span class="sic-badge sic-cost" data-testid="sic-cost">{{
            formatSkillCost(split.bytes)
          }}</span>
          <span class="sic-badge" data-testid="sic-lines"
            >{{ totalLines }} line{{ totalLines === 1 ? '' : 's' }}</span
          >
        </div>
        <div v-if="open" class="sic-body" data-testid="sic-body">
          <div
            v-for="(skill, index) in split.skills"
            :key="`${skill.name}-${index}`"
            class="sic-row"
            data-testid="sic-row"
          >
            <div
              class="sic-row-head"
              role="button"
              tabindex="0"
              data-testid="sic-row-head"
              :aria-expanded="isRowOpen(index)"
              @click="toggleRow(index)"
              @keydown.enter.prevent="toggleRow(index)"
              @keydown.space.prevent="toggleRow(index)"
            >
              <span class="sic-chev" aria-hidden="true">{{ isRowOpen(index) ? '▾' : '▸' }}</span>
              <span class="sic-name">{{ skill.name }}</span>
              <span class="sic-size">{{ formatBytes(skill.bytes) }} · {{ skill.lines }} ln</span>
            </div>
            <div v-if="isRowOpen(index)" class="sic-row-body" data-testid="sic-row-body">
              <div v-if="outlineOf(skill).length > 0" class="sic-outline" data-testid="sic-outline">
                <ul>
                  <li
                    v-for="section in outlineOf(skill)"
                    :key="`${section.line}-${section.title}`"
                    :class="`sic-depth-${section.depth}`"
                  >
                    {{ section.title }}
                  </li>
                </ul>
              </div>
              <pre class="sic-body-text" data-testid="sic-body-text">{{
                previewOf(skill, isFullRow(index))
              }}</pre>
              <div class="sic-actions">
                <button
                  v-if="skill.lines > PREVIEW_LINES"
                  type="button"
                  class="sic-btn"
                  data-testid="sic-show-all"
                  @click.stop="toggleFull(index)"
                >
                  {{ isFullRow(index) ? 'Show less' : `Show all ${skill.lines} lines` }}
                </button>
                <button
                  type="button"
                  class="sic-btn"
                  data-testid="sic-copy"
                  @click.stop="copyBody(skill, index)"
                >
                  {{ copiedRow === index ? 'Copied' : 'Copy body' }}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>
    <span v-else data-testid="sic-fallback">{{ content }}</span>
  </div>
</template>

<style scoped>
.skill-invocation-card {
  margin-top: 8px;
  white-space: normal;
  font-size: var(--text-dense);
}

.sic-human {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  font-size: var(--text-body);
  font-weight: 600;
}

.sic-card {
  margin-top: 6px;
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background-color: var(--semantic-card-bg);
  overflow: hidden;
}

.sic-head {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 6px 9px;
  cursor: pointer;
  user-select: none;
}

.sic-head:hover {
  background-color: var(--semantic-active-bg);
}

.sic-chev {
  width: 9px;
  font-size: var(--text-micro);
  color: var(--semantic-text-dim);
}

.sic-title {
  font-weight: 600;
  color: var(--semantic-text);
}

.sic-badge {
  margin-left: 0;
  padding: 1px 7px;
  border-radius: 999px;
  background-color: var(--semantic-active-bg);
  color: var(--semantic-text-dim);
  font-size: var(--text-micro);
  white-space: nowrap;
}

.sic-count {
  margin-left: auto;
}

.sic-cost {
  color: var(--color-yellow);
}

.sic-body {
  border-top: 1px solid var(--color-border);
  padding: 7px 8px;
}

.sic-row {
  border: 1px solid var(--color-border);
  border-radius: 7px;
  background-color: var(--color-bg);
  margin-bottom: 6px;
  overflow: hidden;
}

.sic-row:last-child {
  margin-bottom: 0;
}

.sic-row-head {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 5px 8px;
  cursor: pointer;
  user-select: none;
}

.sic-row-head:hover {
  background-color: var(--semantic-active-bg);
}

.sic-name {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color: var(--color-violet);
}

.sic-size {
  margin-left: auto;
  color: var(--semantic-text-dim);
  font-size: var(--text-micro);
  white-space: nowrap;
}

.sic-row-body {
  border-top: 1px dashed var(--color-border);
  padding: 7px 8px;
}

.sic-outline ul {
  margin: 0 0 6px;
  padding: 0;
  list-style: none;
  color: var(--semantic-text-dim);
  font-size: var(--text-micro);
}

.sic-outline li {
  padding: 1px 0;
}

.sic-depth-3 {
  padding-left: 12px;
}

.sic-body-text {
  margin: 0;
  max-height: 220px;
  overflow: auto;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  color: var(--semantic-text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: var(--text-micro);
}

.sic-actions {
  display: flex;
  gap: 6px;
  margin-top: 6px;
}

.sic-btn {
  padding: 2px 8px;
  border: 1px solid var(--color-border-light);
  border-radius: 6px;
  background-color: transparent;
  color: var(--semantic-text-dim);
  font-size: var(--text-micro);
  cursor: pointer;
}

.sic-btn:hover {
  color: var(--semantic-text);
}
</style>
