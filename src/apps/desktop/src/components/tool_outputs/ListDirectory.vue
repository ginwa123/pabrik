<!--
  ListDirectory — tool output component for the `list_directory` agent tool.

  Renders the XML envelope produced by `execute_list_directory` +
  `toXml` in `src/modules/agent/tools/list_directory.zig`. The component
  is purely presentational: no API calls, no store mutations, no
  navigation.

  Three response shapes are possible (inner data extracted by
  `ChatView.innerToolData`, so this component receives the inner
  `<directory_listing>...</directory_listing>` body):

    Success with entries:
      <directory_listing path="/proj" count="3">
        <directory name="src"      path="/proj/src"      is_symlink="false"/>
        <file     name="README.md" path="/proj/README.md" is_symlink="false"/>
        <file     name="main.zig"  path="/proj/main.zig"  is_symlink="false"/>
      </directory_listing>
    Empty directory (count=0):
      <directory_listing path="/empty" count="0"></directory_listing>
    Error (innerToolData falls back to the full <tool> envelope):
      <tool><name>list_directory</name>...
        <success>false</success><error>list_directory failed: PathNotFound</error>
      </tool>

  Header (always visible):
    `list_directory → <path> · <count> entry(ies) ✓` (success)
    `list_directory → <path> · error ✗`            (failure)

  Expanded body (click header to toggle):
    Success: one row per entry. Directories render with a folder icon,
    files with a file icon. Symlinks show a `→` marker.
    Each row carries copy-path + open-in-editor buttons (on hover).
    Error:   Red error block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (ReadFile, Search, Glob): monospace, rounded-md, border + soft card
  bg, violet tool-name, ✗/✓ status indicators, expand/collapse `+`/`−`
  toggle on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { normalizeToolContent, parseListDirectory } from './_shared/toolOutputParser'
import ToolParameters from './_shared/ToolParameters.vue'
import { extractParam } from '@/helpers/extractParam'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

// Single parser pass — reuses the typed `ParsedListDirectory` from the
// project-wide parser. Handles both the inner-data shape and the
// outer-<tool>-envelope error fallback (see ChatView.innerToolData).
const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseListDirectory(normalized.value.data)
  if (normalized.value.error) {
    return { ...p, success: false, error: normalized.value.error }
  }
  return p
})

// ---- Derived display values ------------------------------------------------
const contentPath = computed((): string | null => {
  const v = parsed.value.path
  return v && v.trim() !== '' ? v : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return isEmptyContent(props.content) && displayPath.value !== null
})

const path = computed(() => displayPath.value)
const count = computed(() => parsed.value.count)
const entries = computed(() => parsed.value.entries)
const errorMessage = computed(() => parsed.value.error)

// Singular vs plural: "1 entry" / "0 entries" / "N entries". The backend's `count` attribute is the
// source of truth — if a stale envelope ever has `<count>` but no entries (or vice versa), we still
// pick the grammar based on `count`.
const countLabel = computed(() => {
  const n = count.value
  return `${n} ${n === 1 ? 'entry' : 'entries'}`
})

const isSuccess = computed(() => parsed.value.success)
const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

// Header label: "<path> · <count> entries" on success, "error" on failure.
const headerLabel = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? 'error'
  return path.value ?? 'unknown'
})

// Hover title: the full path (no truncation) on success; the error
// message on failure.
const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  return path.value ?? ''
})

// ─── Interactions ──────────────────────────────────────────────────────────
const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyPath = async (e: Event, fullPath: string) => {
  e.stopPropagation()
  try {
    await navigator.clipboard.writeText(fullPath)
  } catch {
    // ignore — clipboard may be blocked in jsdom tests
  }
}

const openInEditorClick = (e: Event, fullPath: string) => {
  e.stopPropagation()
  if (!openInEditor || !props.cwd) return
  openInEditor({ filePath: fullPath, cwd: props.cwd })
}

// Per-row icon: `folder` for directories, `file` for files. The symlink marker is a separate `→` in
// the template — it is typographic text, not an icon, and stays outside the registry. Matches the
// visual conventions of `ls -F` / `eza`.
const rowIcon = (entry: { isDirectory: boolean }): UiIconName =>
  entry.isDirectory ? 'folder' : 'file'

const rowKind = (entry: { isDirectory: boolean }) => (entry.isDirectory ? 'directory' : 'file')

const canOpenInEditor = computed(() => !!props.cwd && !!openInEditor)
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess }"
    data-testid="list-directory"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      role="button"
      tabindex="0"
      @click="toggle"
      @keydown.enter.prevent="toggle"
      @keydown.space.prevent="toggle"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense shrink-0">list_directory</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text)] text-dense"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>
      <span class="text-[var(--semantic-text-muted)] text-micro shrink-0">{{ countLabel }}</span>
      <span v-if="isRunning" data-testid="list-directory-running" class="text-micro text-yellow-500 animate-pulse">running…</span>
      <span
        class="text-dense font-semibold shrink-0"
        :class="isSuccess ? 'text-green-500' : 'text-red-500'"
      >
        {{ statusIndicator }}
      </span>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body shrink-0">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div
        v-if="!isSuccess && errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="list-directory-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path: one row per entry -->
      <template v-if="isSuccess">
        <div v-if="entries.length === 0" class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic" data-testid="list-directory-empty">
          (empty directory)
        </div>

        <div
          v-for="(entry, idx) in entries"
          :key="`${entry.name}-${idx}`"
          class="group/row flex items-center gap-1 px-2 py-1 border-b border-dashed border-[var(--color-border)] last:border-b-0 hover:bg-violet-500/5"
          :data-testid="'list-directory-row'"
          :data-kind="rowKind(entry)"
          :data-is-symlink="entry.isSymlink ? 'true' : 'false'"
        >
          <span
            class="min-w-4 text-center text-[var(--semantic-text-muted)] text-meta shrink-0 inline-flex items-center justify-center gap-0.5"
            aria-hidden="true"
          >
            <UiIcon :name="rowIcon(entry)" class="w-3.5 h-3.5" />
            <template v-if="entry.isSymlink">→</template>
          </span>
          <span
            class="flex-1 truncate text-[var(--semantic-text)] text-meta"
            :title="entry.path"
          >{{ entry.name }}</span>
          <span
            class="text-[var(--semantic-text-dim)] text-micro truncate max-w-[40%] hidden group-hover/row:inline"
            :title="entry.path"
          >{{ entry.path }}</span>
          <button
            class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover/row:opacity-100 hover:!text-violet-500 text-lead transition-opacity shrink-0"
            @click="(e) => copyPath(e, entry.path)"
            :title="`Copy ${entry.path}`"
            data-testid="list-directory-copy-path"
          >⎘</button>
          <button
            v-if="canOpenInEditor"
            class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover/row:opacity-100 hover:!text-violet-500 transition-opacity shrink-0"
            @click="(e) => openInEditorClick(e, entry.path)"
            title="Open in code editor"
          >
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
            </svg>
          </button>
        </div>
      </template>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>