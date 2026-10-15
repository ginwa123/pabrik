<!--
  PropertiesPanel — the right-rail form for editing the selected
  element's properties. Mirrors the Figma/Sketch "design" pane.

  Layout (top → bottom):
    1. Header — element name + type label.
    2. Empty state — when no element is selected, show a hint.
    3. Geometry section — x/y/width/height/rotation inputs.
    4. Style section — fill color, stroke color + width, corner radius,
       opacity.
    5. Type-specific section — text_content + text_style for text,
       image_url for image.
    6. HTML section — Monaco editor (lazy-loaded) for the element's
       stored HTML body, with a save button.
    7. Delete button (with confirm) — bottom of the panel.

  Form inputs are bound to the `element` prop via v-model.number for
  numerics and v-model for strings; every change fires `update` with
  the patch. The parent (DesignView) is responsible for debouncing
  (text inputs would otherwise fire 1+/char; the parent's store
  action handles the API call).

  The Monaco editor is loaded lazily on first expand via dynamic
  `import('monaco-editor')`. The import is gated on user click so
  we don't pay the ~3 MB download cost until the user actually wants
  to edit HTML. If monaco-editor is not installed (defensive), we
  fall back to a <textarea> with a TODO comment.

  Public API:
    props:
      element   DesignElement | null   the selected element (or null)
      readonly  boolean                when true, all inputs are disabled
    emits:
      update      [patch: Partial<DesignElement>]
      htmlChanged [html: string]
      delete      [elementId: string]

  Test contract:
    data-testid="properties-panel" on the wrapper
    data-testid="properties-panel-empty" on the empty state
    data-testid="properties-input-{name}" on each input
    data-testid="properties-toggle-html-editor" on the expand button
    data-testid="properties-html-editor" on the Monaco container
    data-testid="properties-delete-button" on the delete button
-->
<script setup lang="ts">
import { computed, onBeforeUnmount, onUpdated, ref } from 'vue'
import type { DesignElement } from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'
import ListSkeleton from '../shell/ListSkeleton.vue'
import { useDesignHistory } from '../../composables/useDesignHistory'
import { useDesignHistoryStore } from '../../stores/designHistory'

const workspacesStore = useWorkspacesStore()

// True while the active page's element fetch is in flight. Without it
// the panel renders "Select an element to edit its properties" during
// the fetch — a false statement about the page's data.
const isElementsLoading = computed(() => {
  const itemId = workspacesStore.activeWorkspaceItemId
  const pageId = workspacesStore.activeDesignPageId
  if (!itemId || !pageId) return false
  return workspacesStore.isDesignElementsLoading(itemId, pageId)
})

// Undo/redo plan (Chunk 4): one history entry per field commit. Pre-state is captured on input
// focus; post-state on @change. We instantiate the composable here (rather than at DesignView) so
// the capture is local to each field — no need to plumb ids through props.
const history = useDesignHistory(computed(() => workspacesStore.activeDesignPageId))

const props = withDefaults(
  defineProps<{
    // Pass the full selection set (not just the "active" one).
    // The panel renders one of three states based on `elements.length`: 0 → empty state 1 →
    // single-element form >1 → multi-select banner The parent owns the selection logic; this
    // component just formats the current selection into the right UI.
    elements: DesignElement[]
    readonly?: boolean
    // When true, the parent canvas is in Preview mode (toggle in the canvas header bar). The form
    // fields are hidden and replaced with a "you're previewing" banner — the user is interacting
    // with the mockup, not editing its metadata.
    previewMode?: boolean
  }>(),
  {
    readonly: false,
    previewMode: false,
  },
)

// Computed convenience: the single element when exactly one is selected.
// Templates can use this instead of `elements[0] ?? null` everywhere.
const singleElement = computed<DesignElement | null>(() =>
  props.elements.length === 1 ? (props.elements[0] ?? null) : null,
)

const emit = defineEmits<{
  update: [patch: Partial<DesignElement>]
  htmlChanged: [html: string]
  delete: [elementId: string]
}>()

