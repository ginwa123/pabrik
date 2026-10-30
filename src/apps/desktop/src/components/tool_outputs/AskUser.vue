<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import { renderMarkdownHtml, stripMarkdownSyntax } from '../../helpers/markdown'
import { type AskUserQuestion } from '../../helpers/askUserBlock'
import { answerAskUser } from '../../api'

interface Props {
  question: AskUserQuestion
  messageId: string
  sessionId?: string
}

const props = defineProps<Props>()

type ViewState = 'pending' | 'answered' | 'skipped' | 'abandoned' | 'settled'

const submitting = ref(false)
const sendFailed = ref(false)
const locallyResolved = ref<ViewState | null>(null)
const locallyAnswered = ref('')

const selected = ref<string[]>([])
const freeText = ref('')
const usingFreeText = ref(false)

const state = computed<ViewState>(() => locallyResolved.value ?? props.question.status)
const options = computed(() => props.question.options)
const multiSelect = computed(() => props.question.multiSelect)

function parseAnswers(raw: string): string[] {
  const trimmed = (raw ?? '').trim()
  if (trimmed.length === 0) return []
  if (trimmed.startsWith('[')) {
    try {
      const arr = JSON.parse(trimmed)
      if (Array.isArray(arr)) return arr.map((v) => String(v))
    } catch {
      /* a bracket-prefixed plain answer is still one answer */
    }
  }
  return [trimmed]
}

const answers = computed<string[]>(() =>
  parseAnswers(locallyAnswered.value || props.question.answer),
)

const answerIsFreeText = computed(
  () => freeText.value.trim().length > 0 && (usingFreeText.value || selected.value.length === 0),
)

const canSend = computed(() => {
  if (state.value !== 'pending' || submitting.value) return false
  if (options.value.length === 0) return freeText.value.trim().length > 0
  return selected.value.length > 0 || answerIsFreeText.value
})

function toggleOption(option: string): void {
  if (state.value !== 'pending' || submitting.value) return
  usingFreeText.value = false
  if (multiSelect.value) {
    selected.value = selected.value.includes(option)
      ? selected.value.filter((v) => v !== option)
      : [...selected.value, option]
  } else {
    selected.value = [option]
  }
}

function chooseFreeText(): void {
  usingFreeText.value = true
  selected.value = []
}

const FREETEXT_MAX_PX = 220

