<!--
  WebSearch — tool output component for the `web_search` agent tool.

  Renders the JSON envelope produced by `exec_web_search`
  (`src/agentic_loop/tools_exec_web_search.zig`):

    Success: {"provider":"tinyfish","status":200,"response":{…}}
    Failure: {"error":"…","unknown_provider":true,"available":[…]}
             (one of nine reason flags — see `parseWebSearch`)

  `response` is UNTYPED PASSTHROUGH (D13): the provider's own JSON, verbatim.
  TinyFish answers `{results:[…]}`, Brave `{web:{results:[…]}}`, Serper
  `{organic:[…]}`, a self-hosted SearxNG a bare `[{…}]`. This card therefore
  renders ONE convention and degrades to formatted JSON for everything else:

    - a top-level `results` array of objects → one row per result
      (title, url, and whichever of snippet / description / content exists),
    - anything else → the payload as pretty JSON.

  That fallback is the CORRECT behaviour, not an error state: an unfamiliar
  provider shape is normal. Nothing in here throws, and no `try`/`catch`
  turns a failure into a plausible-looking empty result — a payload that
  cannot be serialised says so in the card instead of rendering as "[]".

  Header: `web_search → <provider> · <n results | HTTP status> ✓`
  Body:   the provider badge, then results or the formatted JSON, plus the
          reason flags and details on a failure.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import {
  normalizeToolContent,
  parseWebSearch,
  parseWebSearchErrorText,
  type ParsedWebSearch,
} from './_shared/toolOutputParser'

const props = defineProps<{
  /** The tool row's payload — the inner `data` object on success, or the full
   * envelope on failure (ChatView's `innerToolData` falls back to the whole
   * content when `data` is null, which is what a failure envelope carries). */
  content: unknown
  /** The JSON-stringified tool-call arguments: `{provider, curl}`. */
  parameters?: string
  /** Whether the row is already expanded in the parent chat. */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ─── Envelope ──────────────────────────────────────────────────────────────

const normalized = computed(() => normalizeToolContent(props.content))

const parsed = computed<ParsedWebSearch>(() => {
  const p = parseWebSearch(normalized.value.data)
  const text = normalized.value.error
  if (text === null) return p
  // A failure reaches this card through the envelope's `error` field, which
  // for the self-correcting reasons carries the whole inner JSON as text.
  // `parseWebSearchErrorText` reads the flags out of it when they are there.
  return { ...p, success: false, error: parseWebSearchErrorText(text) }
})

/**
 * The provider, preferring the envelope's own word for it and falling back to
 * the name the call asked for — a `configured` failure names no provider at
 * all, and a card that then says "unknown" loses the only fact it has.
 * `||`, not `??`: an envelope may carry `"provider":""`, which is no name.
 */
interface WebSearchArgs {
  provider?: string
  curl?: string
}

const args = computed<WebSearchArgs>(() => {
  const text = (props.parameters ?? '').trim()
  if (text === '') return {}
  try {
    const value: unknown = JSON.parse(text)
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as WebSearchArgs
    }
  } catch {
    // Not JSON — an absent provider badge is the correct outcome, not a fault.
  }
  return {}
})

const provider = computed(() => parsed.value.provider || args.value.provider || null)

// ─── The results convention ────────────────────────────────────────────────

interface ResultRow {
  key: string
  title: string
  url: string
  /** `url` is safe to make clickable — http(s), not `javascript:` or `data:`. */
  linkable: boolean
  /** Whichever of snippet / description / content the provider sent. */
  body: string
  position: string | null
}

/**
 * Whether a provider-supplied URL may become an `href`.
 *
 * The payload is passthrough (D13): the backend pins the host it REQUESTS and
 * scrubs the key, but it never inspects what came back, so a `url` here is
 * whatever the provider wrote. Only http(s) becomes a link; anything else
 * (`javascript:`, `data:`, a bare word) is shown as plain text, because a
 * clickable one runs in this app's origin.
 */
function isWebUrl(url: string): boolean {
  return /^https?:\/\//i.test(url)
}

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}

function text(value: unknown): string {
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return ''
}

function firstText(record: Record<string, unknown>, keys: string[]): string {
  for (const key of keys) {
    const v = text(record[key]).trim()
    if (v !== '') return v
  }
  return ''
}

/**
 * The ranked list, or null when the payload is not the `results` convention.
 *
 * The check is deliberately narrow: a TOP-LEVEL `results` whose every member
 * is an object. Brave nests the same array under `web`, SearxNG returns a
 * bare array — both are real payloads and both render as formatted JSON.
 */
const rows = computed<ResultRow[] | null>(() => {
  const raw = asRecord(parsed.value.response).results
  if (!Array.isArray(raw)) return null
  const out: ResultRow[] = []
  for (const [index, item] of raw.entries()) {
    if (typeof item !== 'object' || item === null || Array.isArray(item)) return null
    const r = item as Record<string, unknown>
    // Serper calls the link `link`; every other provider says `url`.
    const url = firstText(r, ['url', 'link'])
    out.push({
      key: `${index}`,
      title: firstText(r, ['title']),
      url,
      linkable: isWebUrl(url),
      body: firstText(r, ['snippet', 'description', 'content']),
      position: text(r.position ?? r.rank).trim() || null,
    })
  }
  return out
})

const hasResultRows = computed(() => rows.value !== null)