// ─── Form field handlers ─────────────────────────────────────────────── Each handler builds a
// patch object and emits `update`.
// We use dedicated handlers (instead of inline @change on every input) so the emit always carries
// the exact field that changed — the parent's store action treats it as a sparse merge.
type NumericField = 'x' | 'y' | 'width' | 'height' | 'rotation' | 'stroke_width' | 'corner_radius' | 'opacity'
type StringField = 'name' | 'fill' | 'stroke' | 'text_content' | 'text_style' | 'image_url'

const handleNumericChange = (field: NumericField, value: number): void => {
  const el = singleElement.value
  if (el) {
    void history.capturePreState([el.id])
    // Post-state is captured via the debounced schedule below — when
    // the element's field actually changes (via the store update
    // mirror), we capture post-state. This fires once per @change.
  }
  emit('update', { [field]: value } as Partial<DesignElement>)
  schedulePropertiesPanelCapturePost()
}

const handleStringChange = (field: StringField, value: string): void => {
  const el = singleElement.value
  if (el) {
    void history.capturePreState([el.id])
  }
  emit('update', { [field]: value } as Partial<DesignElement>)
  schedulePropertiesPanelCapturePost()
}

// Watch the single-element fields for actual change. When any field updates (from a PropertiesPanel
// edit), we capture post- state. The watcher is debounced to collapse rapid edits into a single
// entry.
const fieldsFingerprint = (el: DesignElement): string =>
  `${el.x}|${el.y}|${el.width}|${el.height}|${el.rotation}|${el.fill}|${el.stroke}|${el.stroke_width}|${el.corner_radius}|${el.opacity}|${el.name}|${el.text_content}|${el.image_url}|${el.type}`
let propertiesPanelPostTimer: ReturnType<typeof setTimeout> | null = null
function schedulePropertiesPanelCapturePost(): void {
  // Snapshot before the parent's store update lands; the debounced
  // callback only captures post-state when the fields actually changed.
  const before = singleElement.value ? fieldsFingerprint(singleElement.value) : ''
  if (propertiesPanelPostTimer) clearTimeout(propertiesPanelPostTimer)
  propertiesPanelPostTimer = setTimeout(() => {
    propertiesPanelPostTimer = null
    const el = singleElement.value
    if (el && before !== fieldsFingerprint(el)) void history.capturePostState([el.id])
  }, 80)
}

// ─── Confirm-before-delete state ───────────────────────────────────────
const showDeleteConfirm = ref(false)

const handleDeleteClick = (): void => {
  if (props.readonly) return
  if (!singleElement.value) return
  showDeleteConfirm.value = true
}

const handleDeleteConfirm = (): void => {
  if (!singleElement.value) return
  emit('delete', singleElement.value.id)
  showDeleteConfirm.value = false
}

const handleDeleteCancel = (): void => {
  showDeleteConfirm.value = false
}

// ─── HTML editor (Monaco lazy-load) ────────────────────────────────────
const htmlExpanded = ref(false)
const htmlDraft = ref('')
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
const monacoEditor = ref<any | null>(null)
const monacoContainerRef = ref<HTMLDivElement | null>(null)
const monacoLoadError = ref<string | null>(null)

// When the user expands the editor and the element changes, seed the draft with the current HTML
// body. We don't auto-pull on every element switch — that would clobber the user's in-progress
// edit. Instead, we pull on (a) first expand and (b) explicit element change while collapsed.
// Seed the draft when the selected element changes while collapsed (prev-id guard on update).
// Expanded edits are never clobbered.
const prevElementId = ref<string | null>(singleElement.value?.id ?? null)
onUpdated(() => {
  const id = singleElement.value?.id ?? null
  if (id !== prevElementId.value) {
    prevElementId.value = id
    if (!htmlExpanded.value && singleElement.value) {
      htmlDraft.value = singleElement.value.text_content || ''
    }
  }
})

