<!--
  KanbanPrList — board-level change-request list (wireframe:
  docs/wireframes/kanban-pull-request-button.html, §2/§3).

  Full-cover view mounted by KanbanView: header (Back, forge-aware
  title, Refresh, New-CR link), Open/Closed tabs, an `Only this
  board` client-side filter, one row per change request, and a
  Close → confirm flow per row.

  The fetch state is a discriminated union (`loading | ready |
  failed`) so a failed `gh`/`glab` call can never render as "no
  open pull requests" (the PR-#719 bug class: an empty list is only
  rendered when the request resolved with `changes.length === 0`).

  The parent owns the tab (URL `?prs=`); this component only emits
  `tabChange`, and the parent calls the exposed `reload()` to
  re-fetch (no `watch()` — `local/no-watch` bans new watchers).
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import ForgeIcon from '../git/ForgeIcon.vue'
import UiIcon from '../ui/UiIcon.vue'
import { ApiError, closePr, listPrs, type GitPrListItem } from '../../api'
import { forgeWording } from '../../helpers/forgeWording'
import { repoBaseFromPrUrl } from '../../helpers/prStatusCache'
import type { Task } from '../../stores/workspaces'

export type PrListTab = 'open' | 'closed'

const props = defineProps<{
  itemPath: string
  itemId: string
  workspaceId: string
  tasks: Task[]
  open: boolean
  tab: PrListTab
}>()

const emit = defineEmits<{
  back: []
  tabChange: [tab: PrListTab]
  openCount: [n: number]
  closed: [payload: { number: number; headRef: string }]
}>()

// ─── Fetch state (discriminated union — never confuse failed with empty) ──

type ListState =
  | { kind: 'loading' }
  | {
      kind: 'ready'
      rows: GitPrListItem[]
      provider: string
      program: string
      truncated: boolean
      detail: string
      checkedAtMs: number
    }
  | { kind: 'failed'; message: string }

const state = ref<ListState>({ kind: 'loading' })
// Last-known row counts per tab, so the strip can show both numbers
// even though only the active tab is fetched.
const tabCounts = ref<{ open: number | null; closed: number | null }>({ open: null, closed: null })

const provider = computed(() => (state.value.kind === 'ready' ? state.value.provider : ''))
const wording = computed(() => forgeWording(provider.value || undefined))
// The plural is written here, once — nowhere else hardcodes it.
const pluralLabel = computed(() =>
  wording.value.short === 'MR' ? 'Merge requests' : 'Pull requests',
)
const newCrLabel = computed(() => `New ${wording.value.noun} ↗`)

// ─── Error sentence extraction ─────────────────────────────────────────────
// The backend's error bodies are always `{ "error": "<sentence>" }`;
// surface that sentence, never a status code.
const errorSentence = (err: unknown): string => {
  if (err instanceof ApiError) {
    const body = err.body || ''
    if (body) {
      try {
        const parsed: unknown = JSON.parse(body)
        if (
          parsed &&
          typeof parsed === 'object' &&
          typeof (parsed as { error?: unknown }).error === 'string'
        )
          return (parsed as { error: string }).error
      } catch {
        // Not JSON — fall through to the status text below.
      }
    }
    return body || `HTTP ${err.status} ${err.statusText}`.trim() || 'request failed'
  }
  return err instanceof Error ? err.message : String(err)
}

const load = (): void => {
  if (!props.itemPath) {
    state.value = { kind: 'failed', message: 'Set a project root first.' }
    return
  }
  const tab = props.tab
  state.value = { kind: 'loading' }
  listPrs(props.itemPath, { state: tab, limit: 30 }).then(
    (resp) => {
      const rows = resp.changes ?? []
      state.value = {
        kind: 'ready',
        rows,
        provider: resp.provider || '',
        program: resp.program || '',
        truncated: !!resp.truncated,
        detail: resp.detail || '',
        checkedAtMs: Date.now(),
      }
      tabCounts.value = { ...tabCounts.value, [tab]: rows.length }
      if (tab === 'open') emit('openCount', rows.length)
    },
    (err: unknown) => {
      // Failure lands in the union — never in an empty-looking list.
      state.value = { kind: 'failed', message: errorSentence(err) }
    },
  )
}

