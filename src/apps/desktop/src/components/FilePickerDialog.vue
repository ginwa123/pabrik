<!--
  FilePickerDialog — generic, data-source-agnostic modal file/folder picker.

  The component is generic over the item type `T`. Callers supply the data-source
  functions (loadItems / keyFor / pathFor / isExpandable) and the component owns
  every UX concern: the modal shell, breadcrumbs, two-pane tree + content layout,
  search, type filter, hidden-file toggle, keyboard navigation, body scroll lock,
  focus trap, focus restoration, loading/error/empty states.

  Agnostic by design: this works for files/folders, git branches, docker
  containers, or any tree-shaped dataset — just plug in the data source.

  Modes:
    - 'folder' : only folders can be selected; files are visible but inert
    - 'file'   : only files can be selected; folders are navigation only
    - 'both'   : either can be selected; chips filter the content pane

  Keyboard:
    Esc      : clear search, or close
    Enter    : select the highlighted item
    ↑ / ↓    : move highlight in content pane
    /        : focus search
    Backspace: go to parent path

  Cross-platform note (Windows fix, 2026-09-05): every path helper below
  accepts BOTH `/` and `\` separators and understands Windows absolutes
  (`C:\...`, `C:/...`, UNC `\\server\share`). The backend's listDirectory
  returns OS-native absolute paths (backslash-joined on Windows via
  std.fs.path.join). The old POSIX-only helpers mangled those into mixed
  shapes like `/Users\ginwa\...` (leading slash + backslashes, drive letter
  lost) — that malformed string was then persisted as workspace_items.path
  and flowed into sessions.cwd and the agent prompt. All helpers stay
  byte-identical to the old behavior for POSIX inputs; the Windows branches
  only trigger on drive-letter / UNC prefixes.
-->
<script setup lang="ts" generic="T">
import { ref, computed, nextTick, type Ref } from 'vue'
import { useRecentFoldersStore } from '../stores/recentFolders'
import UiIcon from './ui/UiIcon.vue'
import type { UiIconName } from './ui/icons'
import FilePickerTabStrip from './filePicker/FilePickerTabStrip.vue'
import FilePickerFooter from './filePicker/FilePickerFooter.vue'
import FilePickerAddressBar from './filePicker/FilePickerAddressBar.vue'
import FilePickerToolbar from './filePicker/FilePickerToolbar.vue'
import FilePickerBrowsePane from './filePicker/FilePickerBrowsePane.vue'
import FilePickerRecentTab from './filePicker/FilePickerRecentTab.vue'
import { useFilePickerRows, type FilterMode } from './filePicker/filePickerRows'
import { useFilePickerNav } from './filePicker/filePickerNav'
import { useFilePickerSelection } from './filePicker/filePickerSelection'
import { useFilePickerKeyboard } from './filePicker/filePickerKeyboard'
import { useFilePickerLifecycle } from './filePicker/filePickerLifecycle'
import { normalizeAddressInput } from './filePicker/pathUtils'

type Mode = 'folder' | 'file' | 'both'

// ─── Props ─────────────────────────────────────────────────────────────────
const props = defineProps<{
  modelValue: boolean
  mode?: Mode
  initialPath?: string
  title?: string

  /** Async fetcher for the children of `path`. */
  loadItems: (path: string) => Promise<T[]>
  /** Unique id used as Vue :key (often the path itself). */
  keyFor: (item: T) => string
  /** Absolute path of the item. */
  pathFor: (item: T) => string
  /** True if the item can be expanded in the tree (typically `is_directory`). */
  isExpandable: (item: T) => boolean
  /** Display name. Falls back to keyFor(). */
  labelFor?: (item: T) => string
  /** Secondary text (e.g. size, modified date). Falls back to ''. */
  subtitleFor?: (item: T) => string
  /** A key of the `UiIcon` registry. Falls back to `folder` / `file`
   *  based on isExpandable. */
  iconFor?: (item: T) => UiIconName

  showHidden?: boolean
  closeOnSelect?: boolean
  selectButtonText?: string
  /** Pre-select this path on open. */
  selectedPath?: string
  /** NEW: show the Recent tab + tabstrip. Pass `true` to enable (the default), omit to keep the
   * default, pass `false` to opt out for the single-pane tree. */
  enableRecentHistory?: boolean
}>()

// Defaults applied at use sites (avoid withDefaults quirks with function-typed optional props)
const mode = computed<Mode>(() => props.mode ?? 'folder')
// Windows-safe default: '' routes to getSystemFolder (home / %USERPROFILE%),
// '/' routes to listFolder('/'). No caller passes initialPath today, so the
// default IS the open path. POSIX keeps '/' (byte-identical), Windows gets ''.
const isWindowsPlatform =
  typeof navigator !== 'undefined' && /Win/i.test(navigator.platform || (navigator as unknown as { userAgent?: string }).userAgent || '')
const initialPath = computed(() => props.initialPath ?? (isWindowsPlatform ? '' : '/'))
const showHiddenDefault = computed(() => props.showHidden ?? false)
const selectLabel = computed(() => props.selectButtonText ?? 'Select')
// Default enableRecentHistory to true (Recent tab is the user's primary flow). Vue 3.5's runtime
// default for `boolean?` is `false`, so we treat `false` AND `undefined` as "use default" and
// `true` as "on".
const enableRecent = computed<boolean>(() =>
  props.enableRecentHistory === undefined ? true : !!props.enableRecentHistory,
)

// ─── Emits ─────────────────────────────────────────────────────────────────
const emit = defineEmits<{
  'update:modelValue': [value: boolean]
  'select': [path: string]
  'cancel': []
}>()

// ─── State ─────────────────────────────────────────────────────────────────
const dialogRef = ref<HTMLElement | null>(null)
const browsePane = ref<{ scrollToIndex: (index: number) => void } | null>(null)
const addressBar = ref<{ focusInput: () => void } | null>(null)
const toolbar = ref<{ searchInputEl: HTMLInputElement | null } | null>(null)

const currentPath = ref(initialPath.value)
const treeEntriesCache = ref<Record<string, T[]>>({})
const treeExpanded = ref<Record<string, boolean>>({})
const contentEntries = ref<T[]>([]) as Ref<T[]>
const isLoading = ref(false)
const loadError = ref<string | null>(null)
const selectedPath = ref<string>(props.selectedPath || '')
const highlightedIndex = ref<number>(-1)
const searchQuery = ref('')
const filterMode = ref<FilterMode>('all')
// Local toggle with prop default. The override captures user toggles;
// opening the dialog clears it so each open starts from the prop.
const showHiddenOverride = ref<boolean | null>(null)
const showHiddenLocal = computed<boolean>({
  get: () => showHiddenOverride.value ?? showHiddenDefault.value,
  set: (v: boolean) => {
    showHiddenOverride.value = v
  },
})
// ── Address-bar editing state ────────────────────────────────────────── When isPathEditing is
// true the clickable breadcrumb is replaced with a single text input pre-filled with currentPath.
// See beginPathEdit / commitPathEdit / cancelPathEdit below.
const isPathEditing = ref(false)
const pathDraft = ref('')



// ─── Data loading ──────────────────────────────────────────────────────────
async function loadPath(path: string): Promise<T[]> {
  isLoading.value = true
  loadError.value = null
  try {
    const items = await props.loadItems(path)
    treeEntriesCache.value = { ...treeEntriesCache.value, [path]: items }
    return items
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to load'
    loadError.value = msg
    console.error('[FilePickerDialog] loadPath failed for', path, err)
    return []
  } finally {
    isLoading.value = false
  }
}

const { expandAncestors, navigateTo, refreshCurrent, toggleTreeNode } = useFilePickerNav({
  loadPath,
  currentPath,
  selectedPath,
  highlightedIndex,
  searchQuery,
  contentEntries,
  treeExpanded,
  treeEntriesCache,
})

// ─── Selection ─────────────────────────────────────────────────────────────
const {
  handleItemClick,
  handleItemDoubleClick,
  handleSelect,
  handleCancel,
  effectiveSelection,
  canSelect,
  showCurrentFolderHint,
} = useFilePickerSelection({
  mode: () => mode.value,
  currentPath,
  selectedPath,
  pathFor: props.pathFor,
  isExpandable: props.isExpandable,
  navigateTo,
  addRecent: (path) => recentStore.addRecent(path),
  closeOnSelect: () => !!props.closeOnSelect,
  emitSelect: (path) => emit('select', path),
  emitClose: () => emit('update:modelValue', false),
  emitCancel: () => emit('cancel'),
})

// ─── Tab state (Recent / Browse) ───────────────────────────────────────────── Default: Recent.
// The Recent tab is the user's primary path — most-of-the-time they pick a folder they've picked
// before. The Browse tab is the power-user / unfamiliar-folder flow.
const activeTab = ref<'recent' | 'browse'>('recent')
const recentStore = useRecentFoldersStore()
const recentList = computed(() => recentStore.list())
const recentCount = computed(() => recentList.value.length)


function handleRecentRowClick(path: string): void {
  selectedPath.value = path
  handleSelect()
}

function handleRecentPinClick(path: string): void {
  recentStore.togglePin(path)
}


const { filteredContent, treeFlat } = useFilePickerRows({
  contentEntries,
  treeEntriesCache,
  treeExpanded,
  filterMode,
  showHidden: showHiddenLocal,
  searchQuery,
  pathFor: props.pathFor,
  keyFor: props.keyFor,
  isExpandable: props.isExpandable,
  labelFor: props.labelFor,
  subtitleFor: props.subtitleFor,
  iconFor: props.iconFor,
})

// ─── Keyboard ──────────────────────────────────────────────────────────────
function scrollHighlightedIntoView() {
  nextTick(() => browsePane.value?.scrollToIndex(highlightedIndex.value))
}

const { handleKeydown } = useFilePickerKeyboard({
  dialogRef,
  searchInputEl: () => toolbar.value?.searchInputEl ?? null,
  isPathEditing,
  searchQuery,
  currentPath,
  highlightedIndex,
  filteredContent,
  effectiveSelection,
  canSelect,
  navigateTo,
  handleItemClick,
  handleSelect,
  handleCancel,
  commitPathEdit,
  cancelPathEdit,
  scrollHighlightedIntoView,
})

// ─── Address-bar enter / exit / commit ───────────────────────────────────── beginPathEdit swaps
// the breadcrumb <span> tree for a single <input> pre-filled with currentPath, then auto-focuses +
// selects so the user can start typing (or paste) immediately. commitPathEdit normalizes the typed.
function beginPathEdit() {
  pathDraft.value = currentPath.value
  isPathEditing.value = true
  // Defer focus until after Vue has committed the conditional v-if swap.
  nextTick(() => addressBar.value?.focusInput())
}

function commitPathEdit() {
  const normalized = normalizeAddressInput(pathDraft.value, currentPath.value)
  isPathEditing.value = false
  if (normalized === null) {
    // Empty / whitespace → no-op, just close the editor.
    pathDraft.value = ''
    return
  }
  pathDraft.value = ''
  void navigateTo(normalized)
}

function cancelPathEdit() {
  isPathEditing.value = false
  pathDraft.value = ''
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────
useFilePickerLifecycle({
  modelValue: () => props.modelValue,
  selectedPathProp: () => props.selectedPath || '',
  initialPath: () => initialPath.value,
  currentPath,
  treeEntriesCache,
  treeExpanded,
  contentEntries,
  selectedPath,
  searchQuery,
  highlightedIndex,
  filterMode,
  showHiddenOverride,
  isPathEditing,
  pathDraft,
  loadError,
  activeTab,
  expandAncestors,
  focusSearch: () => toolbar.value?.searchInputEl?.focus(),
})

</script>

<template>
  <Teleport to="body">
    <Transition name="fp-modal">
      <div
        v-if="modelValue"
        ref="dialogRef"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="file-picker-title"
      >
        <!-- Backdrop with subtle radial atmosphere.
          NOTE: no @click handler here — clicking outside the dialog
          must NOT close it (accidental backdrop clicks used to lose
          the user's navigation state). Close only via X / Cancel / Esc. -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="
            background:
              radial-gradient(at top, rgba(137, 146, 167, 0.08), rgba(0, 0, 0, 0.6) 60%);
          "
          data-testid="file-picker-backdrop"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-3xl rounded-xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35),
              0 24px 64px rgba(137, 146, 167, 0.06);
            max-height: min(80vh, 720px);
            min-height: 480px;
          "
          data-testid="file-picker-dialog"
        >
          <!-- Hairline gradient accent on top edge -->
          <div
            class="absolute top-0 left-0 right-0 h-px pointer-events-none"
            style="
              background: linear-gradient(
                90deg,
                transparent,
                var(--color-violet),
                var(--color-blue),
                transparent
              );
            "
          />

          <!-- Header -->
          <div
            class="px-5 py-3 flex items-center justify-between shrink-0"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <h2
              id="file-picker-title"
              class="text-body font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <UiIcon name="folder-open" />
              <slot name="header">
                {{ title || (mode === 'file' ? 'Select File' : mode === 'both' ? 'Select Item' : 'Select Folder') }}
              </slot>
            </h2>
            <button
              @click="handleCancel"
              data-testid="file-picker-close"
              class="p-1 rounded transition-opacity hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              aria-label="Close"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <!--
            Breadcrumb / address bar.

            Normal mode: shows the path as clickable segments (the
            existing UX — clicking a segment navigates there).

            Edit mode: clicking the "✏️ Go" button (or pressing its
            shortcut) replaces the breadcrumb with a single text input
            pre-filled with the current path. Enter navigates, Escape
            reverts. Whatever the user types goes through
            normalizeAddressInput() so e.g. a bare "docs" jumps into
            currentPath/docs instead of being rejected as relative.
          -->
          <FilePickerAddressBar
            ref="addressBar"
            :current-path="currentPath"
            :is-path-editing="isPathEditing"
            v-model:pathDraft="pathDraft"
            @navigate="navigateTo"
            @begin-edit="beginPathEdit"
            @commit="commitPathEdit"
            @cancel="cancelPathEdit"
          />

          <!--
            Tab strip (Recent / Browse). Sits between the breadcrumb and
            the toolbar. Active tab is underlined violet. The default tab is
            `recent` for the user's
            primary flow. The toolbar (search + hidden + refresh) is
            visible only under Browse — Recent has no use for it.

            The strip uses `flex-1` on a spacer so the two tabs stay
            left-aligned regardless of breadcrumb width. The right
            side is reserved for the keyboard hint chip so the strip
            never collides with the breadcrumb's right edge.
          -->
          <FilePickerTabStrip
            v-if="enableRecent"
            v-model:activeTab="activeTab"
            :recent-count="recentCount"
          />

          <!-- Toolbar (Browse only) -->
          <FilePickerToolbar
            v-if="!enableRecent || activeTab === 'browse'"
            ref="toolbar"
            :show-filters="mode === 'both'"
            v-model:filterMode="filterMode"
            v-model:showHidden="showHiddenLocal"
            v-model:searchQuery="searchQuery"
            @refresh="refreshCurrent"
          >
            <template #toolbar>
              <slot name="toolbar" />
            </template>
          </FilePickerToolbar>

          <!-- Two-pane body (Browse only) -->
          <FilePickerBrowsePane
            v-if="!enableRecent || activeTab === 'browse'"
            ref="browsePane"
            v-model:highlightedIndex="highlightedIndex"
            :tree-rows="treeFlat"
            :entries="filteredContent"
            :current-path="currentPath"
            :selected-path="selectedPath"
            :content-entry-count="contentEntries.length"
            :is-loading="isLoading"
            :load-error="loadError"
            :search-query="searchQuery"
            :tree-expanded="treeExpanded"
            :key-for="props.keyFor"
            @navigate="navigateTo"
            @toggle="toggleTreeNode"
            @refresh="refreshCurrent"
            @item-click="handleItemClick"
            @item-double-click="handleItemDoubleClick"
          >
            <template v-if="$slots.empty" #empty>
              <slot name="empty" />
            </template>
            <template v-if="$slots.item" #item="slotProps">
              <slot name="item" v-bind="slotProps" />
            </template>
          </FilePickerBrowsePane>

          <!--
            Recent tab body. A flat list of cards, each row is a folder
            the user has picked before. The row is a single <button> for
            keyboard nav (Tab-able, Enter to select). The star toggles
            pin. The body scroll is contained in the
            [data-testid="file-picker-recent-list"] wrapper.
          -->
          <FilePickerRecentTab
            v-if="enableRecent && activeTab === 'recent'"
            @select-row="handleRecentRowClick"
            @pin="handleRecentPinClick"
            @browse="activeTab = 'browse'"
          />

          <!-- Footer -->
          <FilePickerFooter
            :effective-selection="effectiveSelection"
            :show-current-folder-hint="showCurrentFolderHint"
            :can-select="canSelect"
            :select-label="selectLabel"
            @cancel="handleCancel"
            @select="handleSelect"
          >
            <template #footer>
              <slot name="footer" />
            </template>
          </FilePickerFooter>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal entry/exit animation — spring-style scale + fade */
.fp-modal-enter-active,
.fp-modal-leave-active {
  transition: opacity 0.2s ease;
}

.fp-modal-enter-from,
.fp-modal-leave-to {
  opacity: 0;
}

.fp-modal-enter-active > div:last-child,
.fp-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.fp-modal-enter-from > div:last-child,
.fp-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>