function autoGrow(event: Event): void {
  const el = event.target as HTMLTextAreaElement | null
  if (!el) return
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, FREETEXT_MAX_PX)}px`
}

function onFreeTextInput(event: Event): void {
  usingFreeText.value = true
  autoGrow(event)
}

function buildBody(skip: boolean): Record<string, unknown> {
  const body: Record<string, unknown> = { message_id: props.messageId }
  if (skip) {
    body.skip = true
    return body
  }
  if (answerIsFreeText.value) {
    body.answer = freeText.value.trim()
  } else if (multiSelect.value) {
    body.answer = JSON.stringify(selected.value)
  } else {
    body.answer = selected.value[0] ?? ''
  }
  return body
}

async function submit(skip: boolean): Promise<void> {
  if (state.value !== 'pending' || submitting.value) return
  if (!skip && !canSend.value) return

  const sessionId = props.sessionId
  if (!sessionId) {
    sendFailed.value = true
    return
  }

  submitting.value = true
  sendFailed.value = false
  const body = buildBody(skip)
  const res = await answerAskUser(sessionId, body)
  submitting.value = false

  if (!res.success) {
    sendFailed.value = true
    return
  }

  const nextState = (res.status as ViewState) ?? (skip ? 'skipped' : 'answered')
  locallyResolved.value = nextState === 'pending' ? null : nextState
  if (!skip) locallyAnswered.value = String(body.answer ?? '')
  window.removeEventListener('keydown', onKeydown)
}

function onKeydown(event: KeyboardEvent): void {
  if (state.value !== 'pending' || submitting.value) return
  const target = event.target as HTMLElement | null
  if (target && (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT')) return

  if (event.key === 'Enter') {
    event.preventDefault()
    void submit(false)
    return
  }
  if (event.key === 'Escape') {
    event.preventDefault()
    void submit(true)
    return
  }
  const index = Number.parseInt(event.key, 10)
  if (Number.isNaN(index) || index < 1 || index > options.value.length) return
  const option = options.value[index - 1]
  if (option === undefined) return
  event.preventDefault()
  toggleOption(option)
}

const waiting = computed(() => state.value === 'pending')

const questionHtml = computed(() => renderMarkdownHtml(props.question.question))

const optionLabels = computed<string[]>(() => options.value.map((o) => stripMarkdownSyntax(o)))

const title = computed(() => {
  const header = stripMarkdownSyntax(props.question.header)
  if (header) return header
  const q = stripMarkdownSyntax(props.question.question)
  if (q.length > 0) return q.length > 60 ? `${q.slice(0, 60)}…` : q
  return 'Question'
})

const rightMeta = computed(() => {
  switch (state.value) {
    case 'pending':
      return multiSelect.value && options.value.length > 0
        ? `pick any of ${options.value.length}`
        : null
    case 'answered':
      return answers.value.length > 1 ? `${answers.value.length} answers` : null
    default:
      return null
  }
})

const answerChip = computed(() =>
  answers.value.map((answer) => stripMarkdownSyntax(answer)).join(' · '),
)

onMounted(() => {
  if (waiting.value) window.addEventListener('keydown', onKeydown)
})

const prevWaiting = ref(waiting.value)
onUpdated(() => {
  const now = waiting.value
  if (now === prevWaiting.value) return
  prevWaiting.value = now
  if (now) window.addEventListener('keydown', onKeydown)
  else window.removeEventListener('keydown', onKeydown)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeydown)
})

defineExpose({ submit, toggleOption, chooseFreeText, canSend, buildBody })
</script>

<template>
  <div
    class="ask-user-card font-mono text-dense"
    data-testid="ask-user-card"
    :data-state="state"
  >
    <div class="ask-user-head" data-testid="ask-user-header">
      <span class="ask-user-title font-sans text-dense">{{ title }}</span>
      <span v-if="rightMeta" class="ask-user-meta text-micro">{{ rightMeta }}</span>
      <span v-if="waiting" class="ask-user-waiting text-micro">waiting for you</span>
    </div>

    <div
      v-if="state !== 'pending' && state !== 'settled'"
      class="ask-user-resolved px-3 py-2 font-sans text-dense"
      data-testid="ask-user-resolved-summary"
    >
      <template v-if="state === 'answered'">✓ {{ answerChip || 'answered' }}</template>
      <template v-else-if="state === 'skipped'">skipped — the agent will not guess</template>
      <template v-else-if="state === 'abandoned'">you moved on — the agent will not guess</template>
    </div>

    <div
      v-if="question.question"
      class="markdown-content ask-user-question px-3 pb-2 font-sans text-body"
      data-testid="ask-user-question"
      v-html="questionHtml"
    />

    <div
      v-if="state === 'settled'"
      class="ask-user-resolved px-3 pb-2 font-sans text-dense"
      data-testid="ask-user-settled"
    >
      this question is settled ({{ question.rawStatus || 'no status' }})
    </div>

    <template v-if="state === 'pending'">
      <div v-if="options.length > 0" class="flex flex-col gap-1 px-3 pb-2">
        <button
          v-for="(option, index) in options"
          :key="option"
          type="button"
          class="flex items-start gap-2 rounded-md border px-2 py-1.5 text-left transition-colors"
          :class="
            selected.includes(option)
              ? 'border-[var(--color-violet)] bg-[var(--color-violet)]/10'
              : 'border-[var(--color-border)] hover:border-[var(--color-violet)]/50'
          "
          :disabled="submitting"
          :data-testid="`ask-user-option-${index}`"
          @click="toggleOption(option)"
        >
          <span class="mt-0.5 shrink-0 text-micro" style="color: var(--semantic-text-dim)">
            {{ index + 1 }}
          </span>
          <span class="flex-1 font-sans text-dense" style="color: var(--semantic-text)">
            {{ optionLabels[index] ?? option }}
          </span>
          <span
            v-if="option === question.recommended"
            class="shrink-0 rounded-full border border-green-500/40 px-1.5 text-micro text-green-500"
          >
            recommended
          </span>
        </button>
      </div>

      <div v-if="question.allowFreeText" class="px-3 pb-2">
        <label
          class="mb-1 flex items-center gap-2 font-sans text-dense"
          style="color: var(--semantic-text-dim)"
        >
          <input
            type="radio"
            :checked="usingFreeText"
            data-testid="ask-user-other-radio"
            @change="chooseFreeText()"
          />
          Other — type your own answer
        </label>
        <textarea
          v-model="freeText"
          rows="3"
          data-testid="ask-user-freetext"
          class="w-full resize-y rounded-md border bg-transparent px-2 py-1.5 font-sans text-dense leading-relaxed"
          style="
            border-color: var(--color-border);
            color: var(--semantic-text);
            min-height: 4.5rem;
          "
          placeholder="Type your answer…"
          :disabled="submitting"
          @focus="chooseFreeText()"
          @input="onFreeTextInput($event)"
          @keydown.enter.exact.prevent="submit(false)"
        />
      </div>

      <div class="ask-user-actions">
        <button
          type="button"
          class="rounded-md px-3 py-1 font-sans text-dense font-semibold"
          style="background: var(--color-violet); color: var(--color-bg)"
          :disabled="!canSend"
          :class="{ 'cursor-not-allowed opacity-50': !canSend }"
          data-testid="ask-user-send"
          @click="submit(false)"
        >
          <span v-if="submitting">Sending…</span>
          <span v-else-if="multiSelect && selected.length > 1"
            >Send {{ selected.length }} answers</span
          >
          <span v-else>Send answer</span>
        </button>
        <button
          type="button"
          class="rounded-md border px-3 py-1 font-sans text-dense"
          style="border-color: var(--color-border); color: var(--semantic-text-dim)"
          :disabled="submitting"
          data-testid="ask-user-skip"
          @click="submit(true)"
        >
          Skip
        </button>
        <span class="ml-auto text-micro" style="color: var(--semantic-text-dim)">
          1–{{ options.length || 1 }} pick · ⏎ send · esc skip
        </span>
      </div>

      <div
        v-if="sendFailed"
        class="px-3 pb-2 font-sans text-dense text-red-500"
        data-testid="ask-user-error"
      >
        Couldn't send your answer — the server is unreachable.
        <button type="button" class="ml-1 underline" @click="submit(false)">Retry</button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.ask-user-card {
  border: 1px solid var(--color-border);
  border-radius: 10px;
  background: var(--color-bg-subtle, transparent);
  margin-top: 0.5rem;
}

.ask-user-head {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem 0.375rem;
  border-bottom: 1px solid var(--color-border);
}

.ask-user-title {
  font-weight: 600;
  color: var(--semantic-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.ask-user-meta,
.ask-user-waiting {
  color: var(--semantic-text-dim);
  flex-shrink: 0;
}

.ask-user-waiting {
  margin-left: auto;
}

.ask-user-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  border-top: 1px solid var(--color-border);
  padding: 0.5rem 0.75rem;
}

.ask-user-question :deep(p) {
  margin-bottom: 0.4rem;
}

.ask-user-question :deep(p:last-child) {
  margin-bottom: 0;
}

.ask-user-question :deep(ul),
.ask-user-question :deep(ol) {
  margin-bottom: 0.4rem;
  padding-left: 1.1rem;
}

.ask-user-question :deep(li) {
  margin-bottom: 0.15rem;
}

.ask-user-question :deep(h1),
.ask-user-question :deep(h2),
.ask-user-question :deep(h3),
.ask-user-question :deep(h4),
.ask-user-question :deep(h5),
.ask-user-question :deep(h6) {
  font-size: var(--text-body);
  font-weight: 600;
  margin-top: 0.35rem;
  margin-bottom: 0.25rem;
  border-bottom: none;
  padding-bottom: 0;
}

.ask-user-question :deep(h1:first-child),
.ask-user-question :deep(h2:first-child),
.ask-user-question :deep(h3:first-child) {
  margin-top: 0;
}

.ask-user-question :deep(blockquote) {
  margin: 0.3rem 0;
  padding: 0.1rem 0.5rem;
  font-size: var(--text-dense);
}

.ask-user-question :deep(pre) {
  max-height: 11rem;
  overflow: auto;
  font-size: var(--text-meta);
  padding: 0.4rem 0.5rem;
}

.ask-user-question :deep(code) {
  font-size: 0.85em;
}

.ask-user-question :deep(table) {
  display: block;
  overflow-x: auto;
  font-size: var(--text-dense);
}

.ask-user-question :deep(a) {
  color: inherit;
  text-decoration: underline;
}
</style>
