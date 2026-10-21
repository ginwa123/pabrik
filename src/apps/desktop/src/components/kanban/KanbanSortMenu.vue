<!--
  KanbanSortMenu — the 7-item sort menu used inside the column's
  existing "⋮" menu (Sort tasks…) and (in future) the kanban
  header.

  Two render modes via the `showTrigger` prop:
    - showTrigger=true  (default) — renders a `<button>` trigger +
      click-toggled dropdown `<ul>`. Used as a standalone dropdown.
    - showTrigger=false — renders only the `<ul>` items, no button,
      no click-outside / Esc handlers. Used inside the column's
      centered sort modal (the modal provides its own backdrop +
      Esc close).

  7 sort modes:
    - position asc (Manual / default — preserves drag-to-reorder)
    - created_at asc / desc (Created oldest / newest first)
    - updated_at asc / desc (Updated oldest / newest first)
    - name asc / desc (Name A→Z / Z→A)

  Public API:
    props:
      sortBy      'position' | 'created_at' | 'updated_at' | 'name'
      direction   'asc' | 'desc'
      showTrigger boolean (default true)
    emits:
      update:sortBy    [value]
      update:direction [value]

-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'

type SortField = 'position' | 'created_at' | 'updated_at' | 'name'
type SortDirection = 'asc' | 'desc'

interface MenuItem {
  id: string
  label: string
  sortBy: SortField
  direction: SortDirection
}

const MENU_ITEMS: MenuItem[] = [
  { id: 'position', label: 'Manual', sortBy: 'position', direction: 'asc' },
  { id: 'created-desc', label: 'Created (newest)', sortBy: 'created_at', direction: 'desc' },
  { id: 'created-asc', label: 'Created (oldest)', sortBy: 'created_at', direction: 'asc' },
  { id: 'updated-desc', label: 'Updated (newest)', sortBy: 'updated_at', direction: 'desc' },
  { id: 'updated-asc', label: 'Updated (oldest)', sortBy: 'updated_at', direction: 'asc' },
  { id: 'name-asc', label: 'Name (A→Z)', sortBy: 'name', direction: 'asc' },
  { id: 'name-desc', label: 'Name (Z→A)', sortBy: 'name', direction: 'desc' },
]

const props = withDefaults(defineProps<{
  sortBy?: SortField
  direction?: SortDirection
  showTrigger?: boolean
}>(), {
  sortBy: 'position',
  direction: 'asc',
  showTrigger: true,
})

const emit = defineEmits<{
  'update:sortBy': [value: SortField]
  'update:direction': [value: SortDirection]
}>()

const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)

const toggleMenu = () => {
  menuOpen.value = !menuOpen.value
}

const closeMenu = () => {
  menuOpen.value = false
}

const isActive = (item: MenuItem) =>
  props.sortBy === item.sortBy && props.direction === item.direction

const handleSelect = (item: MenuItem) => {
  emit('update:sortBy', item.sortBy)
  emit('update:direction', item.direction)
  closeMenu()
}

const handleDocumentClick = (event: MouseEvent) => {
  if (!menuOpen.value) return
  const target = event.target as Node | null
  if (menuRef.value && target && !menuRef.value.contains(target)) {
    closeMenu()
  }
}

const handleKeyDown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && menuOpen.value) {
    event.preventDefault()
    closeMenu()
  }
}

// Click-outside + Esc handlers are only needed when the trigger
// flow is active. showTrigger=false skips both — the modal wrapper
// owns its own backdrop + Esc close.
onMounted(() => {
  if (!props.showTrigger) return
  document.addEventListener('click', handleDocumentClick)
  document.addEventListener('keydown', handleKeyDown)
})

onUnmounted(() => {
  if (!props.showTrigger) return
  document.removeEventListener('click', handleDocumentClick)
  document.removeEventListener('keydown', handleKeyDown)
})

// Trigger label: shows the current sort mode so the user can see
// the active sort at a glance without opening the menu.
const triggerLabel = computed(() => {
  const item = MENU_ITEMS.find((m) => isActive(m))
  return item ? item.label : 'Manual'
})
</script>

<template>
  <div ref="menuRef" class="relative shrink-0">
    <button
      v-if="showTrigger"
      type="button"
      class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity flex items-center gap-1"
      style="
        background-color: var(--semantic-sidebar-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text-muted);
      "
      data-testid="kanban-sort-menu-trigger"
      :aria-expanded="menuOpen"
      aria-haspopup="menu"
      @click.stop="toggleMenu"
    >
      <span aria-hidden="true">⇅</span>
      <span class="ml-1">Sort: {{ triggerLabel }}</span>
    </button>
    <ul
      v-if="showTrigger ? menuOpen : true"
      :class="showTrigger
        ? 'absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-10 min-w-[200px]'
        : 'py-1 min-w-[200px] relative'"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
      "
      data-testid="kanban-sort-menu"
      :role="showTrigger ? 'menu' : 'listbox'"
    >
      <li v-for="item in MENU_ITEMS" :key="item.id" role="none">
        <button
          type="button"
          :role="showTrigger ? 'menuitem' : 'option'"
          :aria-current="isActive(item) ? 'true' : undefined"
          :data-testid="`kanban-sort-menu-${item.id}`"
          class="w-full px-3 py-2 text-left text-body hover:opacity-80"
          :style="
            isActive(item)
              ? 'color: var(--color-violet); font-weight: 500;'
              : 'color: var(--semantic-text);'
          "
          @click="handleSelect(item)"
        >
          <span>{{ item.label }}</span>
          <span
            v-if="isActive(item)"
            aria-hidden="true"
            class="ml-1"
            style="color: var(--color-violet);"
          >✓</span>
        </button>
      </li>
    </ul>
  </div>
</template>
