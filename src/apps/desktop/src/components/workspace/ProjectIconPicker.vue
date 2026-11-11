<script setup lang="ts">
/** The `Change icon…` flyout: a searchable grid of every glyph `UiIcon` can
 * draw, plus `Reset to default`. The parent mounts it with `v-if`, so opening
 * it is a fresh mount — no stale search text, no stale `current`. */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'
import { PROJECT_ICON_NAMES } from '../../stores/projectIcons'

const props = defineProps<{
  /** Viewport x of the anchor (the context menu's right edge). */
  x: number
  /** Viewport y of the anchor (the context menu's top edge). */
  y: number
  /** The glyph the row draws right now, override or fallback. */
  current: UiIconName
  /** Shown in the header so it is obvious which project is being changed. */
  workspaceName: string
}>()

const emit = defineEmits<{
  pick: [name: UiIconName]
  reset: []
  close: []
}>()

const PANEL_WIDTH = 268
const PANEL_HEIGHT = 300
const VIEWPORT_MARGIN = 8

const panel = ref<HTMLElement | null>(null)
const search = ref('')
const searchInput = ref<HTMLInputElement | null>(null)

/** Flip to the left of the anchor when the panel would run off the right
 * edge, then clamp both axes so it never leaves the viewport. */
const position = computed(() => {
  const flipLeft = props.x + PANEL_WIDTH > window.innerWidth - VIEWPORT_MARGIN
  const rawX = flipLeft ? props.x - PANEL_WIDTH - 6 : props.x + 6
  const maxX = Math.max(VIEWPORT_MARGIN, window.innerWidth - PANEL_WIDTH - VIEWPORT_MARGIN)
  const maxY = Math.max(VIEWPORT_MARGIN, window.innerHeight - PANEL_HEIGHT - VIEWPORT_MARGIN)
  return {
    left: `${Math.min(Math.max(VIEWPORT_MARGIN, rawX), maxX)}px`,
    top: `${Math.min(Math.max(VIEWPORT_MARGIN, props.y), maxY)}px`,
  }
})

const matches = computed(() => {
  const query = search.value.trim().toLowerCase()
  if (!query) return PROJECT_ICON_NAMES
  return PROJECT_ICON_NAMES.filter((name) => name.includes(query))
})

const onKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') emit('close')
}

const onPointerDown = (event: MouseEvent) => {
  const target = event.target as Node | null
  if (panel.value && target && panel.value.contains(target)) return
  emit('close')
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  window.addEventListener('pointerdown', onPointerDown)
  searchInput.value?.focus()
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown)
  window.removeEventListener('pointerdown', onPointerDown)
})
</script>

<template>
  <Teleport to="body">
    <div
      ref="panel"
      data-testid="project-icon-picker"
      role="dialog"
      aria-label="Change project icon"
      class="fixed z-[60] rounded-lg"
      :style="{
        ...position,
        width: `${PANEL_WIDTH}px`,
        padding: '10px',
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        boxShadow: '0 10px 30px -10px rgba(0, 0, 0, 0.7), 0 2px 8px -2px rgba(0, 0, 0, 0.45)',
      }"
    >
      <div
        class="flex items-center gap-1.5 mb-2 text-micro uppercase tracking-[0.08em]"
        style="color: var(--semantic-text-dim)"
      >
        <span>Icon</span>
        <span
          class="ml-auto normal-case tracking-normal font-mono truncate"
          style="color: var(--semantic-text-muted)"
          data-testid="project-icon-picker-who"
          >{{ workspaceName }}</span
        >
      </div>

      <input
        ref="searchInput"
        v-model="search"
        type="search"
        placeholder="Filter icons"
        aria-label="Filter icons"
        data-testid="project-icon-picker-search"
        class="w-full h-[26px] mb-2 px-2 rounded-md text-dense outline-none"
        :style="{
          border: '1px solid var(--color-border)',
          backgroundColor: 'var(--semantic-sidebar-bg)',
          color: 'var(--semantic-text)',
        }"
      />

      <div
        v-if="matches.length > 0"
        class="grid grid-cols-6 gap-1 overflow-y-auto"
        style="max-height: 196px"
        data-testid="project-icon-picker-grid"
      >
        <button
          v-for="name in matches"
          :key="name"
          type="button"
          :title="name"
          :aria-label="name"
          :aria-pressed="name === current"
          :data-icon="name"
          class="grid place-items-center rounded-md border border-transparent cursor-pointer"
          :style="
            name === current
              ? {
                  aspectRatio: '1',
                  borderColor: 'var(--color-violet)',
                  backgroundColor: 'color-mix(in srgb, var(--color-violet) 16%, transparent)',
                  color: 'var(--color-violet)',
                }
              : { aspectRatio: '1', color: 'var(--semantic-text-muted)' }
          "
          @click="emit('pick', name)"
        >
          <UiIcon :name="name" :size="16" />
        </button>
      </div>
      <p
        v-else
        class="py-4 text-center text-dense italic"
        style="color: var(--semantic-text-dim)"
        data-testid="project-icon-picker-empty"
      >
        No icon matches.
      </p>

      <div class="mt-2 pt-2" :style="{ borderTop: '1px solid var(--color-border)' }">
        <button
          type="button"
          data-testid="project-icon-picker-reset"
          class="w-full h-[26px] rounded-md text-dense cursor-pointer"
          :style="{
            border: '1px solid var(--color-border)',
            color: 'var(--semantic-text-muted)',
            backgroundColor: 'transparent',
          }"
          @click="emit('reset')"
        >
          Reset to default
        </button>
      </div>
    </div>
  </Teleport>
</template>
