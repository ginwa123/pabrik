<script setup lang="ts">
defineProps<{
  isPreviewMode: boolean
  pageName: string | null
  elementCount: number
  zoom: number
}>()

const emit = defineEmits<{
  addElement: []
  togglePreview: []
  zoomIn: []
  zoomOut: []
  zoomReset: []
  zoomFit: []
}>()
</script>

<template>
  <!-- Canvas header bar -->
  <div
    class="px-3 py-2 flex items-center gap-3 shrink-0"
    style="
      border-bottom: 1px solid var(--color-border);
      background-color: var(--semantic-sidebar-bg);
    "
    data-testid="design-canvas-header"
  >
    <button
      v-if="!isPreviewMode"
      type="button"
      class="px-2 py-1 rounded text-dense font-medium"
      style="
        background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
        color: var(--color-bg);
      "
      data-testid="design-add-element-button"
      @click="emit('addElement')"
    >
      + Element
    </button>
    <!--
      Undo/Redo toolbar was intentionally removed (2026-08-06):
      the feature is HIDDEN from the user in design mode.
      Internal plumbing (useDesignHistory composable +
      history.capture*() calls) is retained for clean future
      re-enable — see DesignView.undoHidden.spec.ts.
    -->
    <div
      v-if="pageName !== null"
      class="text-dense flex-1 truncate"
      style="color: var(--semantic-text)"
      :title="pageName"
    >
      {{ pageName }}
    </div>
    <div v-else class="text-dense flex-1" style="color: var(--semantic-text-dim)">
      (no page selected)
    </div>
    <div class="text-dense" style="color: var(--semantic-text-dim)">
      {{ elementCount }} element{{ elementCount === 1 ? '' : 's' }}
    </div>
    <!--
      Preview/Edit mode toggle. When active, each element's iframe
      gets `pointer-events: auto` and the edit chrome is suppressed
      — the user can type into form fields and click buttons inside
      the rendered HTML without selecting elements. Keyboard shortcut:
      Cmd/Ctrl+P toggles, Esc exits. See `isPreviewMode` ref above.
    -->
    <button
      type="button"
      class="px-2 py-0.5 rounded text-dense font-medium transition-colors"
      :style="
        isPreviewMode
          ? 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg); border: none;'
          : 'color: var(--semantic-text); border: 1px solid var(--color-border); opacity: 0.8;'
      "
      :title="
        isPreviewMode
          ? 'Exit Preview mode (shortcut: Esc)'
          : 'Preview the mockup — type into inputs, click buttons (shortcut: Cmd/Ctrl+P)'
      "
      :aria-label="isPreviewMode ? 'Exit Preview mode' : 'Enter Preview mode'"
      :aria-pressed="isPreviewMode"
      data-testid="design-preview-toggle"
      @click="emit('togglePreview')"
    >
      <span aria-hidden="true">{{ isPreviewMode ? '■ ' : '▶ ' }}</span
      >Preview
    </button>
    <div
      class="flex items-center gap-1 shrink-0"
      data-testid="design-zoom-toolbar"
      :title="`Zoom (Ctrl+wheel or trackpad pinch) — currently ${Math.round(zoom * 100)}%`"
    >
      <button
        type="button"
        class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
        style="color: var(--semantic-text); border: 1px solid var(--color-border)"
        aria-label="Zoom out (Ctrl+wheel down)"
        title="Zoom out (Ctrl+wheel down)"
        data-testid="design-zoom-out"
        @click="emit('zoomOut')"
      >
        −
      </button>
      <button
        type="button"
        class="px-2 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80 min-w-[3.5rem] text-center"
        style="color: var(--semantic-text); border: 1px solid var(--color-border)"
        :title="`Reset zoom (currently ${Math.round(zoom * 100)}%)`"
        aria-label="Reset zoom"
        data-testid="design-zoom-reset"
        @click="emit('zoomReset')"
      >
        {{ Math.round(zoom * 100) }}%
      </button>
      <button
        type="button"
        class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
        style="color: var(--semantic-text); border: 1px solid var(--color-border)"
        aria-label="Fit page to viewport (shortcut: F or Shift+1)"
        title="Fit page to viewport (F or Shift+1)"
        data-testid="design-zoom-fit"
        @click="emit('zoomFit')"
      >
        ⛶
      </button>
      <button
        type="button"
        class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
        style="color: var(--semantic-text); border: 1px solid var(--color-border)"
        aria-label="Zoom in (Ctrl+wheel up)"
        title="Zoom in (Ctrl+wheel up)"
        data-testid="design-zoom-in"
        @click="emit('zoomIn')"
      >
        +
      </button>
    </div>
  </div>
</template>
