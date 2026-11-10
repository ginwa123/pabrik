<script setup lang="ts">
// The document page (Migration 095), reached from the sidebar's Documents section, which writes
// `/app/{ws}/doc/{id}` into the URL — a PAGE shape, so the chat it was opened from is unmounted.
// Two formats share it: `markdown` (textarea + preview) and `office` (a Univer editor).
import { computed, onMounted, onUpdated, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useDocumentsStore } from '../../stores/documents'
import { useWorkspacesStore } from '../../stores/workspaces'
import { renderMarkdownHtml } from '../../helpers/markdown'
import { buildAppUrl } from '../../helpers/appUrl'
import {
  DEFAULT_OFFICE_KIND,
  isOfficeFormat,
  parseOfficeBody,
  serializeOfficeBody,
} from '../../helpers/officeDocument'
import OfficeDocumentEditor from './OfficeDocumentEditor.vue'
import { isHtmlFormat } from '../../helpers/htmlDocument'

const props = defineProps<{
  documentId: string
}>()

const documentsStore = useDocumentsStore()
const workspacesStore = useWorkspacesStore()
const router = useRouter()

const editing = ref(false)
const draftTitle = ref('')
const draftContent = ref('')
/** Last persisted body, so `isDirty` compares against what is STORED,
 *  not against the last keystroke. */
const savedContent = ref('')
const savedTitle = ref('')
const showPreview = ref(true)
/** An office document's edits live inside Univer, so the only signal that the
 *  stored body is stale is the editor telling us a command ran. */
const officeDirty = ref(false)
const officeEditor = ref<InstanceType<typeof OfficeDocumentEditor> | null>(null)
/** True once the body has been read. The office editor mounts ONCE with the
 *  body it is handed, so an empty body would open a blank spreadsheet and Save
 *  would write that workbook under the document's real kind. */
const bodyLoaded = ref(false)

// The resolved workspace, not the raw `activeWorkspaceId` ref.
const workspaceId = computed(() => workspacesStore.activeWorkspace?.id ?? null)

const document_ = computed(() => documentsStore.findById(props.documentId))

const isOffice = computed(() => isOfficeFormat(document_.value?.format))

const isHtml = computed(() => isHtmlFormat(document_.value?.format))

/** Which Univer product renders this document. The mounted editor wins: it is
 *  the thing holding the snapshot Save will store, so the envelope's `kind` and
 *  the snapshot inside it can never disagree. */
const officeKind = computed(
  () =>
    officeEditor.value?.kind() ??
    parseOfficeBody(savedContent.value)?.kind ??
    DEFAULT_OFFICE_KIND,
)

const isDirty = computed(
  () =>
    draftTitle.value !== savedTitle.value ||
    (isOffice.value ? officeDirty.value : draftContent.value !== savedContent.value),
)

const renderedHtml = computed(() => renderMarkdownHtml(draftContent.value))

/** The id whose body is being fetched, so a retry cannot stack up requests. */
let loadingId: string | null = null

// Load on mount AND on id change: a Back/Forward between two documents keeps the same component
// mounted, so an `onMounted`-only fetch would leave the previous document's body on screen under
// the new title. Prev-value guard on update — same load the watcher did.
async function loadForDocument(id: string) {
  if (!id || !workspaceId.value || loadingId === id) return
  loadingId = id
  const doc = await documentsStore.loadDocument(workspaceId.value, id).finally(() => {
    if (loadingId === id) loadingId = null
  })
  if (!doc) return
  // `loadDocument` guarantees a body; the `?? ''` is for the type, not a case.
  const body = doc.content ?? ''
  draftTitle.value = doc.title
  draftContent.value = body
  savedTitle.value = doc.title
  savedContent.value = body
  officeDirty.value = false
  bodyLoaded.value = true
  editing.value = false
}

let prevDocumentId = props.documentId

// True once the store has held a row for this id, so a later absence means "deleted", not
// "the list has not loaded yet".
let hadDocumentRow = false

/** Adopt a row that changed underneath us — an agent `document_markdown` edit reaches this view as an SSE
 * refresh. Unsaved edits win: the draft is kept and only the saved baseline moves, so Save still
 * sends just the user's own fields. */
function syncFromStore() {
  const row = document_.value
  if (!row) {
    if (!hadDocumentRow || !documentsStore.loaded) return
    // The open document is gone from a fully-loaded list — an agent `document_markdown` delete removed it.
    // Staying would render "Loading document…" forever.
    hadDocumentRow = false
    router.replace(buildAppUrl({ workspaceId: workspaceId.value ?? '' })).catch(() => {
      // Nothing to recover: a rejected duplicate navigation already means the URL is what the
      // user asked for.
    })
    return
  }
  hadDocumentRow = true
  // A list refresh replaces the row with a body-less one. The title still
  // tracks the server; the body is left alone, because the open document's
  // body is the editor's, not the sidebar's.
  const rowContent = typeof row.content === 'string' ? row.content : null
  if (
    row.title === savedTitle.value &&
    (rowContent === null || rowContent === savedContent.value)
  ) {
    return
  }
  const dirty = isDirty.value
  savedTitle.value = row.title
  if (rowContent !== null) savedContent.value = rowContent
  if (dirty) return
  draftTitle.value = row.title
  if (rowContent !== null) draftContent.value = rowContent
}

