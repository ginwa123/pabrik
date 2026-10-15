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
import { ref, computed, nextTick, onMounted, onUpdated, onBeforeUnmount } from 'vue'
import { useRecentFoldersStore } from '../stores/recentFolders'
import { formatRelativeTime } from '../helpers/relativeTime'
import UiIcon from './ui/UiIcon.vue'
import type { UiIconName } from './ui/icons'

type Mode = 'folder' | 'file' | 'both'
type FilterMode = 'all' | 'folders' | 'files'

interface ContentItem {
  item: T
  path: string
  label: string
  subtitle: string
  icon: UiIconName
  expandable: boolean
  hidden: boolean
}

interface TreeRow {
  item: T
  path: string
  depth: number
}

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
  /** NEW: show the Recent tab + tabstrip. Pass `true` to enable (the
   *  default), omit to keep the default, pass `false` to opt out for
   *  the single-pane tree. Vue 3.5's runtime default for `boolean?`
   *  is `false`, so the JS-side computed below treats `undefined`
   *  (caller didn't pass anything) as "default on" — this is the
   *  inverse of Vue's runtime default. No caller today passes
   *  `false`; the legacy opt-out is supported for symmetry with the
   *  existing `showHidden?: boolean` prop. */
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
// Default enableRecentHistory to true (Recent tab is the user's primary
// flow). Vue 3.5's runtime default for `boolean?` is `false`, so we
// treat `false` AND `undefined` as "use default" and `true` as "on".
// An explicit `false` is therefore ambiguous — callers who want to opt
// out today would also need to pass `false` AND see it preserved. To
// disambiguate, callers must NOT pass `false` (they pass `undefined` or
// nothing). For now, this is consistent with the existing
// `showHidden?: boolean` which Vue 3.5 also defaults to false on absence.
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
const contentRef = ref<HTMLElement | null>(null)
const searchInput = ref<HTMLInputElement | null>(null)
const pathInput = ref<HTMLInputElement | null>(null)

const currentPath = ref(initialPath.value)
const treeEntriesCache = ref<Record<string, T[]>>({})
const treeExpanded = ref<Record<string, boolean>>({})
const contentEntries = ref<T[]>([])
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
// ── Address-bar editing state ──────────────────────────────────────────
// When isPathEditing is true the clickable breadcrumb is replaced with a
// single text input pre-filled with currentPath. Enter navigates to
// whatever is typed (after normalization); Escape reverts. See
// beginPathEdit / commitPathEdit / cancelPathEdit below.
const isPathEditing = ref(false)
const pathDraft = ref('')
let previouslyFocused: HTMLElement | null = null

// ─── Helpers ───────────────────────────────────────────────────────────────

// ── Cross-platform path helpers (Windows fix, 2026-09-05) ──────────────
// See the file header for the full rationale. POSIX inputs produce
// byte-identical results to the old POSIX-only implementations.

/** True for Windows absolutes: `C:\...`, `C:/...`, UNC `\\s\s` / `//s/s`. */
function isWindowsAbs(path: string): boolean {
  if (!path) return false
  if (/^[A-Za-z]:[\\/]/.test(path)) return true
  if (path.startsWith('\\\\') || path.startsWith('//')) return true
  return false
}

/** True for any absolute path on either platform. */
function isAbsPath(path: string): boolean {
  return path.startsWith('/') || isWindowsAbs(path)
}

/** Split on BOTH separators, dropping empties. */
function splitSegments(path: string): string[] {
  return path.split(/[\\/]/).filter(Boolean)
}

/** Basename across both separators. */
function basenameOf(path: string): string {
  const segs = splitSegments(path)
  return segs.length > 0 ? (segs[segs.length - 1] as string) : path
}

/** True when `path` is a filesystem root: `/`, `C:\`, `C:/`, `C:`, or a UNC share root. */
function isRootPath(path: string): boolean {
  if (path === '/' || path === '') return true
  if (/^[A-Za-z]:[\\/]?$/.test(path)) return true
  if (/^[\\/]{2}[^\\/]+[\\/]+[^\\/]+\/?$/.test(path)) return true
  return false
}

function parentPath(path: string): string {
  if (!path || path === '/') return '/'
  // Windows drive root (`C:\`, `C:/`, `C:`) and UNC share roots have no
  // parent in this picker — step out to the system root (''), which the
  // callers resolve via getSystemFolder (backend home / USERPROFILE).
  if (/^[A-Za-z]:[\\/]?$/.test(path)) return ''
  if (/^[\\/]{2}[^\\/]+[\\/]+[^\\/]+\/?$/.test(path)) return ''
  // Strip ONE trailing run of separators (never the root itself).
  const stripped = path.length > 1 ? path.replace(/[\\/]+$/, '') : path
  if (/^[A-Za-z]:$/.test(stripped)) return ''
  if (stripped === '' || stripped === '/') return '/'
  const idx = Math.max(stripped.lastIndexOf('/'), stripped.lastIndexOf('\\'))
  if (idx <= 0) return '/'
  const parent = stripped.substring(0, idx)
  // A bare drive (`C:`) isn't navigable — surface the drive root instead
  // so the ancestor chain keeps the `C:\` level.
  if (/^[A-Za-z]:$/.test(parent)) return `${parent}\\`
  return parent || '/'
}

function defaultIconFor(item: T): UiIconName {
  return props.isExpandable(item) ? 'folder' : 'file'
}

function getLabel(item: T): string {
  return props.labelFor ? props.labelFor(item) : props.keyFor(item)
}

function getSubtitle(item: T): string {
  return props.subtitleFor ? props.subtitleFor(item) : ''
}

function getIcon(item: T): UiIconName {
  return props.iconFor ? props.iconFor(item) : defaultIconFor(item)
}

