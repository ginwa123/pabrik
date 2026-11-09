<script setup lang="ts">
// The "Documents" sidebar section — a collapsible tree.
import { computed, nextTick, onMounted, onUpdated, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useSidebarStore } from '../../stores/sidebar'
import { isAtOrBelow, useDocumentsStore } from '../../stores/documents'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { buildAppUrl } from '../../helpers/appUrl'
import {
  MARKDOWN_FORMAT,
  OFFICE_FORMAT,
  serializeOfficeBody,
  type OfficeKind,
} from '../../helpers/officeDocument'
import DocumentsNewMenu from './DocumentsNewMenu.vue'
import SidebarSkeleton from '../shell/SidebarSkeleton.vue'
import type { Document, DocumentFolder } from '../../api'

const props = defineProps<{
  workspaceId: string | null
}>()

const emit = defineEmits<{
  /** Create a blank document; the parent opens the editor on it. */
  created: [documentId: string]
}>()

const sidebarStore = useSidebarStore()
const documentsStore = useDocumentsStore()
const navigationStore = useNavigationStore()
const workspacesStore = useWorkspacesStore()
const router = useRouter()
const currentMainView = useCurrentMainView()

/** Reactive active check, called from the template on every render. */
const isCurrentDocument = (id: string): boolean =>
  currentMainView.value.kind === 'document' && currentMainView.value.documentId === id

const documents = computed(() => documentsStore.documents)

/** Folders whose children are hidden. A collapsed folder still renders its own
 * row, so the count stays visible while the level below it does not. */
const collapsed = ref<Set<string>>(new Set())

/** A drop lands as a click on some browsers; toggling the folder shut right
 * after the document fell into it reads as "the move did nothing". */
let lastDropAt = 0

const toggleFolder = (id: string) => {
  if (Date.now() - lastDropAt < 300) return
  const next = new Set(collapsed.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  collapsed.value = next
}

/** Only a key pressed ON the row toggles it. Without this guard a keydown from
 * the rename field (or the delete button) bubbles here and is swallowed —
 * which is why a space typed into the field never appeared. */
const onFolderKeydown = (event: KeyboardEvent, id: string) => {
  if (event.target !== event.currentTarget) return
  if (event.key !== 'Enter' && event.key !== ' ') return
  event.preventDefault()
  toggleFolder(id)
}

const expand = (id: string) => {
  if (!collapsed.value.has(id)) return
  const next = new Set(collapsed.value)
  next.delete(id)
  collapsed.value = next
}

type Row =
  | { kind: 'folder'; folder: DocumentFolder; depth: number }
  | { kind: 'document'; document: Document; depth: number }

/** Flattened visible tree, depth-first. Folders come before documents at every
 * level (the store owns that rule) and a collapsed folder contributes one row. */
const rows = computed<Row[]>(() => {
  const out: Row[] = []
  const walk = (parentId: string | null, depth: number) => {
    for (const entry of documentsStore.level(parentId)) {
      if (entry.kind === 'folder') {
        out.push({ kind: 'folder', folder: entry.folder, depth })
        if (!collapsed.value.has(entry.folder.id)) walk(entry.folder.id, depth + 1)
      } else {
        out.push({ kind: 'document', document: entry.document, depth })
      }
    }
  }
  walk(null, 0)
  return out
})

/** The visible distance from the rail's left edge. `--sb-mark` is 16px, the
 * same step the shipped list already spends on its one mark column. */
const indent = (depth: number) => `calc(var(--sb-gutter) + ${depth * 16}px)`

const directChildCount = (folderId: string): number => documentsStore.level(folderId).length

const toggleDocumentsSection = () => {
  const wasExpanded = sidebarStore.documentsExpanded
  sidebarStore.toggleDocumentsExpanded()
  // Lazy first fetch: the section is collapsed on a returning user more
  // often than not, and the list read is the sidebar's hottest query.
  if (!wasExpanded && props.workspaceId && !documentsStore.loaded) {
    void documentsStore.fetchDocuments(props.workspaceId)
  }
}

const activeWorkspaceId = () => props.workspaceId ?? workspacesStore.activeWorkspace?.id ?? null

const selectDocument = (id: string) => {
  const wsId = activeWorkspaceId()
  if (!wsId) {
    // No workspace means no document page to build a URL for. The rows
    // only render with a workspace selected, so this is a guard against
    // a stale list surviving a workspace switch, not a normal path.
    return
  }
  // `replace`, not `push`: clicking through five documents should not bury the previous four under
  // Back. The document is a PAGE, so this replaces whatever main view was open.
  router.replace(buildAppUrl({ workspaceId: wsId, documentId: id })).catch(() => {
    // A duplicate navigation (clicking the already-open row) rejects.
  })
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  navigationStore.clearActiveChat()
}

// ─── Drag state ──────────────────────────────────────────────────────────
const draggingDoc = ref<string | null>(null)
const draggingFolder = ref<string | null>(null)
/** Folder row currently outlined as "drop inside me". */
const overFolder = ref<string | null>(null)
/** Document row the drop would land next to, and on which side. */
const overDoc = ref<{ id: string; after: boolean } | null>(null)

const clearDragState = () => {
  draggingDoc.value = null
  draggingFolder.value = null
  overFolder.value = null
  overDoc.value = null
}

const startDragDocument = (event: DragEvent, id: string) => {
  draggingDoc.value = id
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-document-id', id)
  }
}