onMounted(() => {
  void loadForDocument(props.documentId)
})
onUpdated(() => {
  if (props.documentId !== prevDocumentId) {
    prevDocumentId = props.documentId
    hadDocumentRow = false
    bodyLoaded.value = false
    void loadForDocument(props.documentId)
    return
  }
  // On a cold load the workspace resolves AFTER mount, so the first
  // `loadForDocument` returns early and the body would never arrive. Retry
  // until it does; `bodyLoaded` stops this the moment the body is in.
  if (!bodyLoaded.value && workspaceId.value && document_) {
    void loadForDocument(props.documentId)
  }
  syncFromStore()
})

const startEditing = () => {
  editing.value = true
}

const cancelEditing = () => {
  draftTitle.value = savedTitle.value
  draftContent.value = savedContent.value
  editing.value = false
}

const save = async () => {
  if (!workspaceId.value || !isDirty.value) {
    editing.value = false
    return
  }
  // Send ONLY the fields the user actually changed. Sending both is safe when the draft is fresh,
  // but this view can sit open for a long time and the agent's `document_markdown` edit may have rewritten
  // the body in the meantime — a whole-body PATCH would then silently revert that edit.
  const patch: { title?: string; content?: string } = {}
  if (draftTitle.value !== savedTitle.value) patch.title = draftTitle.value
  if (isOffice.value) {
    // Only when the editor reported an edit: a rename must not rewrite the
    // body, or it would revert an agent `document_markdown` edit that landed meanwhile.
    if (officeDirty.value) {
      const snapshot = officeEditor.value?.snapshot()
      if (snapshot !== null && snapshot !== undefined) {
        patch.content = serializeOfficeBody(officeKind.value, snapshot)
      }
    }
  } else if (draftContent.value !== savedContent.value) {
    patch.content = draftContent.value
  }
  if (Object.keys(patch).length === 0) {
    editing.value = false
    return
  }

  const updated = await documentsStore.updateDocument(workspaceId.value, props.documentId, patch)
  if (updated) {
    savedTitle.value = updated.title
    // A PATCH response carries the body; the `?? ''` is for the type only.
    savedContent.value = updated.content ?? ''
    officeDirty.value = false
    editing.value = false
  }
}

const remove = async () => {
  if (!workspaceId.value) return
  const ok = await documentsStore.deleteDocument(workspaceId.value, props.documentId)
  if (!ok) return
  // Leaving a deleted document selected would render a permanently empty view. The document owns
  // its path, so there is no query param to drop — leave the page by going back to the workspace
  // root, which is where the user was before they opened any document.
  router.replace(buildAppUrl({ workspaceId: workspaceId.value })).catch(() => {
    // Nothing to recover: a rejected duplicate navigation already means
    // the URL is what the user asked for.
  })
}
</script>