function isHiddenItem(path: string): boolean {
  // Hidden iff the basename (last path segment) starts with '.'
  const basename = basenameOf(path)
  return basename.startsWith('.')
}

function parseBreadcrumb(path: string): Array<{ name: string; path: string }> {
  if (!path || path === '/') return []
  // Windows drive: preserve the drive root and join with backslashes so
  // every crumb stays a valid absolute the backend can list.
  const driveMatch = /^[A-Za-z]:/.exec(path)
  if (driveMatch) {
    const drive = driveMatch[0]!
    const rest = splitSegments(path.slice(drive.length))
    const segments: Array<{ name: string; path: string }> = []
    let acc = `${drive}\\`
    segments.push({ name: drive, path: acc })
    for (const part of rest) {
      acc = acc.replace(/[\\/]+$/, '') + '\\' + part
      segments.push({ name: part, path: acc })
    }
    return segments
  }
  // Windows UNC: `\\server\share` is the root crumb.
  const uncMatch = /^[\\/]{2}([^\\/]+)[\\/]+([^\\/]+)/.exec(path)
  if (uncMatch) {
    const root = `\\\\${uncMatch[1]!}\\${uncMatch[2]!}`
    const rest = splitSegments(path.slice(uncMatch[0]!.length))
    const segments: Array<{ name: string; path: string }> = [{ name: root, path: `${root}\\` }]
    let acc = root
    for (const part of rest) {
      acc = acc + '\\' + part
      segments.push({ name: part, path: acc })
    }
    return segments
  }
  // POSIX (unchanged legacy behavior).
  const segments: Array<{ name: string; path: string }> = []
  const parts = path.split('/').filter(Boolean)
  let acc = ''
  for (const part of parts) {
    acc += '/' + part
    segments.push({ name: part, path: acc })
  }
  return segments
}

const breadcrumb = computed(() => parseBreadcrumb(currentPath.value))

// ─── Address-bar normalization ────────────────────────────────────────────
// Accepts whatever the user typed in the address input and returns a
// canonical absolute path, or `null` when the input is unusable.
//
// Rules:
//   - empty / whitespace                              → null (no-op)
//   - '~' / '~/'                                      → '/'
//   - Windows absolute (`C:\...`, `C:/...`, UNC)      → accepted as-is
//     (separator runs collapsed, one trailing separator stripped
//     unless the result is a root)
//   - POSIX absolute (starts with '/')                → collapsed runs of
//     slashes, trailing slash stripped unless root
//   - relative path starting with './' or '../'       → relative to currentPath
//   - bare relative path like 'docs' or 'a/b'         → joined with currentPath
// Trailing slashes are stripped except for roots.
function normalizeAddressInput(raw: string): string | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  if (trimmed === '~' || trimmed === '~/') return '/'

  // Windows absolute (drive or UNC). Previously these fell through to the
  // relative branch and came out as `/C:\...` garbage — the exact mixed
  // shape that ended up persisted as workspace_items.path on Windows.
  if (isWindowsAbs(trimmed)) {
    let out: string
    if (trimmed.startsWith('\\\\') || trimmed.startsWith('//')) {
      out = trimmed.slice(0, 2) + trimmed.slice(2).replace(/[\\/]+/g, '\\')
    } else {
      out = trimmed.replace(/[\\/]+/g, (m) => (m.includes('\\') ? '\\' : '/'))
    }
    // Strip a trailing separator unless the whole thing is a root.
    if (!isRootPath(out)) out = out.replace(/[\\/]+$/, '')
    return out || null
  }

  // Already absolute (starts with '/'). Collapse runs of slashes and
  // strip a trailing slash unless the result would be empty.
  if (trimmed.startsWith('/')) {
    const collapsed = trimmed.replace(/\/+/g, '/').replace(/(.)\/$/, '$1')
    return collapsed || '/'
  }

  // Relative path: resolve against currentPath so a bare "docs" jumps
  // into "./docs" inside the current view instead of being treated as
  // invalid. Dot-prefixed relpaths ('./a', '../a/b') are normalized as
  // path concatenation (no realpath — we don't have access to a
  // filesystem here and the upstream caller's loadItems will be the
  // one that surfaces "not found" if the path doesn't exist).
  const base = currentPath.value
  if (trimmed.startsWith('./') || trimmed.startsWith('../')) {
    const rel = trimmed.replace(/^\.\//, '')
    return joinRelative(base, rel)
  }
  return joinRelative(base, trimmed)
}

// Relative-path join with `..` support. Preserves a Windows drive/UNC prefix on the base so `notes`
// from `C:\Users\ginwa` resolves to `C:\Users\ginwa\notes` (not `/notes`). Purely lexical — no
// filesystem access. POSIX inputs behave exactly like the old POSIX-only version.
function joinRelative(base: string, rel: string): string {
  const driveMatch = /^[A-Za-z]:/.exec(base)
  const uncMatch = !driveMatch ? /^[\\/]{2}[^\\/]+[\\/]+[^\\/]+/.exec(base) : null
  const isWindowsBase = !!driveMatch || !!uncMatch
  const baseRest = driveMatch
    ? base.slice(driveMatch[0]!.length)
    : uncMatch
      ? base.slice(uncMatch[0]!.length)
      : base
  const baseParts = baseRest.split(/[\\/]/).filter((p) => p !== '' && p !== '.')
  const relParts = rel.split(/[\\/]/).filter((p) => p !== '.' && p !== '')
  const out = [...baseParts]
  for (const part of relParts) {
    if (part === '..') {
      if (out.length > 0) out.pop()
    } else {
      out.push(part)
    }
  }
  if (!isWindowsBase) return '/' + out.join('/')
  const prefix = driveMatch ? `${driveMatch[0]!}\\` : `${uncMatch![0].replace(/\//g, '\\')}`
  if (out.length === 0) return prefix
  return prefix.replace(/[\\/]+$/, '') + '\\' + out.join('\\')
}

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

