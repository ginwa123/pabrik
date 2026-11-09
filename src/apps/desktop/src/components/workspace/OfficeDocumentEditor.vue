<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { parseOfficeBody, type OfficeKind } from '../../helpers/officeDocument'
import { mountOfficeEditor, type OfficeEditor } from '../../helpers/univerBootstrap'

const props = defineProps<{
  /** The stored body: the office envelope, or empty for a blank document. */
  body: string
}>()

const emit = defineEmits<{
  /** The user changed the document. The view marks itself dirty and enables Save. */
  change: []
}>()

const surface = ref<HTMLElement | null>(null)
const failure = ref<string | null>(null)
const loading = ref(true)

let editor: OfficeEditor | null = null
/** The kind this editor actually mounted. The view stores the snapshot under
 *  this kind, so the envelope can never claim a kind the snapshot is not. */
let mountedKind: OfficeKind | null = null
let unsubscribe: (() => void) | null = null
/** Set when the component unmounts before the async mount resolves, so the
 *  editor that arrives late is disposed instead of leaking a live Univer. */
let unmounted = false

onMounted(async () => {
  const parsed = parseOfficeBody(props.body)
  if (!parsed) {
    failure.value = 'This office document’s body is not readable.'
    loading.value = false
    return
  }
  const target = surface.value
  if (!target) {
    failure.value = 'The editor could not be mounted.'
    loading.value = false
    return
  }

  // The failure is rendered from `failure`, so it reaches the user; there is no
  // Effect seam here because the SDK is a plain promise.
  /* eslint-disable local/no-try-catch -- the reason is rendered, not swallowed */
  try {
    const mounted = await mountOfficeEditor(target, parsed.kind, parsed.snapshot)
    if (unmounted) {
      mounted.dispose()
      return
    }
    editor = mounted
    mountedKind = parsed.kind
    unsubscribe = mounted.onEdit(() => emit('change'))
  } catch (error) {
    failure.value = error instanceof Error ? error.message : String(error)
  } finally {
    loading.value = false
  }
  /* eslint-enable local/no-try-catch */
})

onBeforeUnmount(() => {
  unmounted = true
  unsubscribe?.()
  unsubscribe = null
  editor?.dispose()
  editor = null
})

/** The current content as a Univer snapshot, or null before the editor is ready. */
function snapshot(): unknown {
  return editor?.snapshot() ?? null
}

/** The kind this editor mounted, or null before it is ready. */
function kind(): OfficeKind | null {
  return mountedKind
}

defineExpose({ snapshot, kind })
</script>

<template>
  <div class="flex-1 min-h-0 relative" data-testid="office-document-editor">
    <div
      v-if="failure"
      class="p-6 text-body"
      style="color: var(--semantic-error)"
      data-testid="office-document-editor-error"
    >
      {{ failure }}
    </div>
    <div v-else ref="surface" class="absolute inset-0" data-testid="office-document-editor-surface" />
    <p
      v-if="loading && !failure"
      class="absolute inset-0 flex items-center justify-center text-body pointer-events-none"
      style="color: var(--semantic-text-dim)"
      data-testid="office-document-editor-loading"
    >
      Loading editor…
    </p>
  </div>
</template>
