<!--
  AskUser — tool output component for the `ask_user` agent tool.

  The agent calls `ask_user` when a decision is genuinely blocked on the
  human. The call ENDS the turn: the tool returns immediately, the agentic
  loop breaks, and the question waits here until the user answers. Answering
  rewrites this tool's result row in place and starts a new run, so the model
  continues with the answer in context.

  Wire shape — the component parses the JSON `data` object out of
  `content` (which ChatView passes as the unwrapped `data` payload, or the
  whole envelope JSON string when the call failed):

    Pending (the card's interactive state):
      {"status":"pending","question_id":"q_…","header":"Deploy target",
       "question":"Which environment should I deploy to?",
       "allow_free_text":true,"multi_select":false,
       "recommended":"staging","options":["staging","production"],
       "instruction":"…"}

    Resolved (written in place by POST …/answer):
      …{"status":"answered","answer":"staging","answers_count":1}
      …{"status":"skipped"}  |  {"status":"abandoned"}
      …{"status":"unavailable"}

    Invalid input (never a row):
      {"tool":"ask_user",…,"success":false,
       "error":"recommended must exactly match one of the strings in options"}

  The question's SHAPE travels in the envelope rather than being read from
  the tool row's `<parameters>` block: `wrapToolOutput` converts the arguments
  to XML, so the frontend cannot JSON-parse them back, and the tool row has no
  `tool_calls_json` (that lives on the assistant row). One source means the
  pending card renders identically live and after a page reload.

  MARKDOWN (`question`, `header`, `options`, `answer` may all carry it —
  `ask_user.zig`'s schema says "Markdown allowed" and the model writes it
  that way, e.g. `**Option 1 — Full 1:1**` + `` `linux/window.zig` ``):

    `question`  → rendered as markdown (`renderMarkdownHtml` + `v-html`
                  inside `.markdown-content`), the same trust model the
                  chat transcript already uses for assistant text.
    `header`    → stripped to plain text: the header pill is ONE line.
    `options`   → stripped for the label only. `buildBody` still POSTs the
                  RAW option string, so the model receives back exactly
                  what it wrote.
    `answer`    → stripped for the chip only, same raw-value rule.

  Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md
  Wireframe: docs/wireframes/ask-user-tool.html
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { tryUnwrapToolOutput } from '../../helpers/unwrapToolOutput'
import { renderMarkdownHtml, stripMarkdownSyntax } from '../../helpers/markdown'
import { answerAskUser } from '../../api'

interface Props {
  /** Unwrapped `data` object (or the full envelope JSON string on failure). */
  content: unknown
  /** Raw tool-call arguments, for the collapsible Arguments block. */
  parameters?: string
  expanded?: boolean
  /** Needed to POST the answer. */
  sessionId?: string
}

const props = defineProps<Props>()

// ---------------------------------------------------------------------------
// Envelope parsing
// ---------------------------------------------------------------------------

function asRecord(v: unknown): Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {}
}