async function expandAncestors(targetPath: string) {
  // Build ancestor chain root → … → target.
  const chain: string[] = []
  if (!targetPath) {
    // System root (''): a single backend call with '' so the caller's
    // loadItems can route to getSystemFolder (backend home / USERPROFILE).
    chain.push('')
  } else if (isWindowsAbs(targetPath)) {
    // Windows: chain from the drive/UNC root down.
    let p: string = targetPath
    while (p && !isRootPath(p)) {
      chain.unshift(p)
      const parent = parentPath(p)
      if (parent === p) break // safety: never loop forever
      p = parent
    }
    if (p) chain.unshift(p)
  } else {
    let p: string = targetPath
    while (p && p !== '/') {
      chain.unshift(p)
      p = parentPath(p)
    }
    chain.unshift('/')
  }

  for (const path of chain) {
    const items = await loadPath(path)
    if (path === targetPath) {
      contentEntries.value = items
    } else {
      // Mark all ancestor folders (except target) as expanded so the tree shows them
      treeExpanded.value = { ...treeExpanded.value, [path]: true }
    }
  }
}

async function navigateTo(path: string) {
  // NOTE: '' is meaningful (system root → getSystemFolder), so unlike the
  // old `path || '/'` fallback we pass the value through untouched.
  const target = path
  if (target === currentPath.value) return
  currentPath.value = target
  selectedPath.value = ''
  highlightedIndex.value = -1
  searchQuery.value = ''
  await expandAncestors(target)
}

function refreshCurrent() {
  loadPath(currentPath.value).then((items) => {
    contentEntries.value = items
  })
}

async function toggleTreeNode(path: string) {
  if (treeExpanded.value[path]) {
    treeExpanded.value = { ...treeExpanded.value, [path]: false }
    return
  }
  treeExpanded.value = { ...treeExpanded.value, [path]: true }
  if (!treeEntriesCache.value[path]) {
    await loadPath(path)
  }
}

// ─── Selection ─────────────────────────────────────────────────────────────

function handleItemClick(item: T) {
  const path = props.pathFor(item)
  const expandable = props.isExpandable(item)

  if (expandable) {
    if (mode.value === 'folder' || mode.value === 'both') {
      // Folders can be selected in folder/both mode
      selectedPath.value = path
    } else {
      // mode === 'file': folder click navigates into it
      navigateTo(path)
    }
  } else {
    if (mode.value === 'file' || mode.value === 'both') {
      // Files can be selected in file/both mode
      selectedPath.value = path
    }
    // mode === 'folder': file click is a no-op
  }
}

function handleItemDoubleClick(item: T) {
  // Double-click on a folder navigates INTO it — it must never select + close the dialog. Single
  // click already selects the folder (folder/both mode); the Select button / Enter confirms. This
  // mirrors Finder / Explorer / zenity --directory.
  if (props.isExpandable(item)) {
    void navigateTo(props.pathFor(item))
    return
  }
  // Double-click on a file confirms it (file/both mode only —
  // handleItemClick is a no-op for files in folder mode, so
  // selectedPath stays empty and we don't close).
  handleItemClick(item)
  if (selectedPath.value) {
    handleSelect()
  }
}

function handleSelect() {
  const path = effectiveSelection.value
  if (!path) return
  // Defense-in-depth (Windows cwd fix, 2026-09-05): never emit a relative path. Selections must be
  // absolute on at least one platform — this is the last gate before a picked path is persisted as
  // workspace_items.path and flows into sessions.cwd and the agent prompt.
  if (!isAbsPath(path)) return
  // Record every selection in the recent store (Recent rows AND Browse
  // rows both go through handleSelect). The store dedupes by path.
  recentStore.addRecent(path)
  emit('select', path)
  // Note: Vue 3.5 auto-defaults `boolean?` to `false`, so the only way to opt
  // INTO close-on-select is to explicitly pass `closeOnSelect={true}`. If the
  // prop is omitted, the dialog stays open after selection.
  if (props.closeOnSelect) {
    emit('update:modelValue', false)
  }
}

function handleCancel() {
  emit('cancel')
  emit('update:modelValue', false)
}

const canSelect = computed(() => !!effectiveSelection.value)

// Effective selection for the Select button. Order of preference:
//   1. selectedPath — the user explicitly clicked a folder in the content pane.
//   2. currentPath — the user navigated to a folder via the tree, breadcrumb,
//      Up button, Backspace, or address bar. The currently-open folder is a
//      valid selection (mirrors Finder / Explorer / zenity --directory).
// The POSIX root '/' and the system root '' are treated as "no selection" —
// falling back to either would emit a meaningless path that every caller
// rejects. Windows drive roots (`C:\`) ARE valid selections. Plan:
// docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
const effectiveSelection = computed<string>(() => {
  if (mode.value !== 'folder') return selectedPath.value
  if (selectedPath.value) return selectedPath.value
  if (currentPath.value && currentPath.value !== '/' && currentPath.value !== '') return currentPath.value
  return ''
})

// Whether the footer should show the "← current folder" hint. Only when the fallback path is in
// use: folder mode, no explicit click, but a non-root folder is open. Hidden in file mode (the
// fallback isn't active there) and hidden after an explicit click (the click is more specific).
const showCurrentFolderHint = computed<boolean>(
  () =>
    mode.value === 'folder' &&
    !selectedPath.value &&
    !!effectiveSelection.value,
)

// ─── Tab state (Recent / Browse) ─────────────────────────────────────────────

// Default: Recent. The Recent tab is the user's primary path — most-of-the-time
// they pick a folder they've picked before. The Browse tab is the
// power-user / unfamiliar-folder flow.

// The active tab is a ref (not persisted) — the user always re-enters via
// Recent on each open.
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