// ─── Formatted JSON fallback ───────────────────────────────────────────────

/** Pretty-print an untyped payload. `JSON.stringify` can refuse (a cycle, a
 * BigInt); the card then says the payload is unprintable instead of showing
 * an empty block that reads like "no results". */
const prettyResponse = computed(() => {
  const response = parsed.value.response
  if (response === null || response === undefined) return '(no response body)'
  try {
    const text = JSON.stringify(response, null, 2)
    return text === undefined ? String(response) : text
  } catch {
    return '(the provider response could not be serialised)'
  }
})

/** Copy target: the payload on success, nothing on a failure — there is none. */
const copyValue = computed(() => (parsed.value.success ? prettyResponse.value : ''))

// ─── Failure detail ────────────────────────────────────────────────────────

const alternatives = computed(() => {
  const error = parsed.value.error
  if (!error) return []
  return error.available.length > 0 ? error.available : error.otherProviders
})

const hostMismatch = computed(() => {
  const error = parsed.value.error
  if (!error || error.pinnedHost === null) return null
  return { pinned: error.pinnedHost, requested: error.requestedHost ?? '(none)' }
})

const httpStatus = computed(() => parsed.value.error?.httpStatus ?? null)

// ─── Header ────────────────────────────────────────────────────────────────

const rightMeta = computed(() => {
  if (!parsed.value.success) return null
  if (hasResultRows.value) {
    const n = rows.value?.length ?? 0
    return n === 1 ? '1 result' : `${n} results`
  }
  return parsed.value.status === null ? null : `HTTP ${parsed.value.status}`
})

const headerLabel = computed(() => {
  if (!parsed.value.success) return parsed.value.error?.message || 'error'
  return provider.value ?? 'unknown provider'
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !parsed.success }"
    data-testid="web-search-card"
  >
    <ToolCardHeader
      tool-name="web_search"
      :primary="headerLabel"
      :primary-title="headerLabel"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :show-open-in-editor="false"
      :copy-value="copyValue"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Failure: the reason flags, then the sentence and the details. -->
      <template v-if="!parsed.success && parsed.error">
        <div
          v-if="parsed.error.flags.length > 0"
          class="flex flex-wrap gap-1 px-2 py-1.5 border-b border-dashed border-[var(--color-border)]"
          data-testid="web-search-flags"
        >
          <span
            v-for="flag in parsed.error.flags"
            :key="flag"
            class="px-1 border border-red-500/40 text-red-500 rounded-sm"
            data-testid="web-search-flag"
            >{{ flag }}</span
          >
        </div>

        <div
          class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="web-search-error"
        >
          <span class="font-semibold shrink-0">Error:</span>
          <span class="whitespace-pre-wrap break-all">{{
            parsed.error.message || 'unknown error'
          }}</span>
        </div>

        <div
          v-if="hostMismatch"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="web-search-host-mismatch"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Refused:</span>
          <span class="break-all">
            {{ hostMismatch.requested }} → pinned host {{ hostMismatch.pinned }}
          </span>
        </div>

        <div
          v-if="httpStatus !== null"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">HTTP status:</span>
          <span>{{ httpStatus }}</span>
        </div>

        <div
          v-for="alt in alternatives"
          :key="alt.name"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Available:</span>
          <span class="break-all"
            >{{ alt.name }}<template v-if="alt.url"> — {{ alt.url }}</template></span
          >
        </div>
      </template>

      <!-- Success: who answered, then the payload. -->
      <template v-else>
        <div
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="web-search-provider"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Provider:</span>
          <span class="text-[var(--semantic-text)]">{{ provider ?? 'unknown' }}</span>
          <span v-if="parsed.status !== null" class="text-[var(--semantic-text-muted)]">
            HTTP {{ parsed.status }}
          </span>
        </div>

        <template v-if="hasResultRows">
          <div
            v-for="row in rows ?? []"
            :key="row.key"
            class="flex flex-col gap-0.5 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
            :data-testid="`web-search-row-${row.key}`"
          >
            <div class="flex gap-2 min-w-0">
              <span
                v-if="row.position"
                class="font-semibold shrink-0 text-[var(--semantic-text-muted)]"
                >#{{ row.position }}</span
              >
              <a
                v-if="row.linkable"
                :href="row.url"
                target="_blank"
                rel="noopener noreferrer"
                class="truncate text-[var(--color-violet)] hover:underline"
                :title="row.title || row.url"
                data-testid="web-search-result-link"
                >{{ row.title || row.url }}</a
              >
              <span v-else class="truncate text-[var(--semantic-text)]">{{
                row.title || row.url || '(untitled)'
              }}</span>
            </div>
            <span
              v-if="row.url && row.title"
              class="truncate text-[var(--semantic-text-dim)]"
              :title="row.url"
              >{{ row.url }}</span
            >
            <span
              v-if="row.body"
              class="whitespace-pre-wrap break-words text-[var(--semantic-text)]"
              data-testid="web-search-result-body"
              >{{ row.body }}</span
            >
          </div>
          <div
            v-if="(rows ?? []).length === 0"
            class="px-2 py-1.5 text-[var(--semantic-text-muted)] text-dense"
            data-testid="web-search-empty"
          >
            (no results)
          </div>
        </template>

        <pre
          v-else
          class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-dense"
          data-testid="web-search-json"
          >{{ prettyResponse }}</pre
        >
      </template>

      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
