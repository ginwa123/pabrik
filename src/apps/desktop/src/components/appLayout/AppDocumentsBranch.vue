<script setup lang="ts">
import DocumentsView from '../workspace/DocumentsView.vue'

defineProps<{ documentId: string }>()
</script>

<template>
  <!-- Document page (Migration 095). FIRST branch of the main view
       chain, so it REPLACES whatever was open — the chat is unmounted
       rather than left mounted underneath.

       This is why it is a `v-else-if` here and not a standalone
       `v-if` overlay: as an overlay it inherited the path it was
       opened from, and the chat's floating chrome (z-20/30/31)
       out-painted its z-index: 10, so the composer dock and scroll
       slider floated over the document. Being a page removes the
       overlap by construction instead of relying on a z-index
       ordering. The GitFileViewer / SkillViewer / code-editor
       overlays above are still overlays and still need the chat's
       own stacking containment (`isolation: isolate` on
       `.chat-column`).

       `:key` forces a fresh mount when the user moves between two
       documents (Back/Forward keeps the same component mounted, and
       DocumentsView loads on id change anyway — the key just makes
       the switch unambiguous). The id comes from the PATH, so a
       refresh or a shared link restores the same document. -->
  <DocumentsView :document-id="documentId" />
</template>
