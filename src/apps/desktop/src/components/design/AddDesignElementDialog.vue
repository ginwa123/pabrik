<!--
  AddDesignElementDialog — modal for creating a new design element.

  Mirrors AddKanbanDialog's UX (Teleport to body, backdrop, modal
  card). Body has three fields:
    1. Element type select (rectangle / ellipse / text / image /
       frame / group) — required.
    2. Element name input — required.
    3. Initial HTML textarea — optional. Defaults to a stub HTML
       body per type (a 1×1 colored rectangle for shape types, an
       empty <p> for text, etc.).

  Resets all state on every `props.show` flip from false to true
  (mirrors AddKanbanDialog's UX). On submit, emits `create` with
  the new element's body; the parent calls the store action and
  closes the dialog.

  Public API:
    props:
      show     boolean               dialog visibility
      pageId   string                active page id (for tests)
      readonly boolean               when true, submit is disabled
    emits:
      create   [body: { name, type, html }]
      close    []
-->
<script setup lang="ts">
import { ref, nextTick, onMounted, onUpdated } from 'vue'
import type { DesignElementType } from '../../api'

const props = withDefaults(
  defineProps<{
    show: boolean
    pageId: string
    readonly?: boolean
  }>(),
  {
    readonly: false,
  },
)

const emit = defineEmits<{
  create: [body: { name: string; type: DesignElementType; html: string }]
  close: []
}>()

// ─── Form state ────────────────────────────────────────────────────────

const ELEMENT_TYPES: { value: DesignElementType; label: string }[] = [
  { value: 'rectangle', label: 'Rectangle' },
  { value: 'ellipse', label: 'Ellipse' },
  { value: 'text', label: 'Text' },
  { value: 'image', label: 'Image' },
  { value: 'frame', label: 'Frame' },
  { value: 'group', label: 'Group' },
]

const name = ref('')
const elementType = ref<DesignElementType>('rectangle')
const initialHtml = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

// Default HTML body per type — provides a starting point the user can
// edit further in the PropertiesPanel's Monaco editor.
const defaultHtmlFor = (t: DesignElementType): string => {
  switch (t) {
    case 'rectangle':
      return '<div style="width:100%;height:100%;background:#7c3aed;"></div>'
    case 'ellipse':
      return '<div style="width:100%;height:100%;background:#22c55e;border-radius:50%;"></div>'
    case 'text':
      return '<p style="margin:0;padding:8px;font-family:sans-serif;font-size:14px;color:#fff;">Text</p>'
    case 'image':
      return '<img src="https://placehold.co/600x400" alt="placeholder" style="width:100%;height:100%;object-fit:contain;" />'
    case 'frame':
      return '<div style="width:100%;height:100%;border:2px dashed #8992a7;"></div>'
    case 'group':
      return '<div style="width:100%;height:100%;"></div>'
    default:
      return '<div style="width:100%;height:100%;"></div>'
  }
}

// ─── Handlers ──────────────────────────────────────────────────────────

const handleCreate = (): void => {
  const trimmedName = name.value.trim()
  if (!trimmedName) return
  // If the user didn't edit the HTML textarea, use the type-default
  // body so the new element has SOME content (the canvas preview
  // shows the rectangle / image / text instead of empty).
  const html = initialHtml.value.trim() || defaultHtmlFor(elementType.value)
  emit('create', {
    name: trimmedName,
    type: elementType.value,
    html,
  })
  handleClose()
}

const handleClose = (): void => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent): void => {
  if (event.key === 'Escape') {
    handleClose()
  }
}

// ─── Lifecycle ───────────────────────────────────────────────────────── Reset all state when the
// dialog opens. We deliberately do NOT preserve any field across open/close — matches
// AddKanbanDialog's UX and avoids surprising the user with stale data.
const handleOpen = async () => {
  name.value = ''
  elementType.value = 'rectangle'
  initialHtml.value = ''
  await nextTick()
  nameInput.value?.focus()
}

// Auto-fill the HTML textarea when the type is picked (only if the user
// hasn't typed anything yet — we don't want to clobber their draft).
const onTypeSelect = (event: Event) => {
  const t = (event.target as HTMLSelectElement).value as DesignElementType
  elementType.value = t
  if (!initialHtml.value.trim()) {
    initialHtml.value = defaultHtmlFor(t)
  }
}

// Open-reset without a watcher: seed on mount (initial show=true) and on closed->open updates. A
// Transition before-enter hook cannot do this — it never fires on initial mount (no `appear`) and
// VTU stubs Transition, so specs that mount then setProps(show=true) would see empty fields.
const wasShown = ref(props.show)
onMounted(() => {
  if (props.show) void handleOpen()
})
onUpdated(() => {
  if (props.show && !wasShown.value) void handleOpen()
  wasShown.value = props.show
})
</script>

<template>
  <Teleport to="body">
    <Transition name="add-design-element-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-design-element-title"
        data-testid="add-design-element-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6)"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: 80vh;
          "
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              id="add-design-element-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <span aria-hidden="true">◇</span>
              Add Design Element
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              Add a new element to this page
            </p>
          </div>

          <!-- Type -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Type
            </label>
            <select
              :value="elementType"
              :disabled="readonly"
              data-testid="add-design-element-type"
              @change="onTypeSelect"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              <option v-for="opt in ELEMENT_TYPES" :key="opt.value" :value="opt.value">
                {{ opt.label }}
              </option>
            </select>
          </div>

          <!-- Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="My rectangle"
              :disabled="readonly"
              data-testid="add-design-element-name"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keyup.enter="handleCreate"
            />
          </div>

          <!-- Initial HTML -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Initial HTML body
              <span class="ml-1 text-micro" style="color: var(--semantic-text-dim)">
                (optional — default filled by type)
              </span>
            </label>
            <textarea
              v-model="initialHtml"
              rows="4"
              :disabled="readonly"
              data-testid="add-design-element-html"
              class="w-full px-3 py-2 rounded-lg text-dense font-mono outline-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              placeholder="<div>...</div>"
            />
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              data-testid="add-design-element-cancel"
              class="px-3 py-1.5 rounded-lg text-body font-medium"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
              @click="handleClose"
            >
              Cancel
            </button>
            <button
              type="button"
              :disabled="!name.trim() || readonly"
              data-testid="add-design-element-submit"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
              @click="handleCreate"
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.add-design-element-modal-enter-active,
.add-design-element-modal-leave-active {
  transition: opacity 0.2s ease;
}
.add-design-element-modal-enter-from,
.add-design-element-modal-leave-to {
  opacity: 0;
}
.add-design-element-modal-enter-active > div:last-child,
.add-design-element-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.add-design-element-modal-enter-from > div:last-child,
.add-design-element-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