const startDragFolder = (event: DragEvent, id: string) => {
  draggingFolder.value = id
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-document-folder-id', id)
  }
}

/** Dragging over a folder row means "into"; over a document row it means
 * "before/after", the same two halves the shipped reorder used. */
const handleDragOver = (event: DragEvent, row: Row) => {
  if (!draggingDoc.value && !draggingFolder.value) return
  event.preventDefault()
  if (row.kind === 'folder') {
    // A folder cannot be dropped into itself or its own descendant; the store
    // refuses it too, but a dead drop target should not look alive.
    const source = draggingFolder.value
    if (
      source &&
      (source === row.folder.id || isAtOrBelow(documentsStore.folders, source, row.folder.id))
    ) {
      return
    }
    overFolder.value = row.folder.id
    overDoc.value = null
    return
  }
  if (!draggingDoc.value) return
  overFolder.value = null
  const target = (event.currentTarget as HTMLElement).getBoundingClientRect()
  overDoc.value = { id: row.document.id, after: event.clientY > target.top + target.height / 2 }
}

const levelDocumentIds = (folderId: string | null): string[] =>
  documentsStore
    .level(folderId)
    .filter((entry): entry is { kind: 'document'; document: Document } => entry.kind === 'document')
    .map((entry) => entry.document.id)

const reorderWithin = (
  folderId: string | null,
  sourceId: string,
  targetId: string,
  after: boolean,
) => {
  const ids = levelDocumentIds(folderId)
  const from = ids.indexOf(sourceId)
  const to = ids.indexOf(targetId)
  if (from === -1 || to === -1) return
  const [moved] = ids.splice(from, 1)
  if (!moved) return
  const targetIdx = to > from ? to - 1 : to
  ids.splice(targetIdx + (after ? 1 : 0), 0, moved)
  const wsId = activeWorkspaceId()
  if (!wsId) return
  void documentsStore.reorderDocuments(wsId, ids, folderId)
}

/** The element under the pointer is the truth: a drag can skip a `dragover`
 * frame, and a drop that trusts the last hover frame is a silent no-op on any
 * part of a folder row that is not its exact middle. */
const rowUnder = (event: DragEvent) => {
  const el = event.target as HTMLElement | null
  const rowEl = el?.closest('[data-folder-id], [data-doc-id]') as HTMLElement | null
  return {
    rowEl,
    folderId: rowEl?.getAttribute('data-folder-id') ?? null,
    documentId: rowEl?.getAttribute('data-doc-id') ?? null,
  }
}

const handleDrop = (event: DragEvent, row: Row) => {
  event.preventDefault()
  const wsId = activeWorkspaceId()
  const doc = draggingDoc.value
  const folder = draggingFolder.value
  const { rowEl, folderId, documentId } = rowUnder(event)
  const hovered = overDoc.value
  const rect = rowEl?.getBoundingClientRect()
  const after = rect ? event.clientY > rect.top + rect.height / 2 : (hovered?.after ?? false)
  lastDropAt = Date.now()
  clearDragState()
  if (!wsId) return

  // A folder row means "into", whatever part of the row you let go on.
  const targetFolder = folderId ?? (row.kind === 'folder' ? row.folder.id : null)
  if (targetFolder) {
    if (doc) {
      expand(targetFolder)
      void documentsStore.moveDocument(wsId, doc, targetFolder)
    } else if (folder && folder !== targetFolder) {
      expand(targetFolder)
      void documentsStore.moveFolder(wsId, folder, targetFolder)
    }
    return
  }

  const targetDocument = documentId ?? (row.kind === 'document' ? row.document.id : null)
  if (targetDocument && doc && doc !== targetDocument) {
    const target = documentsStore.documents.find((d) => d.id === targetDocument)
    reorderWithin(target?.folder_id ?? null, doc, targetDocument, after)
  }
}