<template>
  <!-- Fills <main> as a normal page. It used to be an absolute overlay
       that kept whatever was underneath mounted, which is what let the
       chat's floating chrome paint over the document; a document now owns
       the main view outright, so plain flex sizing is both correct and
       enough. -->
  <div
    class="flex-1 flex flex-col min-h-0"
    style="background-color: var(--semantic-content-bg)"
    data-testid="documents-view"
  >
    <!-- Load failure is its own block, not a blank pane. A silently empty
         view is indistinguishable from a deleted document. -->
    <div
      v-if="documentsStore.error && !document_"
      class="p-6 text-body"
      style="color: var(--semantic-error)"
      data-testid="documents-view-error"
    >
      {{ documentsStore.error }}
    </div>

    <div
      v-else-if="!document_"
      class="p-6 text-body"
      style="color: var(--semantic-text-dim)"
      data-testid="documents-view-missing"
    >
      Loading document…
    </div>

    <template v-else>
      <header
        class="shrink-0 flex items-center gap-2 px-4 h-9 border-b"
        style="border-color: var(--color-border)"
      >
        <input
          v-if="editing"
          v-model="draftTitle"
          class="flex-1 bg-transparent outline-none text-lead"
          style="color: var(--semantic-text)"
          data-testid="documents-title-input"
          aria-label="Document title"
        />
        <span
          v-else
          class="text-lead truncate"
          style="color: var(--semantic-text)"
          data-testid="documents-title"
        >
          {{ document_.title }}
        </span>

        <div class="ml-auto flex items-center gap-2 shrink-0">
          <template v-if="isOffice">
            <button
              v-if="editing"
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim)"
              data-testid="documents-cancel"
              @click="cancelEditing"
            >
              Cancel
            </button>
            <button
              v-else
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim)"
              data-testid="documents-edit"
              @click="startEditing"
            >
              Rename
            </button>
            <button
              class="text-meta px-2 h-[var(--sb-hit)] font-medium transition-opacity hover:opacity-100 disabled:opacity-40"
              style="color: var(--semantic-link)"
              data-testid="documents-save"
              :disabled="!isDirty || documentsStore.saving"
              @click="save"
            >
              {{ documentsStore.saving ? 'Saving…' : 'Save' }}
            </button>
            <button
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-error)"
              data-testid="documents-delete"
              @click="remove"
            >
              Delete
            </button>
          </template>

          <template v-else>
            <button
              v-if="editing"
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim)"
              data-testid="documents-preview-toggle"
              @click="showPreview = !showPreview"
            >
              {{ showPreview ? 'Hide preview' : 'Show preview' }}
            </button>
            <template v-if="editing">
              <button
                class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
                style="color: var(--semantic-text-dim)"
                data-testid="documents-cancel"
                @click="cancelEditing"
              >
                Cancel
              </button>
              <button
                class="text-meta px-2 h-[var(--sb-hit)] font-medium transition-opacity hover:opacity-100 disabled:opacity-40"
                style="color: var(--semantic-link)"
                data-testid="documents-save"
                :disabled="!isDirty || documentsStore.saving"
                @click="save"
              >
                {{ documentsStore.saving ? 'Saving…' : 'Save' }}
              </button>
            </template>
            <template v-else>
              <button
                class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
                style="color: var(--semantic-text-dim)"
                data-testid="documents-edit"
                @click="startEditing"
              >
                Edit
              </button>
              <button
                class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
                style="color: var(--semantic-error)"
                data-testid="documents-delete"
                @click="remove"
              >
                Delete
              </button>
            </template>
          </template>
        </div>
      </header>

      <!-- An office document is edited in place: the grid IS the editor.
           `:key` gives each document its own Univer instance, because the
           component stays mounted across a Back/Forward. -->
      <template v-if="isOffice">
        <OfficeDocumentEditor
          v-if="bodyLoaded"
          :key="props.documentId"
          ref="officeEditor"
          :body="savedContent"
          @change="officeDirty = true"
        />
        <div
          v-else
          class="p-6 text-body"
          style="color: var(--semantic-text-dim)"
          data-testid="documents-office-loading"
        >
          Loading document…
        </div>
      </template>

      <!-- An HTML document is its own page: the source on the left while
           editing, the rendered page on the right. The iframe is sandboxed
           WITHOUT `allow-same-origin`, so the page runs on a null origin and
           cannot reach the app. -->
      <div v-else-if="isHtml" class="flex-1 min-h-0 flex" data-testid="documents-html-body">
        <textarea
          v-if="editing"
          v-model="draftContent"
          class="flex-1 min-w-0 p-4 bg-transparent outline-none resize-none text-body font-mono"
          style="color: var(--semantic-text)"
          data-testid="documents-content-input"
          aria-label="HTML source"
          spellcheck="false"
        />
        <iframe
          v-if="!editing || showPreview"
          :srcdoc="draftContent"
          sandbox="allow-scripts allow-forms"
          referrerpolicy="no-referrer"
          class="flex-1 min-w-0 border-0"
          :style="editing ? 'border-left: 1px solid var(--color-border)' : ''"
          title="HTML preview"
          data-testid="documents-html-preview"
        ></iframe>
      </div>

      <!-- Both panes are always mounted while editing. `v-if` on the
           textarea would drop the caret and the scroll position on every
           preview toggle. -->
      <div v-else class="flex-1 min-h-0 flex" data-testid="documents-body">
        <textarea
          v-if="editing"
          v-model="draftContent"
          class="flex-1 min-w-0 p-4 bg-transparent outline-none resize-none text-body font-mono"
          style="color: var(--semantic-text)"
          data-testid="documents-content-input"
          aria-label="Document content"
          spellcheck="false"
        />
        <div
          v-else
          class="flex-1 min-w-0 p-4 overflow-y-auto markdown-content"
          style="color: var(--semantic-text)"
          data-testid="documents-rendered"
          v-html="renderedHtml"
        />
        <div
          v-if="editing && showPreview"
          class="flex-1 min-w-0 p-4 overflow-y-auto border-l markdown-content"
          style="border-color: var(--color-border); color: var(--semantic-text)"
          data-testid="documents-preview"
          v-html="renderedHtml"
        />
      </div>
    </template>
  </div>
</template>