const handleExpandHtml = async (): Promise<void> => {
  htmlExpanded.value = !htmlExpanded.value
  if (!htmlExpanded.value) return
  if (!singleElement.value) return
  // Seed the draft on first expand.
  htmlDraft.value = singleElement.value.text_content || ''

  // Lazy-load Monaco on first expand. Dynamic import is the only way
  // to defer the ~3 MB bundle; bundlers will code-split at this
  // import call.
  if (monacoEditor.value) return
  try {
    const monaco = await import(/* @vite-ignore */ 'monaco-editor')
    // Disable web workers — Monaco's default worker setup doesn't work in our Vite/jsdom
    // environment; the simpler approach is to run monaco in the main thread (slightly slower
    // autocomplete but no worker setup).
    // For the v1 design use case (single-user, small HTML snippets) this is fine.
    if (typeof window !== 'undefined') {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      ;(window as any).MonacoEnvironment = {
        getWorker: () => ({
          postMessage: () => {},
          terminate: () => {},
          addEventListener: () => {},
          removeEventListener: () => {},
        }),
      }
    }
    if (!monacoContainerRef.value) return
    const editor = monaco.editor.create(monacoContainerRef.value, {
      value: htmlDraft.value,
      language: 'html',
      theme: 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 12,
      lineNumbers: 'on',
      wordWrap: 'on',
    })
    editor.onDidChangeModelContent(() => {
      htmlDraft.value = editor.getValue()
    })
    monacoEditor.value = editor
    monacoLoadError.value = null
  } catch (err) {
    // Monaco not installed or failed to load — fall back to textarea
    // (the v-if on the textarea fallback covers this).
    monacoLoadError.value = err instanceof Error ? err.message : String(err)
    monacoEditor.value = null
  }
}

// Wire-up (undo/redo plan Chunk 1): was `emit('htmlChanged', htmlDraft.value)` which went upward to
// DesignView → re-emitted → AppLayout had no listener → silent drop. Now we call the store action
// directly.
// Falls back to the emit if the store action throws (e.g. when the single-element contract is
// violated mid-gesture). Undo/redo plan (Chunk 6): push an html_edit entry that records the
// before/after body so undo can restore the previous body.
const handleHtmlSave = async (): Promise<void> => {
  const el = singleElement.value
  if (!el) {
    emit('htmlChanged', htmlDraft.value)
    return
  }
  // Capture pre-state (before body).
  const beforeHtml = el.text_content ?? ''
  try {
    await workspacesStore.updateDesignElementHtml(
      workspacesStore.activeWorkspace?.id ?? '',
      workspacesStore.activeWorkspaceItemId ?? '',
      workspacesStore.activeDesignPageId,
      el.id,
      htmlDraft.value,
    )
    // Push the html_edit entry with before/after body so undo can
    // restore the previous HTML body via PATCH.
    void history.capturePostState([el.id]).then(() => {
      // capturePostState diffs element fields. We also need to attach the html body diff. The
      // composable's capturePostState doesn't fetch HTML bodies (that would be slow on every drag);
      // for html_edit we use a dedicated push.
      const htmlHistoryStore = useDesignHistoryStore()
      htmlHistoryStore.push(workspacesStore.activeDesignPageId, {
        id: `entry_html_${Date.now()}_${Math.random()}`,
        timestamp: Date.now(),
        label: 'Edit HTML body',
        pageId: workspacesStore.activeDesignPageId,
        kind: 'html_edit',
        changes: [
          {
            elementId: el.id,
            before: { text_content: beforeHtml },
            after: { text_content: htmlDraft.value },
            htmlBody: { before: beforeHtml, after: htmlDraft.value },
          },
        ],
      })
    })
  } catch {
    emit('htmlChanged', htmlDraft.value)
  }
}

const handleHtmlCancel = (): void => {
  htmlDraft.value = singleElement.value?.text_content || ''
  if (monacoEditor.value) {
    monacoEditor.value.setValue(htmlDraft.value)
  }
}

// Tear down the Monaco editor on component unmount to release its
// listeners and DOM references.
onBeforeUnmount(() => {
  if (monacoEditor.value) {
    monacoEditor.value.dispose()
    monacoEditor.value = null
  }
})

