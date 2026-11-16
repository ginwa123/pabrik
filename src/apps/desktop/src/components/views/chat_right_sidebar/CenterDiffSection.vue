<script setup lang="ts">
import { onMounted, onUnmounted, onUpdated, ref } from 'vue'
import SidebarDiffView from './SidebarDiffView.vue'
import type { DiffCommentSavePayload } from './DiffCommentBox.vue'
import type { ParsedDiffLine } from './parseUnifiedDiff'

/** One lazily-mounted file section of the stacked center diff. */
const props = defineProps<{
  sectionId: string
  path: string
  lines: ParsedDiffLine[]
  added: number
  removed: number
  staged?: boolean
  error?: string | null
  cwd: string
  /** Collapsed = header only. */
  collapsed?: boolean
  mode?: 'unified' | 'split'
  wholeFile?: boolean
  untracked?: boolean
}>()

const emit = defineEmits<{
  open: [payload: { path: string; line?: number }]
  retry: []
  'toggle-collapse': []
  'toggle-whole-file': []
  'submit-review': [message: string]
  'comment-saved': [payload: DiffCommentSavePayload]
}>()

const isMounted = ref(false)
const rootEl = ref<HTMLElement | null>(null)
let observer: IntersectionObserver | null = null

onMounted(() => {
  const el = rootEl.value
  if (!el || typeof IntersectionObserver === 'undefined') {
    // No observer (jsdom/tests) — mount immediately.
    isMounted.value = true
    return
  }
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          isMounted.value = true
          observer?.disconnect()
          observer = null
          break
        }
      }
    },
    { rootMargin: '400px 0px' },
  )
  observer.observe(el)
})

/** Expanding a section must mount its body NOW. */
let prevCollapsed = props.collapsed
onUpdated(() => {
  const now = props.collapsed
  if (prevCollapsed === true && now === false) isMounted.value = true
  prevCollapsed = now
})

onUnmounted(() => {
  observer?.disconnect()
  observer = null
})
</script>

<template>
  <section
    ref="rootEl"
    :id="sectionId"
    :data-path="props.path"
    data-testid="center-diff-section"
    style="content-visibility: auto; contain-intrinsic-size: auto 400px"
  >
    <div v-if="!isMounted" data-testid="center-diff-placeholder" style="min-height: 200px" />
    <SidebarDiffView
      v-else
      :path="path"
      :lines="lines"
      :added="added"
      :removed="removed"
      :staged="staged"
      :loading="false"
      :error="error ?? null"
      :cwd="cwd"
      :show-back="false"
      :mode="mode"
      :collapsed="collapsed"
      :whole-file="wholeFile"
      :untracked="untracked"
      @open="(payload) => emit('open', payload)"
      @retry="() => emit('retry')"
      @toggle-collapse="() => emit('toggle-collapse')"
      @toggle-whole-file="() => emit('toggle-whole-file')"
      @submit-review="(message) => emit('submit-review', message)"
      @comment-saved="(payload) => emit('comment-saved', payload)"
    />
  </section>
</template>