// Format a Unix-ms timestamp as the SQLite UTC string `formatRelativeTime`
// expects (`'YYYY-MM-DD HH:MM:SS'`). See plan R12.
function toSqliteUtc(ms: number): string {
  const d = new Date(ms)
  return d.toISOString().replace('T', ' ').slice(0, 19)
}

// ─── Filtered view ─────────────────────────────────────────────────────────

const filteredContent = computed<ContentItem[]>(() => {
  const entries = contentEntries.value ?? []
  const items: ContentItem[] = entries.map((raw) => {
    // Cast through unknown because Vue's deep ref unwraps T into UnwrapRefSimple<T>
    // inside the ref's value array. The user's data-source functions still expect T.
    const item = raw as unknown as T
    return {
      item,
      path: props.pathFor(item),
      label: getLabel(item),
      subtitle: getSubtitle(item),
      icon: getIcon(item),
      expandable: props.isExpandable(item),
      hidden: isHiddenItem(getLabel(item)),
    }
  })

  let filtered = items

  // Filter by mode chip
  if (filterMode.value === 'folders') {
    filtered = filtered.filter((i) => i.expandable)
  } else if (filterMode.value === 'files') {
    filtered = filtered.filter((i) => !i.expandable)
  }

  // Hidden files
  if (!showHiddenLocal.value) {
    filtered = filtered.filter((i) => !i.hidden)
  }

  // Search
  const q = searchQuery.value.trim().toLowerCase()
  if (q) {
    filtered = filtered.filter((i) => i.label.toLowerCase().includes(q))
  }

  return filtered
})

// Flattened tree (recursive from root, with depth)
const treeFlat = computed<TreeRow[]>(() => {
  const result: TreeRow[] = []
  const cache = treeEntriesCache.value
  // Root key is '/' on POSIX, '' when the dialog opened at the system root (resolved via
  // getSystemFolder), or a drive/UNC root (`C:\`, `\\server\share`) on Windows. Prefer '' (a failed
  // '/' load leaves a stale empty '/' entry behind after the system-root fallback).
  const rootKey =
    Object.keys(cache).find((k) => k === '') ??
    Object.keys(cache).find((k) => k === '/' || isRootPath(k))
  const rootChildren = (rootKey !== undefined ? cache[rootKey] : undefined) || []

  const add = (entries: T[], depth: number) => {
    for (const raw of entries) {
      const item = raw as unknown as T
      if (!props.isExpandable(item)) continue
      const path = props.pathFor(item)
      result.push({ item, path, depth })
      if (treeExpanded.value[path] && treeEntriesCache.value[path]) {
        add(treeEntriesCache.value[path] as T[], depth + 1)
      }
    }
  }

  add(rootChildren, 0)
  return result
})

// ─── Keyboard ──────────────────────────────────────────────────────────────

function scrollHighlightedIntoView() {
  nextTick(() => {
    const el = contentRef.value?.querySelector(
      `[data-index="${highlightedIndex.value}"]`,
    ) as HTMLElement | null
    if (el) el.scrollIntoView({ block: 'nearest' })
  })
}

function handleKeydown(event: KeyboardEvent) {
  // Focus trap on Tab
  if (event.key === 'Tab') {
    const focusable = dialogRef.value?.querySelectorAll<HTMLElement>(
      'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])',
    )
    if (!focusable || focusable.length === 0) return
    const first = focusable[0]!
    const last = focusable[focusable.length - 1]!
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
    return
  }

  if (event.key === 'Escape') {
    // Address-input takes precedence over search: if the user is editing
    // the path, Esc cancels the edit (does NOT close the dialog).
    if (isPathEditing.value) {
      cancelPathEdit()
      event.stopPropagation()
      event.preventDefault()
      return
    }
    if (searchQuery.value) {
      searchQuery.value = ''
      event.stopPropagation()
      return
    }
    handleCancel()
    event.stopPropagation()
    return
  }

  // Address input (path editor): Enter commits, other keys are eaten by
  // the input itself but we still need to stop the dialog-wide keydown
  // handler from interpreting them as arrow-up / arrow-down / backspace.
  if (isPathEditing.value) {
    if (event.key === 'Enter') {
      commitPathEdit()
      event.preventDefault()
      event.stopPropagation()
    }
    // For every other key we drop the bubble so the global Up / Backspace
    // / ArrowDown handlers below don't fire while the user is typing.
    event.stopPropagation()
    return
  }

  // Don't handle navigation keys while typing in search
  if (document.activeElement === searchInput.value) {
    if (event.key === 'Enter') {
      // Submit the first match as the selection
      const first = filteredContent.value[0]
      if (first) {
        handleItemClick(first.item)
        if (effectiveSelection.value) handleSelect()
      }
      event.preventDefault()
    }
    return
  }

  if (event.key === '/') {
    searchInput.value?.focus()
    event.preventDefault()
    return
  }

  if (event.key === 'Enter') {
    if (highlightedIndex.value >= 0 && filteredContent.value[highlightedIndex.value]) {
      const entry = filteredContent.value[highlightedIndex.value]!
      handleItemClick(entry.item)
      if (effectiveSelection.value) handleSelect()
    } else if (canSelect.value) {
      handleSelect()
    }
    event.preventDefault()
    return
  }

  if (event.key === 'ArrowDown') {
    const len = filteredContent.value.length
    if (len === 0) return
    highlightedIndex.value = Math.min(
      highlightedIndex.value < 0 ? 0 : highlightedIndex.value + 1,
      len - 1,
    )
    scrollHighlightedIntoView()
    event.preventDefault()
    return
  }

  if (event.key === 'ArrowUp') {
    highlightedIndex.value = Math.max(
      highlightedIndex.value < 0 ? 0 : highlightedIndex.value - 1,
      0,
    )
    scrollHighlightedIntoView()
    event.preventDefault()
    return
  }

  if (event.key === 'Backspace') {
    navigateTo(parentPath(currentPath.value))
    event.preventDefault()
    return
  }
}

