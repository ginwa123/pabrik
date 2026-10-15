<script setup lang="ts">
// The document page (Migration 095). Reached from the sidebar's Documents section, which writes
// `/app/{ws}/doc/{id}` into the URL — a PAGE shape, so this view is the main content area and the
// chat it was opened from is unmounted (not stacked underneath).

// That is what removed the original bug, where the chat's floating chrome out-painted this
// overlay's z-index. Two modes, one textarea: - Read: the rendered markdown. - Edit: a plain
// textarea over the raw source, with a live preview toggle.

// Rendering goes through `helpers/markdown.ts` rather than `marked` directly: that helper escapes
// raw HTML BEFORE parsing, which is the repo's XSS model for every non-transcript markdown surface.

// A document body is authored by an agent that may have quoted a file it read, so this is not
// strictly self-XSS-only.
import { computed, onMounted, onUpdated, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useDocumentsStore } from '../../stores/documents'
import { useWorkspacesStore } from '../../stores/workspaces'
import { renderMarkdownHtml } from '../../helpers/markdown'
import { buildAppUrl } from '../../helpers/appUrl'

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

// The resolved workspace, not the raw `activeWorkspaceId` ref. The ref is
// only set by the header dropdown or a `?workspaceId=` URL restore, so a
// user who reached a document by clicking a project row left it null —
// and because the load `watch` below bails on a null workspace, the view
// sat on "Loading document…" forever with no Edit/Delete button, i.e. the
// document looked like it simply would not open.
const workspaceId = computed(() => workspacesStore.activeWorkspace?.id ?? null)

const document_ = computed(() => documentsStore.findById(props.documentId))

const isDirty = computed(
  () => draftTitle.value !== savedTitle.value || draftContent.value !== savedContent.value,
)

const renderedHtml = computed(() => renderMarkdownHtml(draftContent.value))

// Load on mount AND on id change: a Back/Forward between two documents keeps the same component
// mounted, so an `onMounted`-only fetch would leave the previous document's body on screen under
// the new title. Prev-value guard on update — same load the watcher did.
async function loadForDocument(id: string) {
  if (!id || !workspaceId.value) return
  const doc = await documentsStore.loadDocument(workspaceId.value, id)
  if (!doc) return
  draftTitle.value = doc.title
  draftContent.value = doc.content
  savedTitle.value = doc.title
  savedContent.value = doc.content
  editing.value = false
}

let prevDocumentId = props.documentId
onMounted(() => {
  void loadForDocument(props.documentId)
})
onUpdated(() => {
  if (props.documentId === prevDocumentId) return
  prevDocumentId = props.documentId
  void loadForDocument(props.documentId)
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
  // but this view can sit open for a long time and the agent's `edit_document` may have rewritten
  // the body in the meantime — a whole-body PATCH would then silently revert that edit.

  // Partial patches are also what the backend's omitted-vs-empty semantics are built for.
  const patch: { title?: string; content?: string } = {}
  if (draftTitle.value !== savedTitle.value) patch.title = draftTitle.value
  if (draftContent.value !== savedContent.value) patch.content = draftContent.value

  const updated = await documentsStore.updateDocument(workspaceId.value, props.documentId, patch)
  if (updated) {
    savedTitle.value = updated.title
    savedContent.value = updated.content
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
        </div>
      </header>

      <!-- Both panes are always mounted while editing. `v-if` on the
           textarea would drop the caret and the scroll position on every
           preview toggle. -->
      <div class="flex-1 min-h-0 flex" data-testid="documents-body">
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
