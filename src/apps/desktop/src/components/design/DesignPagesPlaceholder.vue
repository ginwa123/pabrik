<script setup lang="ts">
defineProps<{
  loading: boolean
  error: string | null
}>()

const emit = defineEmits<{ addPage: [] }>()
</script>

<template>
  <!--
    (2026-08-06): the <DesignPageTabs> row at the top of DesignView
    is removed. Pages now live in the workspace sidebar tree
    (WorkspaceItem.vue renders DesignPageRow under expanded design
    items). The canvas header still shows the active page name so
    the user knows which page they're on. The empty state below
    ("+ Add the first page") is preserved for users who navigate
    into DesignView before expanding the tree (e.g. via deep link).
  -->

  <!-- ─── Loading state for pages ───────────────────────────────── -->
  <div
    v-if="loading"
    class="flex-1 flex items-center justify-center text-body"
    style="color: var(--semantic-text-dim)"
    data-testid="design-pages-loading"
  >
    Loading pages…
  </div>

  <!-- ─── Error state for pages ─────────────────────────────────── -->
  <div
    v-else-if="error"
    class="flex-1 flex items-center justify-center text-body"
    style="color: rgb(248, 113, 113)"
    data-testid="design-pages-error"
  >
    Failed to load pages: {{ error }}
  </div>

  <!-- ─── Empty state (no pages) ────────────────────────────────── -->
  <div v-else class="flex-1 flex items-center justify-center" data-testid="design-pages-empty">
    <div class="text-center">
      <div class="text-display mb-2" style="color: var(--semantic-text-dim)" aria-hidden="true">
        ▤
      </div>
      <div class="text-body mb-4" style="color: var(--semantic-text-dim)">No pages yet</div>
      <button
        type="button"
        class="px-3 py-1.5 rounded-lg text-body font-medium"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        @click="emit('addPage')"
      >
        + Add the first page
      </button>
    </div>
  </div>
</template>