/** Dropping on the empty space below the tree moves the row to the root. */
const handleRootDrop = (event: DragEvent) => {
  event.preventDefault()
  const wsId = activeWorkspaceId()
  const doc = draggingDoc.value
  const folder = draggingFolder.value
  clearDragState()
  if (!wsId) return
  if (doc) void documentsStore.moveDocument(wsId, doc, null)
  else if (folder) void documentsStore.moveFolder(wsId, folder, null)
}

// ─── Create / rename / delete ────────────────────────────────────────────
const createDocument = (folderId: string | null = null, kind: 'markdown' | OfficeKind = 'markdown') => {
  const wsId = activeWorkspaceId()
  if (!wsId) return
  const isMarkdown = kind === 'markdown'
  // The envelope is written at create time, so the editor knows which Univer
  // product to mount before the first Save.
  const content = isMarkdown ? '' : serializeOfficeBody(kind, {})
  const format = isMarkdown ? MARKDOWN_FORMAT : OFFICE_FORMAT
  const title = kind === 'sheet' ? 'Untitled spreadsheet' : 'Untitled document'

  void documentsStore.createDocument(wsId, title, content, folderId, format).then((doc) => {
    if (doc) {
      selectDocument(doc.id)
      emit('created', doc.id)
    }
  })
}

const renamingId = ref<string | null>(null)
const renameValue = ref('')
/** A function ref, not `ref()`: a string ref inside `v-for` collects into an
 * array, and `.focus()` on that array throws. */
let renameInput: HTMLInputElement | null = null
const setRenameInput = (el: unknown) => {
  renameInput = (el as HTMLInputElement | null) ?? null
}

const startRename = (folder: DocumentFolder) => {
  renamingId.value = folder.id
  renameValue.value = folder.name
  // The field is the next thing to type into: focus it and select the old
  // name so the first keystroke replaces it.
  void nextTick(() => {
    renameInput?.focus()
    renameInput?.select()
  })
}

const commitRename = (folder: DocumentFolder) => {
  const wsId = activeWorkspaceId()
  const name = renameValue.value.trim()
  renamingId.value = null
  if (!wsId || name.length === 0 || name === folder.name) return
  void documentsStore.renameFolder(wsId, folder.id, name)
}

const createFolder = (parentId: string | null = null) => {
  const wsId = activeWorkspaceId()
  if (!wsId) return
  void documentsStore.createFolder(wsId, 'New folder', parentId).then((folder) => {
    if (!folder) return
    if (folder.parent_id) collapsed.value.delete(folder.parent_id)
    startRename(folder)
  })
}

const removeFolder = (folder: DocumentFolder) => {
  const wsId = activeWorkspaceId()
  if (!wsId) return
  void documentsStore.deleteFolder(wsId, folder.id)
}

// Refetch on workspace switch so a stale list is never shown under a new header. `reset()` on the
// way out is what makes the refetch necessary rather than a stale-merge hazard. Prev-value guard on
// update — same reset+fetch the watcher did; mount runs the same initial fetch.
function syncWorkspaceDocuments(next: string | null, prev: string | null | undefined) {
  if (prev && prev !== next) documentsStore.reset()
  if (next && sidebarStore.documentsExpanded) {
    void documentsStore.fetchDocuments(next)
  }
}

let prevWorkspaceId: string | null | undefined = undefined
onMounted(() => {
  syncWorkspaceDocuments(props.workspaceId, prevWorkspaceId)
  prevWorkspaceId = props.workspaceId
  if (props.workspaceId && sidebarStore.documentsExpanded && !documentsStore.loaded) {
    void documentsStore.fetchDocuments(props.workspaceId)
  }
})
onUpdated(() => {
  if (props.workspaceId === prevWorkspaceId) return
  const prev = prevWorkspaceId
  prevWorkspaceId = props.workspaceId
  syncWorkspaceDocuments(props.workspaceId, prev)
})
</script>