// ─── Address-bar enter / exit / commit ─────────────────────────────────────
// beginPathEdit swaps the breadcrumb <span> tree for a single <input>
// pre-filled with currentPath, then auto-focuses + selects so the user
// can start typing (or paste) immediately. commitPathEdit normalizes the
// typed value and calls navigateTo; an empty / whitespace input cancels
// instead of navigating to '/'. cancelPathEdit just exits the editor.
function beginPathEdit() {
  pathDraft.value = currentPath.value
  isPathEditing.value = true
  // Defer focus until after Vue has committed the conditional v-if swap.
  nextTick(() => {
    const el = pathInput.value
    if (!el) return
    el.focus()
    el.select()
  })
}

function commitPathEdit() {
  const normalized = normalizeAddressInput(pathDraft.value)
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

async function openDialog() {
  const startPath = initialPath.value
  currentPath.value = startPath
  treeEntriesCache.value = {}
  treeExpanded.value = {}
  contentEntries.value = []
  selectedPath.value = props.selectedPath || ''
  searchQuery.value = ''
  highlightedIndex.value = -1
  filterMode.value = 'all'
  showHiddenOverride.value = null
  isPathEditing.value = false
  pathDraft.value = ''
  loadError.value = null
  // Reset to the Recent tab on every open. The user always re-enters
  // through Recent — the Browse tab is one click away when they need it.
  activeTab.value = 'recent'

  await expandAncestors(startPath)

  // Windows first-open fallback: the POSIX default '/' doesn't exist on
  // Windows, so the chain above loads nothing and sets loadError. Retry
  // once at the system root ('') which the callers resolve via
  // getSystemFolder (backend home / USERPROFILE). On POSIX '/' virtually
  // always loads, so this branch never fires there.
  if (startPath === '/' && contentEntries.value.length === 0 && loadError.value) {
    loadError.value = null
    await expandAncestors('')
  }

  await nextTick()
  searchInput.value?.focus()
}

function closeDialog() {
  document.body.style.overflow = ''
  if (previouslyFocused && document.body.contains(previouslyFocused)) {
    previouslyFocused.focus()
  }
}

// Open guard: run openDialog on mount when the parent created this
// dialog with modelValue already true (the common v-if +
// v-model="show" pattern) plus closed->open updates. Without the mount
// run the dialog renders but contentEntries / treeEntriesCache stay
// empty, so the user sees "No folders / Empty folder" until they
// navigate manually.
const wasOpen = ref(props.modelValue)
const syncModelValue = (show: boolean) => {
  if (show) {
    previouslyFocused = document.activeElement as HTMLElement
    document.body.style.overflow = 'hidden'
    void openDialog()
  } else {
    closeDialog()
  }
}
onMounted(() => {
  wasOpen.value = props.modelValue
  syncModelValue(props.modelValue)
})
onUpdated(() => {
  if (props.modelValue !== wasOpen.value) {
    wasOpen.value = props.modelValue
    syncModelValue(props.modelValue)
  }
})


onBeforeUnmount(() => {
  document.body.style.overflow = ''
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
          <div
            class="px-5 py-2 flex items-center gap-1 shrink-0 text-dense"
            style="
              border-bottom: 1px solid var(--color-border);
              color: var(--semantic-text-muted);
            "
          >
            <template v-if="!isPathEditing">
              <button
                @click="navigateTo('/')"
                data-testid="file-picker-root"
                class="px-1.5 py-0.5 rounded hover:opacity-80"
                style="color: var(--semantic-text-muted)"
                title="Root"
              >
                /
              </button>
              <template v-for="(seg, idx) in breadcrumb" :key="seg.path">
                <span aria-hidden="true" style="color: var(--semantic-text-dim)">›</span>
                <button
                  @click="navigateTo(seg.path)"
                  :data-testid="`file-picker-crumb-${idx}`"
                  class="px-1.5 py-0.5 rounded hover:opacity-80 font-mono truncate max-w-[180px]"
                  :style="
                    idx === breadcrumb.length - 1
                      ? { color: 'var(--semantic-text)', fontWeight: '600' }
                      : { color: 'var(--semantic-text-muted)' }
                  "
                >
                  {{ seg.name }}
                </button>
              </template>
            </template>

            <input
              v-else
              ref="pathInput"
              v-model="pathDraft"
              type="text"
              spellcheck="false"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              data-testid="file-picker-path-input"
              :aria-label="`Type a path to navigate. Currently at ${currentPath}.`"
              class="flex-1 min-w-0 px-2 py-0.5 text-dense font-mono rounded outline-none transition-all"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-violet);
                color: var(--semantic-text);
              "
              @keydown.enter.prevent="commitPathEdit"
              @keydown.esc.prevent="cancelPathEdit"
              @blur="commitPathEdit"
            />

            <span class="flex-1" v-if="!isPathEditing" />

            <button
              v-if="!isPathEditing"
              @click="beginPathEdit"
              data-testid="file-picker-path-edit"
              class="px-2 py-0.5 rounded text-dense transition-all hover:opacity-80"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              title="Type a path (Enter to go, Esc to cancel)"
              aria-label="Edit path"
            >
              <UiIcon name="pencil" /> Go
            </button>

            <button
              v-if="currentPath !== '/' && currentPath !== '' && !isPathEditing"
              @click="navigateTo(parentPath(currentPath))"
              data-testid="file-picker-up"
              class="px-2 py-0.5 rounded text-dense transition-all hover:opacity-80"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              title="Go up one level"
            >
              ⬆ Up
            </button>
          </div>

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
          <div
            v-if="enableRecent"
            class="px-5 py-1 flex items-center gap-1 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
            role="tablist"
            aria-label="Folder picker view"
          >
            <button
              type="button"
              role="tab"
              :aria-selected="activeTab === 'recent'"
              data-testid="file-picker-tab-recent"
              @click="activeTab = 'recent'"
              class="relative px-3 h-9 text-dense font-medium transition-colors duration-150 inline-flex items-center gap-1.5 shrink-0"
              :style="{
                color: activeTab === 'recent' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
              }"
            >
              <span class="relative z-10">Recent</span>
              <span
                v-if="recentCount > 0"
                data-testid="file-picker-tab-recent-count"
                class="text-micro px-1.5 rounded font-mono"
                :style="{
                  backgroundColor: activeTab === 'recent' ? 'var(--color-violet)' : 'var(--semantic-text-muted)',
                  color: 'var(--color-bg)',
                }"
              >{{ recentCount }}</span>
              <span
                v-if="activeTab === 'recent'"
                class="absolute left-2 right-2 bottom-0 h-0.5"
                style="background-color: var(--color-violet);"
                aria-hidden="true"
              />
            </button>
            <button
              type="button"
              role="tab"
              :aria-selected="activeTab === 'browse'"
              data-testid="file-picker-tab-browse"
              @click="activeTab = 'browse'"
              class="relative px-3 h-9 text-dense font-medium transition-colors duration-150 inline-flex items-center gap-1.5 shrink-0"
              :style="{
                color: activeTab === 'browse' ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
              }"
            >
              <span class="relative z-10">Browse</span>
              <span
                v-if="activeTab === 'browse'"
                class="absolute left-2 right-2 bottom-0 h-0.5"
                style="background-color: var(--color-violet);"
                aria-hidden="true"
              />
            </button>
            <span class="flex-1" aria-hidden="true" />
          </div>

          <!-- Toolbar (Browse only) -->
          <div
            v-if="!enableRecent || activeTab === 'browse'"
            class="px-5 py-2 flex items-center gap-2 shrink-0"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <div class="relative flex-1">
              <input
                ref="searchInput"
                v-model="searchQuery"
                type="text"
                placeholder="Search... (press / to focus)"
                data-testid="file-picker-search"
                class="w-full pl-7 pr-2 py-1.5 text-dense rounded outline-none transition-all"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
              />
              <UiIcon
                name="search"
                class="absolute left-2 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none"
                style="color: var(--semantic-text-dim)"
              />
            </div>

            <!-- Filter chips (only in 'both' mode) -->
            <div
              v-if="mode === 'both'"
              class="flex items-center gap-1 text-dense"
              role="tablist"
              aria-label="Filter items"
            >
              <button
                v-for="opt in (['all', 'folders', 'files'] as const)"
                :key="opt"
                @click="filterMode = opt"
                :data-testid="`file-picker-filter-${opt}`"
                :aria-pressed="filterMode === opt"
                class="px-2 py-1 rounded transition-all"
                :style="
                  filterMode === opt
                    ? {
                        backgroundColor: 'var(--semantic-active-bg)',
                        color: 'var(--semantic-text)',
                      }
                    : { color: 'var(--semantic-text-dim)' }
                "
              >
                {{
                  opt === 'all'
                    ? 'All'
                    : opt === 'folders'
                      ? 'Folders'
                      : 'Files'
                }}
              </button>
            </div>

            <!-- Hidden files toggle -->
            <button
              @click="showHiddenLocal = !showHiddenLocal"
              data-testid="file-picker-hidden-toggle"
              class="px-2 py-1 text-dense rounded transition-all"
              :style="
                showHiddenLocal
                  ? {
                      backgroundColor: 'var(--semantic-active-bg)',
                      color: 'var(--semantic-text)',
                    }
                  : { color: 'var(--semantic-text-dim)' }
              "
              :title="showHiddenLocal ? 'Hide hidden files' : 'Show hidden files'"
              :aria-pressed="showHiddenLocal"
            >
              <UiIcon name="eye" />
            </button>

            <!-- Refresh -->
            <button
              @click="refreshCurrent"
              data-testid="file-picker-refresh"
              class="px-2 py-1 text-dense rounded transition-all hover:opacity-80"
              style="color: var(--semantic-text-dim)"
              title="Refresh"
            >
              <UiIcon name="refresh" />
            </button>

            <slot name="toolbar" />
          </div>

          <!-- Two-pane body (Browse only) -->
          <div
            v-if="!enableRecent || activeTab === 'browse'"
            class="flex-1 flex overflow-hidden"
          >
            <!-- Tree pane -->
            <div
              class="shrink-0 overflow-y-auto py-1"
              style="
                width: 240px;
                border-right: 1px solid var(--color-border);
                background-color: var(--semantic-sidebar-bg);
              "
              data-testid="file-picker-tree"
            >
              <!-- Loading -->
              <div
                v-if="isLoading && treeFlat.length === 0"
                class="px-3 py-2 space-y-1"
              >
                <div
                  v-for="n in 3"
                  :key="n"
                  class="h-5 rounded animate-pulse"
                  style="
                    background-color: var(--semantic-active-bg);
                    width: 80%;
                  "
                />
              </div>

              <!-- Error -->
              <div v-else-if="loadError" class="px-3 py-4 text-center">
                <div class="text-title mb-1">⚠️</div>
                <p
                  class="text-dense mb-2"
                  style="color: var(--semantic-text-dim)"
                >
                  {{ loadError }}
                </p>
                <button
                  @click="refreshCurrent"
                  data-testid="file-picker-retry"
                  class="px-2 py-1 text-dense rounded"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text);
                  "
                >
                  Retry
                </button>
              </div>

              <!-- Empty -->
              <div
                v-else-if="treeFlat.length === 0"
                class="px-3 py-4 text-center"
              >
                <UiIcon name="folder-open" class="w-6 h-6 mb-1" />
                <p class="text-dense" style="color: var(--semantic-text-dim)">
                  No folders
                </p>
              </div>

              <!-- Tree rows -->
              <template v-else>
                <button
                  v-for="row in treeFlat"
                  :key="row.path"
                  @click="navigateTo(row.path)"
                  @dblclick.stop="toggleTreeNode(row.path)"
                  :data-testid="`file-picker-tree-${row.path}`"
                  class="w-full flex items-center gap-1.5 px-2 py-1 text-dense text-left transition-colors hover:opacity-80"
                  :style="{
                    paddingLeft: `${0.5 + row.depth * 0.875}rem`,
                    backgroundColor:
                      row.path === currentPath
                        ? 'var(--semantic-active-bg)'
                        : 'transparent',
                    color: 'var(--semantic-text)',
                    fontWeight: row.path === currentPath ? '600' : 'normal',
                  }"
                >
                  <span
                    class="text-micro inline-block w-2 transition-transform duration-150"
                    :style="
                      treeExpanded[row.path] ? 'transform: rotate(90deg)' : ''
                    "
                    @click.stop="toggleTreeNode(row.path)"
                    :data-testid="`file-picker-tree-toggle-${row.path}`"
                  >▶</span>
                  <UiIcon :name="getIcon(row.item)" />
                  <span class="truncate">{{ getLabel(row.item) }}</span>
                </button>
              </template>
            </div>

            <!-- Content pane -->
            <div
              ref="contentRef"
              class="flex-1 overflow-y-auto py-1"
              data-testid="file-picker-content"
            >
              <!-- Loading skeleton -->
              <div
                v-if="isLoading && contentEntries.length === 0"
                class="p-3 space-y-1"
              >
                <div
                  v-for="n in 5"
                  :key="n"
                  class="h-9 rounded animate-pulse"
                  style="background-color: var(--semantic-active-bg)"
                />
              </div>

              <!-- Error -->
              <div
                v-else-if="loadError"
                class="px-3 py-4 text-center"
              >
                <div class="text-title mb-1">⚠️</div>
                <p
                  class="text-dense mb-2"
                  style="color: var(--semantic-text-dim)"
                >
                  {{ loadError }}
                </p>
                <button
                  @click="refreshCurrent"
                  data-testid="file-picker-retry"
                  class="px-2 py-1 text-dense rounded"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text);
                  "
                >
                  Retry
                </button>
              </div>

              <!-- Empty -->
              <div
                v-else-if="filteredContent.length === 0"
                class="px-3 py-8 text-center"
              >
                <slot name="empty">
                  <UiIcon name="inbox" class="w-6 h-6 mb-1" />
                  <p class="text-dense" style="color: var(--semantic-text-dim)">
                    {{
                      searchQuery
                        ? 'No matches'
                        : 'Empty folder'
                    }}
                  </p>
                </slot>
              </div>

              <!-- Items -->
              <template v-else>
                <button
                  v-for="(entry, idx) in filteredContent"
                  :key="props.keyFor(entry.item)"
                  @click="handleItemClick(entry.item)"
                  @dblclick="handleItemDoubleClick(entry.item)"
                  :data-testid="`file-picker-item-${props.keyFor(entry.item)}`"
                  :data-index="idx"
                  :aria-selected="selectedPath === entry.path"
                  @mouseenter="highlightedIndex = idx"
                  class="w-full flex items-center gap-2 px-3 py-1.5 text-body text-left transition-colors"
                  :style="{
                    backgroundColor:
                      selectedPath === entry.path
                        ? 'var(--semantic-active-bg)'
                        : highlightedIndex === idx
                          ? 'var(--semantic-hover-bg)'
                          : 'transparent',
                    boxShadow:
                      selectedPath === entry.path
                        ? 'inset 3px 0 0 var(--color-violet)'
                        : 'none',
                    color: 'var(--semantic-text)',
                  }"
                >
                  <slot
                    name="item"
                    :item="entry.item"
                    :selected="selectedPath === entry.path"
                  >
                    <UiIcon :name="entry.icon" class="w-4 h-4 shrink-0" />
                    <span class="flex-1 truncate">{{ entry.label }}</span>
                    <span
                      v-if="entry.subtitle"
                      class="text-dense shrink-0"
                      style="color: var(--semantic-text-dim)"
                    >
                      {{ entry.subtitle }}
                    </span>
                  </slot>
                </button>
              </template>
            </div>
          </div>

          <!--
            Recent tab body. A flat list of cards, each row is a folder
            the user has picked before. The row is a single <button> for
            keyboard nav (Tab-able, Enter to select). The star toggles
            pin. The body scroll is contained in the
            [data-testid="file-picker-recent-list"] wrapper.
          -->
          <div
            v-if="enableRecent && activeTab === 'recent'"
            class="flex-1 flex flex-col overflow-hidden"
            data-testid="file-picker-recent-body"
          >
            <!-- Empty state -->
            <div
              v-if="recentCount === 0"
              class="flex-1 flex flex-col items-center justify-center gap-3 px-5 py-8 text-center"
              data-testid="file-picker-recent-empty"
            >
              <UiIcon name="folder" class="w-6 h-6" />
              <p class="text-body" style="color: var(--semantic-text)">
                No recent folders yet
              </p>
              <p class="text-dense" style="color: var(--semantic-text-dim)">
                Pick one in Browse to save it here for next time.
              </p>
              <button
                type="button"
                @click="activeTab = 'browse'"
                data-testid="file-picker-recent-open-browse"
                class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200 hover:opacity-80"
                style="
                  background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                  color: var(--color-bg);
                "
              >
                Open Browse
              </button>
            </div>

            <!-- The list -->
            <div
              v-else
              class="flex-1 overflow-y-auto px-5 py-2"
              data-testid="file-picker-recent-list"
            >
              <button
                v-for="entry in recentList"
                :key="entry.path"
                type="button"
                @click="handleRecentRowClick(entry.path)"
                :data-testid="`file-picker-recent-row-${entry.path}`"
                :title="entry.pinned ? `${entry.path} (pinned)` : entry.path"
                class="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-body text-left transition-colors duration-150 hover:opacity-80"
                style="color: var(--semantic-text);"
              >
                <!-- Folder icon -->
                <UiIcon name="folder" class="w-4 h-4 shrink-0" />
                <!-- Name + path stack -->
                <span class="flex-1 min-w-0 flex flex-col gap-0.5">
                  <span class="font-medium truncate">
                    {{ basenameOf(entry.path) || entry.path }}
                    <span
                      v-if="entry.pinned"
                      class="ml-1 text-micro px-1.5 py-0.5 rounded uppercase font-semibold"
                      style="background-color: var(--color-violet); color: var(--color-bg);"
                      data-testid="file-picker-recent-pinned-badge"
                    ><UiIcon name="star" /> PINNED</span>
                  </span>
                  <span
                    class="text-dense font-mono truncate"
                    style="color: var(--semantic-text-muted)"
                  >
                    {{ entry.path }}
                  </span>
                </span>
                <!-- Right column: time + pin star -->
                <span class="flex items-center gap-2 shrink-0">
                  <span
                    :data-testid="`file-picker-recent-time-${entry.path}`"
                    class="text-dense font-mono"
                    style="color: var(--semantic-text-dim)"
                  >
                    {{ formatRelativeTime(toSqliteUtc(entry.lastUsedAt)) }}
                  </span>
                  <button
                    type="button"
                    @click.stop="handleRecentPinClick(entry.path)"
                    :data-testid="`file-picker-recent-pin-${entry.path}`"
                    :title="entry.pinned ? 'Unpin' : 'Pin to keep at top'"
                    :aria-label="entry.pinned ? 'Unpin folder' : 'Pin folder'"
                    class="w-7 h-7 rounded flex items-center justify-center transition-opacity duration-150 hover:opacity-80"
                    :style="{
                      color: entry.pinned ? 'var(--color-violet)' : 'var(--semantic-text-dim)',
                    }"
                  >
                    <svg
                      v-if="entry.pinned"
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="currentColor"
                      class="w-4 h-4"
                      aria-hidden="true"
                    >
                      <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
                    </svg>
                    <svg
                      v-else
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 20 20"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.5"
                      class="w-4 h-4"
                      aria-hidden="true"
                    >
                      <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.286 3.957a1 1 0 00.95.69h4.162c.969 0 1.371 1.24.588 1.81l-3.367 2.446a1 1 0 00-.364 1.118l1.286 3.957c.3.921-.755 1.688-1.54 1.118l-3.366-2.446a1 1 0 00-1.176 0l-3.366 2.446c-.784.57-1.838-.197-1.539-1.118l1.286-3.957a1 1 0 00-.364-1.118L2.066 9.384c-.783-.57-.38-1.81.588-1.81h4.162a1 1 0 00.95-.69l1.286-3.957z" />
                    </svg>
                  </button>
                </span>
              </button>
            </div>
          </div>

          <!-- Footer -->
          <div
            class="px-5 py-3 flex items-center gap-3 shrink-0"
            style="
              border-top: 1px solid var(--color-border);
              background-color: var(--semantic-sidebar-bg);
            "
          >
            <div class="flex-1 min-w-0 flex items-center gap-2">
              <span
                class="text-dense shrink-0"
                style="color: var(--semantic-text-dim)"
                >Selected:</span
              >
              <span
                class="text-dense font-mono truncate"
                style="
                  color: var(--semantic-text);
                  direction: rtl;
                  text-align: left;
                "
                :title="effectiveSelection || '(none)'"
                data-testid="file-picker-selected-path"
                >{{ effectiveSelection || '(none)' }}</span
              >
              <!--
                NEW (plan: 2026-08-13-folder-picker-select-button-current-folder.md).
                Hint shown when the Select button is enabled via the fallback
                path (currentPath, not selectedPath). Tells the user "the
                button is on because you're sitting on this folder, not
                because you clicked it". Hidden when selectedPath is set
                (explicit click is more specific) or in file mode.
              -->
              <span
                v-if="showCurrentFolderHint"
                class="text-micro shrink-0"
                style="color: var(--semantic-text-dim)"
                data-testid="file-picker-selected-hint"
                >← current folder</span
              >
            </div>

            <slot name="footer" />

            <button
              @click="handleCancel"
              data-testid="file-picker-cancel"
              class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              @click="handleSelect"
              :disabled="!canSelect"
              data-testid="file-picker-select"
              class="px-3 py-1.5 text-dense rounded-lg font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(
                  135deg,
                  var(--color-violet),
                  var(--color-blue)
                );
                color: var(--color-bg);
              "
            >
              {{ selectLabel }}
            </button>
          </div>
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

/* Skeleton shimmer */
@keyframes fp-skeleton-shimmer {
  0% {
    opacity: 0.5;
  }
  50% {
    opacity: 1;
  }
  100% {
    opacity: 0.5;
  }
}

.animate-pulse {
  animation: fp-skeleton-shimmer 1.4s ease-in-out infinite;
}

/* Search focus ring */
input:focus {
  box-shadow: 0 0 0 2px rgba(137, 146, 167, 0.2);
}

/* Scrollbar polish for tree + content panes */
.overflow-y-auto::-webkit-scrollbar {
  width: 8px;
}
.overflow-y-auto::-webkit-scrollbar-track {
  background: transparent;
}
.overflow-y-auto::-webkit-scrollbar-thumb {
  background-color: var(--color-border);
  border-radius: 4px;
}
.overflow-y-auto::-webkit-scrollbar-thumb:hover {
  background-color: var(--semantic-text-dim);
}
</style>