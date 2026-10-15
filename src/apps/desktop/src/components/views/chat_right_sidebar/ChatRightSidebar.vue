<script setup lang="ts">
import { ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import FolderExplorer from '../../file/FolderExplorer.vue'
import SidebarDiffPanel from './SidebarDiffPanel.vue'
import TerminalTab from './TerminalTab.vue'
import { useInjectOpenInCodeEditor } from '../../../composables/useCodeEditor'
import type { FolderEntry } from '../../../api'
import type { DiffSelection } from './parseUnifiedDiff'

const props = defineProps<{
  cwd: string
  open: boolean
  width: number
  minWidth?: number
  maxWidth?: number
  /**    * Branch from the bottom status bar (single source of truth). `undefined` while loading — the
   * panel falls back to its own fetched branch. Drilled from ChatView's `sidebarBranch`. */
  branch?: string
  /** Attached PR URL — switches the panel to PR-changes mode. */
  prUrl?: string
  /** Effective provider for the attached PR. */
  prProvider?: string
  /**    * Per-chat persistence key (ChatView's chatId). When set, terminal session ids persist in
   * localStorage and re-attach on return; without it sessions die with the tab (legacy behavior). */
  sessionKey?: string
}>()

const emit = defineEmits<{
  'update:open': [open: boolean]
  'update:width': [width: number]
  refresh: []
  'show-diff': [selection: DiffSelection]
  'show-diff-list': [files: DiffSelection[]]
}>()

const panelRef = ref<InstanceType<typeof SidebarDiffPanel> | null>(null)

const STORAGE_KEY_PANEL = 'pabrik-right-sidebar-panel'

type SidebarPanel = 'explorer' | 'changes' | 'terminal'

function readSidebarParam(): SidebarPanel | null {
  try {
    const params = new URLSearchParams(window.location.search)
    const q = params.get('sidebar')
    if (q === 'terminal' || q === 'changes' || q === 'explorer') return q
  } catch {
    // Non-browser (tests/SSR) — fall through.
  }
  return null
}

function loadPanel(): SidebarPanel {
  const q = readSidebarParam()
  if (q) return q
  try {
    const saved = localStorage.getItem(STORAGE_KEY_PANEL)
    if (saved === 'terminal' || saved === 'changes' || saved === 'explorer') return saved
  } catch {
    // Non-browser (tests/SSR) — fall through to default.
  }
  return 'explorer'
}

const activePanel = ref<SidebarPanel>(loadPanel())

// The rail. The panel's name is the active segment's own label, so there is
// no separate title row above it — one row of chrome instead of two. Glyphs
// are the app's existing vocabulary (no icon dependency); each is
// aria-hidden so a screen reader reads "Explorer", not "black square
// Explorer".
const PANEL_SEGMENTS: { id: SidebarPanel; glyph: string; label: string }[] = [
  { id: 'explorer', glyph: '▤', label: 'Explorer' },
  { id: 'changes', glyph: '⎇', label: 'Changes' },
  { id: 'terminal', glyph: '⌁', label: 'Terminal' },
]

// Router is optional: unit mounts (ChatRightSidebar.spec) have no router.
// Grab once at setup so setPanel can sync ?sidebar= without calling
// useRouter inside the click handler.
let router: ReturnType<typeof useRouter> | null = null
let route: ReturnType<typeof useRoute> | null = null
try {
  router = useRouter()
  route = useRoute()
} catch {
  router = null
  route = null
}

// Every view switch lands in the URL (?sidebar=explorer|changes|terminal)
// so refresh, Back/Forward, and shared links restore the same panel.
const setPanel = (panel: SidebarPanel) => {
  activePanel.value = panel
  try {
    localStorage.setItem(STORAGE_KEY_PANEL, panel)
  } catch {
    // ignore
  }
  if (router && route) {
    const query = { ...route.query, sidebar: panel }
    router.replace({ path: route.path, query }).catch(() => {})
  }
}

// Explorer file-click opens in the in-app CodeEditor (same flow as the center diff's Open button).
// Captured at setup: inject() only resolves during setup — calling it inside the click handler
// would return null. Null-guarded for mounts outside an AppLayout subtree (unit tests).
const openInEditor = useInjectOpenInCodeEditor()
const onExplorerFileClick = (file: FolderEntry) => {
  if (!openInEditor || !props.cwd) return
  void openInEditor({ filePath: file.path, fileName: file.name, cwd: props.cwd })
}

const isResizing = ref(false)

const startResize = (e: MouseEvent) => {
  e.preventDefault()
  isResizing.value = true
  const startX = e.clientX
  const startWidth = props.width
  const min = props.minWidth ?? 200
  const max = props.maxWidth ?? 600

  const onMove = (ev: MouseEvent) => {
    const next = startWidth - (ev.clientX - startX)
    emit('update:width', Math.max(min, Math.min(max, next)))
  }
  const onUp = () => {
    isResizing.value = false
    window.removeEventListener('mousemove', onMove)
    window.removeEventListener('mouseup', onUp)
  }
  window.addEventListener('mousemove', onMove)
  window.addEventListener('mouseup', onUp)
}

const close = () => emit('update:open', false)

// No cwd watcher here: SidebarDiffPanel already watches props.cwd itself (clears its tab cache +
// reloads). A second fetch from this level doubled every worktree switch and the two concurrent
// getGitChanges calls could resolve out of order (stale branch wins).

defineExpose({
  // Reload the panel's current tab (PR tab re-syncs merge state too).
  // Falls back to git status for older panel refs without refresh().
  refresh: () => {
    const panel = panelRef.value as unknown as {
      refresh?: () => unknown
      loadGitStatus?: () => unknown
    } | null
    if (panel?.refresh) return panel.refresh()
    return panel?.loadGitStatus?.()
  },
  reloadDiff: () => panelRef.value?.loadDiff(),
})
</script>

<template>
  <aside
    v-if="open"
    class="chat-right-sidebar shrink-0 h-full relative hidden lg:flex flex-col min-h-0"
    :style="{
      width: width + 'px',
      backgroundColor: 'var(--semantic-sidebar-bg)',
      borderLeft: '1px solid var(--color-border)',
    }"
    data-testid="chat-right-sidebar"
  >
    <div
      class="absolute left-0 top-0 bottom-0 w-1 cursor-col-resize hover:opacity-100 opacity-0 hover:bg-[var(--color-violet)]"
      style="background: transparent"
      data-testid="chat-right-sidebar-resize"
      @mousedown="startResize"
    />
    <!-- One rail: the switcher and the close button share a row, and the
         active segment's own label is the panel's title — the separate
         title row it replaces repeated that word a second time. -->
    <div
      class="flex items-center gap-1.5 px-2 h-11 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <div
        class="flex items-center gap-1 flex-1 min-w-0 h-full"
        role="tablist"
        aria-label="Right sidebar panel"
      >
        <button
          v-for="seg in PANEL_SEGMENTS"
          :key="seg.id"
          type="button"
          role="tab"
          :aria-selected="activePanel === seg.id"
          class="relative flex-1 min-w-0 h-8 rounded flex items-center justify-center gap-1.5 text-dense font-medium transition-colors duration-150"
          :style="
            activePanel === seg.id
              ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 0 -2px 0 0 var(--color-violet);'
              : 'color: var(--semantic-text-dim); background-color: transparent;'
          "
          :data-testid="`chat-right-sidebar-tab-${seg.id}`"
          @click="setPanel(seg.id)"
        >
          <span aria-hidden="true" class="shrink-0 opacity-70">{{ seg.glyph }}</span>
          <span class="truncate min-w-0">{{ seg.label }}</span>
        </button>
      </div>
      <button
        type="button"
        class="w-7 h-7 shrink-0 rounded flex items-center justify-center hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Close sidebar"
        aria-label="Close sidebar"
        data-testid="chat-right-sidebar-close"
        @click="close"
      >
        ✕
      </button>
    </div>
    <div class="flex-1 min-h-0">
      <!-- All three panels stay mounted (v-show, not v-if) so the PTY
      session survives tab switches; only the visible one paints. -->
      <div
        v-show="activePanel === 'explorer'"
        class="h-full min-h-0"
        data-testid="chat-right-sidebar-explorer"
      >
        <FolderExplorer :cwd="cwd" @file-click="onExplorerFileClick" />
      </div>
      <div v-show="activePanel === 'terminal'" class="h-full min-h-0">
        <TerminalTab :cwd="cwd" :session-key="sessionKey" />
      </div>
      <div v-show="activePanel === 'changes'" class="h-full min-h-0">
        <SidebarDiffPanel
          ref="panelRef"
          :cwd="cwd"
          :branch="branch"
          :pr-url="prUrl"
          :pr-provider="prProvider"
          @refresh="() => emit('refresh')"
          @show-diff="(selection) => emit('show-diff', selection)"
          @show-diff-list="(files) => emit('show-diff-list', files)"
        />
      </div>
    </div>
  </aside>
</template>
