<script setup lang="ts">
import { computed, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import { parentPath, parseBreadcrumb } from './pathUtils'

const props = defineProps<{
  currentPath: string
  isPathEditing: boolean
  pathDraft: string
}>()

const emit = defineEmits<{
  navigate: [path: string]
  'update:pathDraft': [value: string]
  beginEdit: []
  commit: []
  cancel: []
}>()

const breadcrumb = computed(() => parseBreadcrumb(props.currentPath))
const draft = computed({
  get: () => props.pathDraft,
  set: (value: string) => emit('update:pathDraft', value),
})

const pathInput = ref<HTMLInputElement | null>(null)
defineExpose({
  focusInput: () => {
    const el = pathInput.value
    if (!el) return
    el.focus()
    el.select()
  },
})
</script>

<template>
  <div
    class="px-5 py-2 flex items-center gap-1 shrink-0 text-dense"
    style="
      border-bottom: 1px solid var(--color-border);
      color: var(--semantic-text-muted);
    "
  >
    <template v-if="!isPathEditing">
      <button
        @click="emit('navigate', '/')"
        data-testid="file-picker-root"
        class="px-1.5 py-0.5 rounded hover:opacity-80"
        style="color: var(--semantic-text-muted)"
        title="Root"
      >
        /
      </button>
      <template v-for="(seg, idx) in breadcrumb" :key="seg.path">
        <span aria-hidden="true" style="color: var(--semantic-text-dim)">›</span>
        <button
          @click="emit('navigate', seg.path)"
          :data-testid="`file-picker-crumb-${idx}`"
          class="px-1.5 py-0.5 rounded hover:opacity-80 font-mono truncate max-w-[180px]"
          :style="
            idx === breadcrumb.length - 1
              ? { color: 'var(--semantic-text)', fontWeight: '600' }
              : { color: 'var(--semantic-text-muted)' }
          "
        >
          {{ seg.name }}
        </button>
      </template>
    </template>

    <input
      v-else
      ref="pathInput"
      v-model="draft"
      type="text"
      spellcheck="false"
      autocomplete="off"
      autocorrect="off"
      autocapitalize="off"
      data-testid="file-picker-path-input"
      :aria-label="`Type a path to navigate. Currently at ${currentPath}.`"
      class="flex-1 min-w-0 px-2 py-0.5 text-dense font-mono rounded outline-none transition-all"
      style="
        background-color: var(--semantic-sidebar-bg);
        border: 1px solid var(--color-violet);
        color: var(--semantic-text);
      "
      @keydown.enter.prevent="emit('commit')"
      @keydown.esc.prevent="emit('cancel')"
      @blur="emit('commit')"
    />

    <span class="flex-1" v-if="!isPathEditing" />

    <button
      v-if="!isPathEditing"
      @click="emit('beginEdit')"
      data-testid="file-picker-path-edit"
      class="px-2 py-0.5 rounded text-dense transition-all hover:opacity-80"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      title="Type a path (Enter to go, Esc to cancel)"
      aria-label="Edit path"
    >
      <UiIcon name="pencil" /> Go
    </button>

    <button
      v-if="currentPath !== '/' && currentPath !== '' && !isPathEditing"
      @click="emit('navigate', parentPath(currentPath))"
      data-testid="file-picker-up"
      class="px-2 py-0.5 rounded text-dense transition-all hover:opacity-80"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      title="Go up one level"
    >
      ⬆ Up
    </button>
  </div>
</template>

<style scoped>
/* Search focus ring */
input:focus {
  box-shadow: 0 0 0 2px rgba(137, 146, 167, 0.2);
}
</style>