function strField(o: Record<string, unknown>, key: string): string {
  const v = o[key]
  if (typeof v === 'string') return v
  if (v === null || v === undefined) return ''
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

/**
 * Resolve `content` to the ask_user `data` object. Accepts the bare data
 * object (ChatView's success path), a full envelope object, or either form
 * as a JSON string (ChatView's error fallback hands us the raw envelope
 * string). Returns the envelope error when the call failed.
 */
function resolveData(content: unknown): {
  data: Record<string, unknown> | null
  error: string | null
} {
  if (content === null || content === undefined) return { data: null, error: null }
  if (typeof content === 'string') {
    if (content.trim() === '') return { data: null, error: null }
    const unwrapped = tryUnwrapToolOutput(content)
    if (unwrapped) {
      if (!unwrapped.success) {
        return { data: null, error: unwrapped.error ?? 'ask_user failed' }
      }
      return { data: asRecord(unwrapped.data), error: null }
    }
    try {
      const parsed: unknown = JSON.parse(content)
      if (typeof parsed === 'object' && parsed !== null) {
        return resolveData(parsed)
      }
    } catch {
      /* not JSON — fall through to empty */
    }
    return { data: null, error: null }
  }
  if (typeof content === 'object' && !Array.isArray(content)) {
    const o = content as Record<string, unknown>
    if (typeof o.tool === 'string' || (typeof o.success === 'boolean' && 'data' in o)) {
      if (o.success === false) {
        return {
          data: null,
          error: typeof o.error === 'string' ? o.error : 'ask_user failed',
        }
      }
      return { data: asRecord(o.data), error: null }
    }
    return { data: o, error: null }
  }
  return { data: null, error: null }
}

type ViewState = 'pending' | 'answered' | 'skipped' | 'abandoned' | 'unavailable' | 'invalid'

interface ParsedEnvelope {
  state: ViewState
  questionId: string
  header: string
  question: string
  options: string[]
  allowFreeText: boolean
  multiSelect: boolean
  recommended: string
  answer: string
  answersCount: number
  error: string
}

const parsed = computed<ParsedEnvelope>(() => {
  const fallback: ParsedEnvelope = {
    state: 'pending',
    questionId: '',
    header: '',
    question: '',
    options: [],
    allowFreeText: true,
    multiSelect: false,
    recommended: '',
    answer: '',
    answersCount: 0,
    error: '',
  }

  const resolved = resolveData(props.content)
  if (resolved.data === null) {
    if (resolved.error !== null) {
      return { ...fallback, state: 'invalid', error: resolved.error }
    }
    return fallback
  }

  return parseData(resolved.data)
})

function parseData(data: Record<string, unknown>): ParsedEnvelope {
  const status = typeof data.status === 'string' ? data.status.trim() : ''

  // Unknown / missing status degrades to a readable completed card rather
  // than throwing — a new backend status must never blank the transcript.
  const state: ViewState =
    status === 'pending' ||
    status === 'answered' ||
    status === 'skipped' ||
    status === 'abandoned' ||
    status === 'unavailable'
      ? (status as ViewState)
      : 'invalid'

  const freeTextRaw = data.allow_free_text
  const multiRaw = data.multi_select
  const optionsRaw = data.options
  const answersCountRaw = data.answers_count

  return {
    state,
    questionId: strField(data, 'question_id'),
    header: strField(data, 'header'),
    question: strField(data, 'question'),
    options: Array.isArray(optionsRaw) ? optionsRaw.map((v) => String(v)) : [],
    // Absent means "not specified" → the tool's own defaults.
    allowFreeText:
      freeTextRaw === null || freeTextRaw === undefined
        ? true
        : freeTextRaw !== false &&
          !(typeof freeTextRaw === 'string' && freeTextRaw.trim() === 'false'),
    multiSelect: multiRaw === true || (typeof multiRaw === 'string' && multiRaw.trim() === 'true'),
    recommended: strField(data, 'recommended'),
    answer:
      typeof data.answer === 'string'
        ? data.answer
        : data.answer === null || data.answer === undefined
          ? ''
          : String(data.answer),
    answersCount:
      typeof answersCountRaw === 'number' && Number.isFinite(answersCountRaw)
        ? answersCountRaw
        : Number.parseInt(strField(data, 'answers_count'), 10) || 0,
    error: strField(data, 'error') || 'ask_user returned an unrecognised status',
  }
}

// ---------------------------------------------------------------------------
// Local interaction state
// ---------------------------------------------------------------------------

// Expanded by default in every state: the question, options, and outcome
// stay visible without an extra click. A user who collapses the card keeps
// it collapsed — this is only the initial value.
const isExpanded = ref<boolean>(true)
const submitting = ref(false)
const sendFailed = ref(false)
/** Set after a successful POST so the card flips even if the SSE frame is missed. */
const locallyResolved = ref<ViewState | null>(null)
const locallyAnswered = ref('')

const selected = ref<string[]>([])
const freeText = ref('')
/** True when the user chose to type instead of picking an option. */
const usingFreeText = ref(false)

const state = computed<ViewState>(() => locallyResolved.value ?? parsed.value.state)
const options = computed(() => parsed.value.options)
const multiSelect = computed(() => parsed.value.multiSelect)

const answers = computed<string[]>(() => {
  if (locallyAnswered.value) return parseAnswers(locallyAnswered.value)
  return parseAnswers(parsed.value.answer)
})

function parseAnswers(raw: string): string[] {
  const trimmed = (raw ?? '').trim()
  if (trimmed.length === 0) return []
  if (trimmed.startsWith('[')) {
    try {
      const arr = JSON.parse(trimmed)
      if (Array.isArray(arr)) return arr.map((v) => String(v))
    } catch {
      /* fall through to the single-value case */
    }
  }
  return [trimmed]
}

/** True when the free-text box is the answer: either the user explicitly chose
 * "Other", or they simply typed something without picking an option. Typing
 * IS answering — requiring a radio click first would silently drop the text. */
const answerIsFreeText = computed(
  () => freeText.value.trim().length > 0 && (usingFreeText.value || selected.value.length === 0),
)

/** A pending question needs a valid selection (or text) before Send. */
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

/** Answer text is often a sentence or three (an id, a path, a caveat), so the
 * box grows with what is typed instead of staying two lines tall. Capped so a
 * pasted essay cannot push the composer off screen. */
const FREETEXT_MAX_PX = 220

function autoGrow(event: Event): void {
  const el = event.target as HTMLTextAreaElement | null
  if (!el) return
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, FREETEXT_MAX_PX)}px`
}

/** Typing in the box IS choosing free text; also let the box grow. */
function onFreeTextInput(event: Event): void {
  usingFreeText.value = true
  autoGrow(event)
}

/** The exact body the endpoint validates. */
function buildBody(skip: boolean): Record<string, unknown> {
  const body: Record<string, unknown> = {}
  if (parsed.value.questionId) body.question_id = parsed.value.questionId
  if (skip) {
    body.skip = true
    return body
  }
  if (answerIsFreeText.value) {
    body.answer = freeText.value.trim()
  } else if (multiSelect.value) {
    // Multi-select answers are a JSON array of strings on the wire.
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
    // Should not happen (ChatView always passes it); fail visibly rather
    // than posting nowhere.
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

  // No optimistic swap while the request is in flight, but once it has
  // succeeded the row rewrite is authoritative — flip locally too, so a
  // dropped SSE frame cannot leave a stale interactive card on screen.
  const nextState = (res.status as ViewState) ?? (skip ? 'skipped' : 'answered')
  locallyResolved.value = nextState === 'pending' ? null : nextState
  if (!skip) locallyAnswered.value = String(body.answer ?? '')
  // Leaving `pending` drops the card-level keydown listener right away.
  window.removeEventListener('keydown', onKeydown)
}

function onKeydown(event: KeyboardEvent): void {
  if (state.value !== 'pending' || submitting.value) return
  const target = event.target as HTMLElement | null
  // Never steal keys from the textarea the user is typing in.
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

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

const waiting = computed(() => state.value === 'pending')

/**
 * The question is model-authored MARKDOWN — `ask_user.zig`'s schema says
 * "Markdown allowed" — so it renders as markdown, not as `{{ text }}`.
 * Before this, a question like
 *
 *   **Option 1 — Full 1:1 (recommended)** … `linux/window.zig` …
 *
 * reached the card as one wall of asterisks and backticks. Scoped CSS
 * below keeps the global `.markdown-content` typography at card scale.
 */
const questionHtml = computed(() => renderMarkdownHtml(parsed.value.question))

/** Option labels: markdown stripped, so `**bold**` never shows literally. */
const optionLabels = computed<string[]>(() =>
  options.value.map((option) => stripMarkdownSyntax(option)),
)

/**
 * The one-line `primary` and the resolved answer chip must stay TEXT —
 * the header pill is a single truncated line, and the answer chip's text
 * is the very string POSTed back to the model. Strip the syntax, keep the
 * words, and keep `options` / `answer` themselves raw for the wire.
 */
const primary = computed(() => {
  const header = stripMarkdownSyntax(parsed.value.header)
  if (header) return header
  const q = stripMarkdownSyntax(parsed.value.question)
  if (q.length > 0) return q.length > 60 ? `${q.slice(0, 60)}…` : q
  return 'ask_user'
})

const rightMeta = computed(() => {
  switch (state.value) {
    case 'pending':
      return multiSelect.value && options.value.length > 0
        ? `pick any of ${options.value.length}`
        : null
    case 'answered':
      return answers.value.length > 1 ? `${answers.value.length} answers` : null
    case 'unavailable':
      return 'no human'
    default:
      return null
  }
})

/** Display-only. `answers` stays raw because `buildBody` POSTs the raw
 * answer value; the chip just drops markdown syntax so a picked
 * `**Option 1**` does not read as asterisks next to its own "✓". */
const answerChip = computed(() =>
  answers.value.map((answer) => stripMarkdownSyntax(answer)).join(' · '),
)

onMounted(() => {
  if (waiting.value) {
    window.addEventListener('keydown', onKeydown)
  }
})

// Card-level Enter/Escape/number shortcuts live only while pending. The submit handler above
// removes the listener when it resolves the card; the prev-value guard below covers parent-driven
// transitions (a fresh pending question arriving via props on an existing card).
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
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': state === 'invalid' }"
    data-testid="ask-user-card"
    :data-state="state"
  >
    <ToolCardHeader
      tool-name="ask_user"
      :primary="primary"
      :success="state !== 'invalid'"
      :expanded="isExpanded"
      :expandable="true"
      :right-meta="rightMeta"
      :running="waiting"
      @update:expanded="isExpanded = $event"
    />

    <!-- Collapsed one-liner: the resolved outcome, for every resolved state. -->
    <div
      v-if="!isExpanded && state !== 'pending' && state !== 'invalid'"
      class="px-2 pb-2 font-sans text-dense"
      style="color: var(--semantic-text-dim)"
      data-testid="ask-user-collapsed-summary"
    >
      <template v-if="state === 'answered'">✓ {{ answerChip }}</template>
      <template v-else-if="state === 'skipped'">skipped — the agent will not guess</template>
      <template v-else-if="state === 'abandoned'">you moved on — the agent will not guess</template>
      <template v-else-if="state === 'unavailable'"
        >no human available — the agent decided</template
      >
    </div>

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <!-- Question text (every state). Markdown: the model's `question`
           field is documented as markdown-capable, and the model writes it
           that way — bold the option headlines, `code` the file paths, a
           list when the context is long. `v-html` + `.markdown-content`,
           the same contract as the chat transcript; the scoped rules at the
           bottom of this file keep the type at card scale. -->
      <div
        v-if="parsed.question"
        class="markdown-content ask-user-question px-2 py-2 font-sans text-body"
        style="color: var(--semantic-text)"
        data-testid="ask-user-question"
        v-html="questionHtml"
      />

      <!-- Invalid / failed call -->
      <div v-if="state === 'invalid'" class="px-2 pb-2 font-sans text-dense text-red-500">
        {{ parsed.error }}
      </div>

      <!-- PENDING: the interactive part -->
      <template v-if="state === 'pending'">
        <div v-if="options.length > 0" class="flex flex-col gap-1 px-2 pb-2">
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
              v-if="option === parsed.recommended"
              class="shrink-0 rounded-full border border-green-500/40 px-1.5 text-micro text-green-500"
            >
              recommended
            </span>
          </button>
        </div>

        <div v-if="parsed.allowFreeText" class="px-2 pb-2">
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

        <div class="flex items-center gap-2 border-t border-[var(--color-border)] px-2 py-2">
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
          class="px-2 pb-2 font-sans text-dense text-red-500"
          data-testid="ask-user-error"
        >
          Couldn't send your answer — the server is unreachable.
          <button type="button" class="ml-1 underline" @click="submit(false)">Retry</button>
        </div>
      </template>

      <!-- RESOLVED states -->
      <div v-else-if="state === 'answered'" class="px-2 pb-2">
        <span
          class="inline-flex items-center gap-2 rounded-md border border-green-500/30 px-2 py-1 font-sans text-dense text-green-500"
          data-testid="ask-user-answer-chip"
        >
          ✓ {{ answerChip }}
        </span>
      </div>

      <div
        v-else-if="state === 'skipped'"
        class="px-2 pb-2 font-sans text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-skipped"
      >
        You skipped this question — the agent will not guess.
      </div>

      <div
        v-else-if="state === 'abandoned'"
        class="px-2 pb-2 font-sans text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-abandoned"
      >
        You moved on without answering — the agent will not guess.
      </div>

      <div
        v-else-if="state === 'unavailable'"
        class="px-2 pb-2 font-sans text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="ask-user-unavailable"
      >
        No human was available — the agent decided on its own.
      </div>
    </div>

    <ToolParameters :parameters="props.parameters ?? '{}'" />
  </div>
</template>

<style scoped>
/*
 * The question renders through the global `.markdown-content` rules, which
 * are tuned for the chat transcript: an `h1` there is 1.5rem and a `<p>`
 * carries 0.75rem of bottom margin. Both are wrong inside a `text-dense` card
 * next to a row of option buttons — the question would dwarf the answer
 * surface. These overrides pull the whole scale down to card size and cap
 * a pasted code block so the Send row stays on screen.
 *
 * `:deep()` is required: the elements come from `v-html`, so they carry no
 * scoped-style attribute of this component.
 */
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

/* A question is prose, not a diff — but the model does quote file lists,
 * and an unbounded <pre> would push Send off the card. */
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