onMounted(() => {
  if (props.open) load()
})

// No `watch()` here — `local/no-watch` bans ALL new watchers,
// including the single-source side-effect form. Reloads are driven
// by the parent instead: it owns the tab (URL `?prs=`) and calls
// the exposed `reload()` from the event handlers that cause the
// change (tab click, open, route guard). Mount covers the open case
// via the `v-if` above.
defineExpose({ reload: load })

// ─── Meta line ─────────────────────────────────────────────────────────────

const checkedLabel = computed(() => {
  if (state.value.kind !== 'ready') return ''
  const diffSec = Math.floor((Date.now() - state.value.checkedAtMs) / 1000)
  if (diffSec < 60) return 'just now'
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`
  return `${Math.floor(diffSec / 86400)}d ago`
})

// `updated_at` arrives as ISO (`2026-10-12T06:34:01Z`); `new Date`
// parses that natively. (helpers/formatRelativeTime targets the
// SQLite-datetime wire shape and would read the trailing `Z` as
// invalid, rendering every row as "now".)
const relTime = (iso: string): string => {
  if (!iso) return 'now'
  const ms = new Date(iso).getTime()
  if (Number.isNaN(ms)) return 'now'
  const diffSec = Math.floor((Date.now() - ms) / 1000)
  if (diffSec < 60) return 'now'
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h`
  const days = Math.floor(diffSec / 86400)
  if (days < 7) return `${days}d`
  if (days < 365) return `${Math.floor(days / 7)}w`
  return `${Math.floor(days / 365)}y`
}

// ─── Board join + filter ───────────────────────────────────────────────────

const taskForRow = (row: GitPrListItem): Task | null =>
  (props.tasks ?? []).find((t) => (t.git_branch ?? '') === row.head_ref && row.head_ref !== '') ??
  null

// Default ON, client-side, exact equality (no prefix matching,
// case-sensitive): a row is on this board only when a card's
// `git_branch` IS the row's `head_ref`.
const onlyThisBoard = ref(true)

const rows = computed(() => (state.value.kind === 'ready' ? state.value.rows : []))
const onBoardRows = computed(() => rows.value.filter((r) => taskForRow(r) !== null))
const visibleRows = computed(() => (onlyThisBoard.value ? onBoardRows.value : rows.value))
const hiddenCount = computed(() => rows.value.length - onBoardRows.value.length)

// ─── New-CR link ───────────────────────────────────────────────────────────

const repoBase = computed(() => {
  for (const r of rows.value) {
    const base = repoBaseFromPrUrl(r.url || '')
    if (base) return base
  }
  return ''
})

const newCrUrl = computed(() => {
  if (!repoBase.value) return ''
  return provider.value === 'gitlab'
    ? `${repoBase.value}/-/merge_requests/new`
    : `${repoBase.value}/compare`
})

const openNewCr = (): void => {
  if (newCrUrl.value) window.open(newCrUrl.value, '_blank', 'noopener')
}

const openRowUrl = (row: GitPrListItem): void => {
  if (row.url) window.open(row.url, '_blank', 'noopener')
}

// ─── Close flow ────────────────────────────────────────────────────────────

const confirmRow = ref<GitPrListItem | null>(null)
const showConfirm = ref(false)
// Number of the row whose close is in flight (null when idle). While
// set, the confirm dialog stays up and every other row's Close is
// disabled.
const closingNumber = ref<number | null>(null)
// Forge sentences that arrived WITHOUT an error status:
// per-row `detail` for `{ closed: false }`.
const closeDetails = ref<Record<number, string>>({})
// Transport/command failure (`{ error }` from a rejected promise):
// one banner above the table, never a silent no-op.
const closeError = ref<string>('')
const toast = ref<string>('')
let toastTimer: ReturnType<typeof setTimeout> | null = null

const askClose = (row: GitPrListItem): void => {
  if (closingNumber.value !== null) return
  delete closeDetails.value[row.number]
  closeError.value = ''
  confirmRow.value = row
  showConfirm.value = true
}

const onConfirmDialogClose = (): void => {
  if (closingNumber.value !== null) return
  showConfirm.value = false
  confirmRow.value = null
}

const runClose = (row: GitPrListItem): void => {
  closingNumber.value = row.number
  closeError.value = ''
  closePr(props.itemPath, String(row.number), { provider: provider.value || undefined }).then(
    (resp) => {
      closingNumber.value = null
      showConfirm.value = false
      confirmRow.value = null
      if (resp.closed) {
        if (state.value.kind === 'ready') {
          const next = state.value.rows.filter((r) => r.number !== row.number)
          state.value = { ...state.value, rows: next }
          tabCounts.value = {
            ...tabCounts.value,
            [props.tab]: next.length,
          }
          if (props.tab === 'open') emit('openCount', next.length)
        }
        emit('closed', { number: row.number, headRef: row.head_ref })
        toast.value = `Closed #${row.number} · ${row.head_ref}`
        if (toastTimer !== null) clearTimeout(toastTimer)
        toastTimer = setTimeout(() => {
          toast.value = ''
          toastTimer = null
        }, 4000)
      } else {
        // The forge accepted the command but the re-read still
        // shows it open: render the forge's own sentence, keep
        // the row where it was.
        closeDetails.value = {
          ...closeDetails.value,
          [row.number]: resp.detail || 'The forge left it open.',
        }
      }
    },
    (err: unknown) => {
      closingNumber.value = null
      showConfirm.value = false
      confirmRow.value = null
      closeError.value = errorSentence(err)
    },
  )
}

const onConfirmDialogConfirm = (): void => {
  // The dialog emits `close` right after `confirm`; the close
  // handler ignores it while a close is in flight so the dialog
  // stays up until the forge answers.
  const row = confirmRow.value
  if (!row || closingNumber.value !== null) return
  runClose(row)
}

const retryClose = (row: GitPrListItem): void => {
  delete closeDetails.value[row.number]
  closeError.value = ''
  runClose(row)
}

onUnmounted(() => {
  if (toastTimer !== null) clearTimeout(toastTimer)
})

const confirmMessage = computed(() => {
  const row = confirmRow.value
  if (!row) return ''
  return (
    `Close ${wording.value.noun} #${row.number} "${row.title}" (${row.head_ref} → ${row.base_ref}) ` +
    `on ${wording.value.forge}? The branch, the worktree and the board card are untouched — ` +
    `and the card does not move columns.`
  )
})
</script>

<template>
  <section
    data-testid="kanban-pr-list-panel"
    class="flex flex-col h-full min-h-0"
    style="color: var(--semantic-text)"
    :aria-label="pluralLabel"
  >
    <!-- Header -->
    <header
      class="flex items-center gap-2 px-3 py-2 shrink-0 flex-wrap"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <button
        type="button"
        class="text-body hover:opacity-80 transition-opacity"
        style="color: var(--color-violet); background: none; border: none; cursor: pointer"
        @click="emit('back')"
      >
        ‹ Back to board
      </button>
      <UiIcon name="pr" />
      <h3 class="text-body font-semibold">{{ pluralLabel }}</h3>
      <ForgeIcon :provider="provider || undefined" />
      <span
        v-if="state.kind === 'ready' && state.detail"
        class="text-dense"
        style="color: var(--semantic-text-dim)"
      >
        {{ state.detail }}
      </span>
      <span class="ml-auto flex items-center gap-2">
        <button
          type="button"
          data-testid="pr-list-refresh"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          title="Ask the forge again"
          @click="load"
        >
          <span aria-hidden="true">↻</span><span class="ml-1">Refresh</span>
        </button>
        <button
          v-if="newCrUrl"
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :title="`Open the forge's new change-request page`"
          @click="openNewCr"
        >
          {{ newCrLabel }}
        </button>
      </span>
    </header>

    <!-- Tab strip -->
    <div
      class="flex items-center gap-1 px-3 pt-2 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
      role="tablist"
      aria-label="Change-request state"
    >
      <button
        type="button"
        role="tab"
        data-testid="pr-tab-open"
        :aria-selected="props.tab === 'open'"
        class="px-2 py-1 text-dense"
        style="
          background: none;
          border: none;
          border-bottom: 2px solid transparent;
          cursor: pointer;
        "
        :style="
          props.tab === 'open'
            ? 'color: var(--semantic-text); border-bottom-color: var(--color-violet);'
            : 'color: var(--semantic-text-dim);'
        "
        @click="emit('tabChange', 'open')"
      >
        Open<span v-if="tabCounts.open !== null"> {{ tabCounts.open }}</span>
      </button>
      <button
        type="button"
        role="tab"
        data-testid="pr-tab-closed"
        :aria-selected="props.tab === 'closed'"
        class="px-2 py-1 text-dense"
        style="
          background: none;
          border: none;
          border-bottom: 2px solid transparent;
          cursor: pointer;
        "
        :style="
          props.tab === 'closed'
            ? 'color: var(--semantic-text); border-bottom-color: var(--color-violet);'
            : 'color: var(--semantic-text-dim);'
        "
        @click="emit('tabChange', 'closed')"
      >
        Closed<span v-if="tabCounts.closed !== null"> {{ tabCounts.closed }}</span>
      </button>
      <span class="ml-auto text-micro pb-1" style="color: var(--semantic-text-dim)">
        <template v-if="state.kind === 'ready'">
          via {{ state.program || wording.program }} · checked {{ checkedLabel }}
        </template>
      </span>
    </div>

    <!-- Filter + meta -->
    <div
      v-if="state.kind === 'ready'"
      class="flex items-center gap-2 px-3 py-2 shrink-0 flex-wrap"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <button
        type="button"
        data-testid="pr-only-this-board"
        :aria-pressed="onlyThisBoard"
        class="px-2 py-1 rounded text-dense font-medium transition-opacity"
        style="border: 1px solid var(--color-border); cursor: pointer"
        :style="
          onlyThisBoard
            ? 'background-color: var(--color-violet); color: var(--color-bg); border-color: var(--color-violet);'
            : 'background-color: transparent; color: var(--semantic-text-muted);'
        "
        :title="`Show only change requests whose branch has a card on this board`"
        @click="onlyThisBoard = !onlyThisBoard"
      >
        Only this board · {{ onBoardRows.length }} of {{ rows.length }}
      </button>
      <button
        v-if="onlyThisBoard && hiddenCount > 0"
        type="button"
        data-testid="pr-list-show-all"
        class="text-dense hover:opacity-80 transition-opacity"
        style="color: var(--color-violet); background: none; border: none; cursor: pointer"
        @click="onlyThisBoard = false"
      >
        show all {{ rows.length }} ({{ hiddenCount }} hidden)
      </button>
      <span v-if="state.truncated" class="text-micro" style="color: var(--semantic-text-dim)">
        showing first {{ rows.length }} — narrow the filter on the forge for the rest
      </span>
    </div>

    <!-- Close-failure banner (transport/command failure — above the table) -->
    <div
      v-if="closeError"
      data-testid="pr-close-error"
      class="mx-3 mt-2 px-3 py-2 rounded text-body shrink-0 flex items-center gap-2 flex-wrap"
      style="
        border: 1px solid var(--color-red);
        background-color: var(--semantic-card-bg);
        color: var(--semantic-text);
      "
      role="alert"
    >
      <span class="flex-1">{{ closeError }}</span>
      <button
        type="button"
        class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
        style="border: 1px solid var(--color-border); color: var(--semantic-text-muted)"
        @click="load"
      >
        <span aria-hidden="true">↻</span><span class="ml-1">Retry</span>
      </button>
    </div>

    <!-- Body -->
    <div class="flex-1 min-h-0 overflow-y-auto">
      <!-- Loading skeleton -->
      <div v-if="state.kind === 'loading'" data-testid="pr-list-loading" class="px-3 py-2">
        <div
          v-for="i in [1, 2, 3, 4]"
          :key="i"
          class="py-2"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <div
            class="rounded"
            style="height: 11px; width: 70%; background-color: var(--semantic-sidebar-bg)"
          />
          <div
            class="rounded mt-2"
            style="height: 11px; width: 40%; background-color: var(--semantic-sidebar-bg)"
          />
        </div>
      </div>

      <!-- Error — visibly different from empty: an icon, who could not
           be asked, the forge's sentence, and Retry -->
      <div
        v-else-if="state.kind === 'failed'"
        data-testid="pr-list-error"
        class="px-4 py-8 text-center"
      >
        <div
          class="mx-auto mb-3 flex items-center justify-center rounded-lg"
          style="
            width: 34px;
            height: 34px;
            border: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
            color: var(--semantic-text-dim);
          "
          aria-hidden="true"
        >
          <UiIcon name="pr" :size="18" />
        </div>
        <p class="text-lead font-semibold">{{ wording.forge }} could not be asked</p>
        <p class="text-body mt-1" style="color: var(--semantic-text-dim)">{{ state.message }}</p>
        <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
          The list is unknown, not empty — nothing below this line is a claim about your
          {{ pluralLabel.toLowerCase() }}.
        </p>
        <button
          type="button"
          class="mt-3 px-3 py-1.5 rounded text-body font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          @click="load"
        >
          <span aria-hidden="true">↻</span><span class="ml-1">Retry</span>
        </button>
      </div>

      <!-- Empty — only when the forge answered with zero rows -->
      <div
        v-else-if="visibleRows.length === 0 && rows.length === 0"
        data-testid="pr-list-empty"
        class="px-4 py-8 text-center"
      >
        <div
          class="mx-auto mb-3 flex items-center justify-center rounded-lg"
          style="
            width: 34px;
            height: 34px;
            border: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
            color: var(--semantic-text-dim);
          "
          aria-hidden="true"
        >
          <UiIcon name="pr" :size="18" />
        </div>
        <p class="text-lead font-semibold">No {{ tab }} {{ pluralLabel.toLowerCase() }}</p>
        <p class="text-body mt-1" style="color: var(--semantic-text-dim)">
          The forge answered: {{ itemPath }} has no {{ tab }} change requests.
        </p>
      </div>

      <!-- Filtered-to-zero (distinct from empty: the forge DID answer) -->
      <div
        v-else-if="visibleRows.length === 0"
        data-testid="pr-list-empty"
        class="px-4 py-8 text-center"
      >
        <p class="text-lead font-semibold">None on this board</p>
        <p class="text-body mt-1" style="color: var(--semantic-text-dim)">
          {{ rows.length }} {{ tab }} {{ pluralLabel.toLowerCase() }} on the forge, none whose
          branch has a card here.
        </p>
        <button
          type="button"
          class="mt-3 px-3 py-1.5 rounded text-body font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          @click="onlyThisBoard = false"
        >
          Show all {{ rows.length }}
        </button>
      </div>

      <!-- Rows -->
      <ul v-else class="list-none m-0 p-0">
        <li
          v-for="row in visibleRows"
          :key="row.number"
          :data-testid="`pr-list-row-${row.number}`"
          class="px-3 py-2"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-dense mono" style="color: var(--semantic-text-dim)">
              #{{ row.number }}
            </span>
            <ForgeIcon :provider="provider || undefined" size-class="w-4 h-4" />
            <span class="text-body font-medium flex-1 min-w-0 truncate">{{ row.title }}</span>
            <span
              v-if="row.is_draft"
              class="text-micro px-2 py-0.5 rounded-full"
              style="border: 1px solid var(--color-border); color: var(--semantic-text-dim)"
            >
              draft
            </span>
            <span class="text-micro" style="color: var(--semantic-text-dim)">
              {{ relTime(row.updated_at) }}
            </span>
          </div>
          <div class="flex items-center gap-2 mt-1 flex-wrap">
            <span
              class="text-dense mono px-1.5 rounded"
              style="
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
                max-width: 100%;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
              "
              :title="`${row.head_ref} → ${row.base_ref}`"
            >
              {{ row.head_ref }} → {{ row.base_ref }}
            </span>
            <span
              v-if="taskForRow(row)"
              class="text-dense px-2 py-0.5 rounded"
              style="border: 1px solid var(--color-border); color: var(--semantic-text-muted)"
            >
              {{ taskForRow(row)?.name }}
            </span>
            <span
              v-else
              class="text-dense px-2 py-0.5 rounded"
              style="border: 1px dashed var(--color-border); color: var(--semantic-text-dim)"
            >
              no card on this board
            </span>
            <span class="text-dense" style="color: var(--semantic-text-muted)">
              {{ row.author }}
            </span>
            <span class="ml-auto flex items-center gap-2">
              <button
                type="button"
                class="text-dense hover:opacity-80 transition-opacity"
                style="
                  color: var(--semantic-text-muted);
                  background: none;
                  border: none;
                  cursor: pointer;
                "
                :title="`Open #${row.number} on ${wording.forge}`"
                :aria-label="`Open #${row.number} on ${wording.forge}`"
                @click="openRowUrl(row)"
              >
                <span aria-hidden="true">↗</span>
              </button>
              <button
                type="button"
                class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity disabled:opacity-50"
                style="
                  background: transparent;
                  border: 1px solid var(--color-red);
                  color: var(--color-red);
                  cursor: pointer;
                "
                :disabled="closingNumber !== null"
                :title="`Close #${row.number} on ${wording.forge}`"
                @click="askClose(row)"
              >
                {{ closingNumber === row.number ? 'Closing…' : 'Close' }}
              </button>
            </span>
          </div>
          <!-- `{ closed: false }` — the forge's own sentence, row stays -->
          <div
            v-if="closeDetails[row.number]"
            :data-testid="`pr-close-detail-${row.number}`"
            class="mt-1 flex items-center gap-2 flex-wrap text-dense"
            style="color: var(--semantic-text-muted)"
            role="status"
          >
            <span class="flex-1">{{ closeDetails[row.number] }}</span>
            <button
              type="button"
              class="px-2 py-0.5 rounded text-dense hover:opacity-80 transition-opacity"
              style="border: 1px solid var(--color-border); color: var(--semantic-text-muted)"
              @click="retryClose(row)"
            >
              <span aria-hidden="true">↻</span><span class="ml-1">Retry</span>
            </button>
          </div>
        </li>
      </ul>
    </div>

    <!-- Toast -->
    <div
      v-if="toast"
      data-testid="pr-close-toast"
      class="mx-auto mb-3 px-3 py-1.5 rounded text-body shrink-0"
      style="
        border: 1px solid var(--color-border);
        background-color: var(--semantic-sidebar-bg);
        color: var(--semantic-text);
      "
      role="status"
      aria-live="polite"
    >
      {{ toast }}
    </div>

    <!-- Close confirm -->
    <div v-if="showConfirm" data-testid="pr-close-confirm">
      <ConfirmDialog
        :show="showConfirm"
        :title="`Close ${wording.noun} #${confirmRow?.number ?? ''}`"
        :message="confirmMessage"
        confirm-text="Close"
        cancel-text="Cancel"
        @close="onConfirmDialogClose"
        @confirm="onConfirmDialogConfirm"
      />
    </div>
  </section>
</template>

<style scoped>
.mono {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
}
</style>
