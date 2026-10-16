<script setup lang="ts">
// The "Documents" sidebar section (Migration 095) — a collapsible list rendered directly BELOW the
// Projects section, not inside it. Three deliberate choices, each for a reason that is easy to get
// wrong: 1. Header markup is copied from `ProjectsList.vue`, not re-invented.
import { computed, onMounted, onUpdated } from 'vue'
import { useRouter } from 'vue-router'
import { useSidebarStore } from '../../stores/sidebar'
import { useDocumentsStore } from '../../stores/documents'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { buildAppUrl } from '../../helpers/appUrl'
import SidebarSkeleton from '../shell/SidebarSkeleton.vue'

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

const toggleDocumentsSection = () => {
  const wasExpanded = sidebarStore.documentsExpanded
  sidebarStore.toggleDocumentsExpanded()
  // Lazy first fetch: the section is collapsed on a returning user more
  // often than not, and the list read is the sidebar's hottest query.
  if (!wasExpanded && props.workspaceId && !documentsStore.loaded) {
    void documentsStore.fetchDocuments(props.workspaceId)
  }
}

const selectDocument = (id: string) => {
  const wsId = props.workspaceId ?? workspacesStore.activeWorkspace?.id ?? null
  if (!wsId) {
    // No workspace means no document page to build a URL for. The rows
    // only render with a workspace selected, so this is a guard against
    // a stale list surviving a workspace switch, not a normal path.
    return
  }
  // `replace`, not `push`: clicking through five documents should not bury the previous four under
  // Back. The document is a PAGE, so this replaces whatever main view was open — the chat is
  // unmounted and the URL says plainly which document this is.
  router.replace(buildAppUrl({ workspaceId: wsId, documentId: id })).catch(() => {
    // A duplicate navigation (clicking the already-open row) rejects.
    // Nothing to recover: the URL already says what the user asked for.
  })
  // The document is the chat-equivalent of an open view, so the chat and project selections must
  // clear — two "active" rows is the visual bug the single-active-state spec exists to prevent.
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  navigationStore.clearActiveChat()
}

const createDocument = () => {
  if (!props.workspaceId) return
  void documentsStore.createDocument(props.workspaceId, 'Untitled document').then((doc) => {
    if (doc) {
      selectDocument(doc.id)
      emit('created', doc.id)
    }
  })
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
      <button
        class="px-[var(--sb-gutter)] h-7 flex items-center gap-2 cursor-pointer hover:opacity-80 transition-opacity w-full text-left border-b border-[--color-border]/40"
        data-testid="documents-section-header"
        @click="toggleDocumentsSection"
      >
        <span
          class="text-meta transition-transform duration-200"
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
          class="text-micro"
          style="color: var(--semantic-text-dim); opacity: 0.7"
          data-testid="documents-count"
          >{{ documents.length }}</span
        >
        <button
          v-if="sidebarStore.documentsExpanded && workspaceId"
          class="ml-auto w-[var(--sb-hit)] h-[var(--sb-hit)] text-meta font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center"
          style="color: var(--semantic-text-dim); opacity: 0.7"
          title="New Document"
          aria-label="New Document"
          data-testid="documents-add-button"
          @click.stop="createDocument"
        >
          +
        </button>
      </button>
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
        v-else-if="workspaceId && documents.length === 0 && documentsStore.loading"
        :rows="3"
        test-id="documents-loading-skeleton"
      />

      <p
        v-else-if="documents.length === 0 && !documentsStore.loading"
        class="px-[var(--sb-gutter)] text-meta py-1"
        style="color: var(--semantic-text-dim); opacity: 0.7"
        data-testid="documents-empty"
      >
        No documents yet
      </p>

      <ul
        v-else
        class="ml-[var(--sb-indent)] space-y-0 border-l"
        style="border-color: var(--color-border)"
      >
        <li v-for="doc in documents" :key="doc.id">
          <button
            class="relative w-full flex items-center gap-2 px-[var(--sb-gutter)] h-[var(--sb-row)] rounded-lg text-dense transition-all duration-150 border-t border-transparent overflow-hidden text-left"
            :data-testid="`document-row-${doc.id}`"
            :style="
              isCurrentDocument(doc.id)
                ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="selectDocument(doc.id)"
          >
            <span class="truncate">{{ doc.title }}</span>
          </button>
        </li>
      </ul>
    </div>
  </div>
</template>