// ─── Computed helpers ──────────────────────────────────────────────────
const isTextElement = computed(() => singleElement.value?.type === 'text')
const isImageElement = computed(() => singleElement.value?.type === 'image')
const showGeometrySection = computed(() => singleElement.value !== null)
const showStyleSection = computed(() => singleElement.value !== null)
const showTypeSpecificSection = computed(
  () => isTextElement.value || isImageElement.value,
)
</script>

<template>
  <div
    class="properties-panel flex flex-col h-full min-h-0 overflow-y-auto"
    style="scrollbar-width: thin;"
    data-testid="properties-panel"
  >
    <!-- ─── Preview-mode banner ────────────────────────────────────── -->
    <!--
      Shown when the parent canvas is in Preview mode (toggle in
      the canvas header bar). Replaces the entire form with a
      compact hint — the user is interacting with the rendered HTML,
      not editing element metadata. Pressing Esc (handled in
      DesignView.vue) exits Preview and restores the form.
    -->
    <div
      v-if="previewMode"
      class="flex-1 flex items-center justify-center p-6 text-body"
      style="color: var(--semantic-text-dim);"
      data-testid="properties-panel-preview"
    >
      <div class="text-center">
        <div class="text-display mb-2" aria-hidden="true">▶</div>
        <div>Previewing — interact with the mockup</div>
        <div class="text-dense mt-1" style="opacity: 0.7;">
          Press Esc to return to editing
        </div>
      </div>
    </div>

    <!-- ─── Multi-select banner (Chunk 2) ──────────────────────────── -->
    <!--
      When 2+ elements are selected, the PropertiesPanel hides the
      single-element form and shows a banner. Future enhancements
      (align/distribute batch actions) will live here. For now, the
      banner tells the user how many are selected and how to clear.
    -->
    <div
      v-else-if="elements.length > 1"
      class="flex-1 flex items-center justify-center p-6 text-body"
      style="color: var(--semantic-text-dim);"
      data-testid="properties-panel-multi"
    >
      <div class="text-center">
        <div class="text-display mb-2" aria-hidden="true">▦</div>
        <div>{{ elements.length }} elements selected</div>
        <div class="text-dense mt-1" style="opacity: 0.7;">
          Press Esc to deselect all
        </div>
      </div>
    </div>

    <!-- ─── Empty state ────────────────────────────────────────────── -->
    <ListSkeleton
      v-if="isElementsLoading"
      :rows="8"
      row-height="h-8"
      test-id="properties-panel-skeleton"
    />
    <div
      v-else-if="elements.length === 0"
      class="flex-1 flex items-center justify-center p-6 text-body"
      style="color: var(--semantic-text-dim);"
      data-testid="properties-panel-empty"
    >
      <div class="text-center">
        <div class="text-display mb-2" aria-hidden="true">◇</div>
        <div>Select an element to edit its properties</div>
      </div>
    </div>

    <template v-if="singleElement && !previewMode">
      <!-- ─── Header ───────────────────────────────────────────────── -->
      <div
        class="px-4 py-3 shrink-0"
        style="border-bottom: 1px solid var(--color-border);"
      >
        <div class="text-dense" style="color: var(--semantic-text-dim);">
          {{ singleElement.type }}
        </div>
        <input
          type="text"
          :value="singleElement.name"
          :disabled="readonly"
          data-testid="properties-input-name"
          class="w-full bg-transparent text-lead font-semibold outline-none mt-1"
          style="color: var(--semantic-text);"
          placeholder="Element name"
          @change="(e) => handleStringChange('name', (e.target as HTMLInputElement).value)"
        />
      </div>

      <!-- ─── Geometry section ─────────────────────────────────────── -->
      <section
        v-if="showGeometrySection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-geometry"
      >
        <div class="text-dense font-semibold mb-2" style="color: var(--semantic-text-dim);">
          Geometry
        </div>
        <div class="grid grid-cols-2 gap-2">
          <label class="text-dense" style="color: var(--semantic-text-dim);">
            X
            <input
              type="number"
              :value="singleElement.x"
              :disabled="readonly"
              data-testid="properties-input-x"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('x', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-dense" style="color: var(--semantic-text-dim);">
            Y
            <input
              type="number"
              :value="singleElement.y"
              :disabled="readonly"
              data-testid="properties-input-y"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('y', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-dense" style="color: var(--semantic-text-dim);">
            W
            <input
              type="number"
              :value="singleElement.width"
              :disabled="readonly"
              data-testid="properties-input-width"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('width', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-dense" style="color: var(--semantic-text-dim);">
            H
            <input
              type="number"
              :value="singleElement.height"
              :disabled="readonly"
              data-testid="properties-input-height"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('height', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="col-span-2 text-dense" style="color: var(--semantic-text-dim);">
            Rotation (deg)
            <input
              type="number"
              :value="singleElement.rotation"
              :disabled="readonly"
              data-testid="properties-input-rotation"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('rotation', Number((e.target as HTMLInputElement).value))"
            />
          </label>
        </div>
      </section>

      <!-- ─── Style section ────────────────────────────────────────── -->
      <section
        v-if="showStyleSection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-style"
      >
        <div class="text-dense font-semibold mb-2" style="color: var(--semantic-text-dim);">
          Style
        </div>
        <div class="space-y-2">
          <label class="block text-dense" style="color: var(--semantic-text-dim);">
            Fill color
            <input
              type="text"
              :value="singleElement.fill"
              :disabled="readonly"
              placeholder="(none)"
              data-testid="properties-input-fill"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('fill', (e.target as HTMLInputElement).value)"
            />
          </label>
          <div class="grid grid-cols-2 gap-2">
            <label class="text-dense" style="color: var(--semantic-text-dim);">
              Stroke
              <input
                type="text"
                :value="singleElement.stroke"
                :disabled="readonly"
                placeholder="(none)"
                data-testid="properties-input-stroke"
                class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none font-mono"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleStringChange('stroke', (e.target as HTMLInputElement).value)"
              />
            </label>
            <label class="text-dense" style="color: var(--semantic-text-dim);">
              Width
              <input
                type="number"
                :value="singleElement.stroke_width"
                :disabled="readonly"
                data-testid="properties-input-stroke-width"
                class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('stroke_width', Number((e.target as HTMLInputElement).value))"
              />
            </label>
          </div>
          <div class="grid grid-cols-2 gap-2">
            <label class="text-dense" style="color: var(--semantic-text-dim);">
              Corner radius
              <input
                type="number"
                :value="singleElement.corner_radius"
                :disabled="readonly"
                data-testid="properties-input-corner-radius"
                class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('corner_radius', Number((e.target as HTMLInputElement).value))"
              />
            </label>
            <label class="text-dense" style="color: var(--semantic-text-dim);">
              Opacity (0-1)
              <input
                type="number"
                step="0.05"
                min="0"
                max="1"
                :value="singleElement.opacity"
                :disabled="readonly"
                data-testid="properties-input-opacity"
                class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('opacity', Number((e.target as HTMLInputElement).value))"
              />
            </label>
          </div>
        </div>
      </section>

      <!-- ─── Type-specific section ────────────────────────────────── -->
      <section
        v-if="showTypeSpecificSection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-type"
      >
        <div class="text-dense font-semibold mb-2" style="color: var(--semantic-text-dim);">
          {{ singleElement.type === 'text' ? 'Text' : 'Image' }}
        </div>
        <template v-if="isTextElement">
          <label class="block text-dense mb-2" style="color: var(--semantic-text-dim);">
            Text content
            <textarea
              :value="singleElement.text_content"
              :disabled="readonly"
              rows="3"
              data-testid="properties-input-text-content"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('text_content', (e.target as HTMLTextAreaElement).value)"
            />
          </label>
          <label class="block text-dense" style="color: var(--semantic-text-dim);">
            Text style (font-family)
            <input
              type="text"
              :value="singleElement.text_style"
              :disabled="readonly"
              placeholder="sans-serif"
              data-testid="properties-input-text-style"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('text_style', (e.target as HTMLInputElement).value)"
            />
          </label>
        </template>
        <template v-else-if="isImageElement">
          <label class="block text-dense" style="color: var(--semantic-text-dim);">
            Image URL
            <input
              type="text"
              :value="singleElement.image_url"
              :disabled="readonly"
              placeholder="https://..."
              data-testid="properties-input-image-url"
              class="w-full mt-0.5 px-2 py-1 rounded text-body outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('image_url', (e.target as HTMLInputElement).value)"
            />
          </label>
        </template>
      </section>

      <!-- ─── HTML editor section (lazy Monaco) ────────────────────── -->
      <section
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-html"
      >
        <button
          type="button"
          :disabled="readonly"
          data-testid="properties-toggle-html-editor"
          class="w-full text-left text-dense font-semibold flex items-center gap-2 mb-2 transition-colors"
          style="color: var(--semantic-text-dim);"
          @click="handleExpandHtml"
        >
          <span aria-hidden="true">{{ htmlExpanded ? '▼' : '▶' }}</span>
          <span>HTML Body (Monaco editor)</span>
        </button>
        <div v-if="htmlExpanded" class="space-y-2">
          <div
            v-if="!monacoLoadError && monacoEditor"
            ref="monacoContainerRef"
            data-testid="properties-html-editor"
            style="height: 200px; border: 1px solid var(--color-border); border-radius: 4px; overflow: hidden;"
          />
          <!-- Fallback textarea when Monaco failed to load -->
          <div v-else>
            <textarea
              v-model="htmlDraft"
              :disabled="readonly"
              rows="8"
              data-testid="properties-html-fallback-textarea"
              class="w-full px-2 py-1 rounded text-dense font-mono outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              :placeholder="monacoLoadError ? `Monaco failed to load: ${monacoLoadError}` : 'Edit HTML body'"
            />
            <div
              v-if="monacoLoadError"
              class="text-micro mt-1"
              style="color: var(--semantic-text-dim);"
            >
              TODO: install monaco-editor for syntax highlighting
            </div>
          </div>
          <div class="flex gap-2 justify-end">
            <button
              type="button"
              :disabled="readonly"
              data-testid="properties-html-cancel"
              class="px-2 py-1 rounded text-dense"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
              @click="handleHtmlCancel"
            >Cancel</button>
            <button
              type="button"
              :disabled="readonly"
              data-testid="properties-html-save"
              class="px-2 py-1 rounded text-dense"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              @click="handleHtmlSave"
            >Save</button>
          </div>
        </div>
      </section>

      <!-- ─── Delete section (with confirm) ────────────────────────── -->
      <section
        class="px-4 py-3 mt-auto"
        data-testid="properties-section-delete"
      >
        <div v-if="!showDeleteConfirm">
          <button
            type="button"
            :disabled="readonly"
            data-testid="properties-delete-button"
            class="w-full px-3 py-1.5 rounded text-body font-medium transition-all"
            style="background-color: rgba(220, 38, 38, 0.18); color: rgb(248, 113, 113); border: 1px solid rgba(220, 38, 38, 0.4);"
            @click="handleDeleteClick"
          >
            Delete element
          </button>
        </div>
        <div
          v-else
          class="space-y-2"
          data-testid="properties-delete-confirm"
        >
          <div class="text-dense" style="color: var(--semantic-text);">
            Delete "{{ singleElement.name }}"? This cannot be undone.
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="properties-delete-cancel"
              class="flex-1 px-2 py-1 rounded text-dense"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
              @click="handleDeleteCancel"
            >Cancel</button>
            <button
              type="button"
              data-testid="properties-delete-confirm"
              class="flex-1 px-2 py-1 rounded text-dense font-medium"
              style="background-color: rgba(220, 38, 38, 0.6); color: white;"
              @click="handleDeleteConfirm"
            >Delete</button>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar {
  width: 6px;
}
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-track {
  background: transparent;
}
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 3px;
}
</style>