<template>
  <div class="flex flex-col shrink-0" data-testid="documents-section">
    <div class="relative shrink-0">
      <div
        class="px-[var(--sb-gutter)] h-7 flex items-center shrink-0 border-b border-(--color-border)/40"
        data-testid="documents-section-header"
        @click="toggleDocumentsSection"
      >
        <button
          class="flex items-center h-full min-w-0 flex-1 text-left transition-opacity hover:opacity-80"
          :aria-expanded="sidebarStore.documentsExpanded"
          aria-label="Documents"
          @click.stop="toggleDocumentsSection"
        >
          <span
            class="w-[var(--sb-mark)] shrink-0 flex items-center text-meta transition-transform duration-200"
            :style="{
              transform: sidebarStore.documentsExpanded ? 'rotate(90deg)' : 'rotate(0deg)',
            }"
            style="color: var(--semantic-text-dim)"
            >▶</span
          >
          <span
            class="text-micro font-semibold uppercase tracking-[0.08em]"
            style="color: var(--semantic-text-dim)"
            data-testid="documents-section-title"
            >Documents</span
          >
          <span
            v-if="workspaceId"
            class="text-micro ml-1.5"
            style="
              color: var(--semantic-text-dim);
              opacity: 0.7;
              font-variant-numeric: tabular-nums;
            "
            data-testid="documents-count"
            >{{ documents.length }}</span
          >
        </button>
        <button
          v-if="sidebarStore.documentsExpanded && workspaceId"
          class="ml-auto w-[var(--sb-hit)] h-[var(--sb-hit)] text-meta font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center shrink-0"
          style="color: var(--semantic-text-dim); opacity: 0.7"
          title="New Folder"
          aria-label="New Folder"
          data-testid="documents-new-folder-button"
          @click.stop="createFolder(null)"
        >
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <path
              d="M1.5 4.2c0-.6.5-1.1 1.1-1.1h3.1l1.3 1.4h6.4c.6 0 1.1.5 1.1 1.1v6.2c0 .6-.5 1.1-1.1 1.1H2.6c-.6 0-1.1-.5-1.1-1.1V4.2Z"
              stroke="currentColor"
              stroke-width="1.2"
            />
            <path d="M8 7.4v3.2M6.4 9h3.2" stroke="currentColor" stroke-width="1.2" />
          </svg>
        </button>
        <DocumentsNewMenu
          v-if="sidebarStore.documentsExpanded && workspaceId"
          @choose="createDocument(null, $event)"
        />
      </div>
    </div>

    <!-- No `max-h`/`overflow-y` of its own: the sidebar <nav> scrolls the
         whole panel. A third scroll region capped at 30vh is what made
         the section feel unreachable. -->
    <div v-if="sidebarStore.documentsExpanded" class="pb-1" data-testid="documents-section-body">
      <!-- Load failure is shown inline and is DISTINCT from the empty
           state. A failed fetch that rendered "No documents yet" would
           tell the user their documents are gone. -->
      <p
        v-if="documentsStore.error && !documentsStore.loaded"
        class="px-[var(--sb-gutter)] text-meta py-1"
        style="color: var(--semantic-error)"
        data-testid="documents-error"
      >
        {{ documentsStore.error }}
      </p>

      <p
        v-else-if="!workspaceId"
        class="px-[var(--sb-gutter)] text-meta py-1"
        style="color: var(--semantic-text-dim); opacity: 0.7"
        data-testid="documents-no-workspace"
      >
        No workspace selected
      </p>

      <!-- Documents loading skeleton — shown on first fetch while no
           rows are painted yet. Keeps the section from flashing the
           empty state on a slow boot. Refreshes keep old rows, so no
           skeleton there. -->
      <SidebarSkeleton
        v-else-if="workspaceId && rows.length === 0 && documentsStore.loading"
        :rows="3"
        test-id="documents-loading-skeleton"
      />

      <p
        v-else-if="rows.length === 0 && !documentsStore.loading"
        class="px-[var(--sb-gutter)] text-meta py-1"
        style="color: var(--semantic-text-dim); opacity: 0.7"
        data-testid="documents-empty"
      >
        No documents yet
      </p>

      <ul v-else class="space-y-0" role="tree" aria-label="Documents">
        <li
          v-for="row in rows"
          :key="row.kind === 'folder' ? `folder:${row.folder.id}` : `doc:${row.document.id}`"
          :draggable="renamingId !== (row.kind === 'folder' ? row.folder.id : '')"
          :data-folder-id="row.kind === 'folder' ? row.folder.id : undefined"
          :data-doc-id="row.kind === 'document' ? row.document.id : undefined"
          role="none"
          :class="
            (row.kind === 'document' && draggingDoc === row.document.id) ||
            (row.kind === 'folder' && draggingFolder === row.folder.id)
              ? 'opacity-50'
              : ''
          "
          :style="
            row.kind === 'document' &&
            overDoc?.id === row.document.id &&
            draggingDoc !== row.document.id
              ? overDoc?.after
                ? 'box-shadow: 0 2px 0 0 var(--color-violet);'
                : 'box-shadow: 0 -2px 0 0 var(--color-violet);'
              : row.kind === 'folder' && overFolder === row.folder.id
                ? 'box-shadow: inset 0 0 0 1px var(--color-violet);'
                : ''
          "
          @dragstart="
            row.kind === 'folder'
              ? startDragFolder($event, row.folder.id)
              : startDragDocument($event, row.document.id)
          "
          @dragover="handleDragOver($event, row)"
          @drop="handleDrop($event, row)"
          @dragend="clearDragState"
        >
          <!-- Folder row: chevron, name, child count, delete. -->
          <div
            v-if="row.kind === 'folder'"
            class="relative w-full flex items-center h-[var(--sb-row)] rounded-lg text-dense transition-all duration-150 overflow-hidden text-left"
            :data-testid="`document-folder-${row.folder.id}`"
            :style="`padding-left: ${indent(row.depth)}; color: var(--semantic-text-muted);`"
            role="treeitem"
            tabindex="0"
            :aria-expanded="!collapsed.has(row.folder.id)"
            :aria-level="row.depth + 1"
            @click="toggleFolder(row.folder.id)"
            @dblclick="startRename(row.folder)"
            @keydown="onFolderKeydown($event, row.folder.id)"
          >
            <span class="w-[var(--sb-mark)] shrink-0 flex items-center" aria-hidden="true">
              <span
                class="text-meta inline-block transition-transform duration-200"
                :style="{
                  transform: collapsed.has(row.folder.id) ? 'rotate(0deg)' : 'rotate(90deg)',
                }"
                >▶</span
              >
            </span>
            <input
              v-if="renamingId === row.folder.id"
              v-model="renameValue"
              class="flex-1 min-w-0 bg-transparent text-dense outline-none"
              style="
                color: inherit;
                border-bottom: 1px solid var(--color-violet);
              "
              data-testid="document-folder-rename-input"
              :ref="setRenameInput"
              @click.stop
              @keydown.stop
              @keydown.enter.prevent="commitRename(row.folder)"
              @keydown.esc.prevent="renamingId = null"
              @blur="commitRename(row.folder)"
            />
            <span v-else class="flex-1 min-w-0 truncate" :title="row.folder.name">{{
              row.folder.name
            }}</span>
            <span
              class="text-micro ml-1.5"
              style="
                color: var(--semantic-text-dim);
                opacity: 0.7;
                font-variant-numeric: tabular-nums;
              "
              >{{ directChildCount(row.folder.id) }}</span
            >
            <button
              class="w-[var(--sb-mark)] h-[var(--sb-hit)] flex items-center justify-center shrink-0 transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim); opacity: 0.55"
              :title="`Delete folder ${row.folder.name}`"
              :aria-label="`Delete folder ${row.folder.name}`"
              :data-testid="`document-folder-delete-${row.folder.id}`"
              @click.stop="removeFolder(row.folder)"
            >
              <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
                <path d="M1 1l8 8M9 1L1 9" stroke="currentColor" stroke-width="1.3" />
              </svg>
            </button>
          </div>

          <!-- Document row: unchanged from the shipped list, plus its indent. -->
          <button
            v-else
            class="relative w-full flex items-center h-[var(--sb-row)] rounded-lg text-dense transition-all duration-150 border-t border-transparent overflow-hidden text-left"
            :data-testid="`document-row-${row.document.id}`"
            role="treeitem"
            :aria-level="row.depth + 1"
            :style="
              isCurrentDocument(row.document.id)
                ? `padding-left: ${indent(row.depth)}; background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);`
                : `padding-left: ${indent(row.depth)}; color: var(--semantic-text-muted);`
            "
            @click="selectDocument(row.document.id)"
          >
            <span class="w-[var(--sb-mark)] shrink-0" aria-hidden="true"></span>
            <span class="flex-1 min-w-0 truncate">{{ row.document.title }}</span>
          </button>
        </li>
        <!-- Drop here to move a row back to the root. -->
        <li
          class="h-4"
          aria-hidden="true"
          data-testid="documents-root-drop"
          @dragover.prevent
          @drop="handleRootDrop"
        ></li>
      </ul>
    </div>
  </div>
</template>
