<!--
  DesignPageRow — single design page row in the workspace sidebar tree.

  Rendered as a nested child of an expanded `design` workspace item
  (parent: <WorkspaceItem>). One row per page; click selects the page
  + activates the design item. On hover, two action buttons appear:

    1. ⋮ — three-dot menu (kanban-column parity). Offers "Rename"
       (emits `renamePage`) and "Delete" (emits `deletePage`). The
       menu is the canonical surface for page-level actions going
       forward; future actions (duplicate, lock, etc.) slot in here.

    2. × — direct delete button (kept for one-click deletion parity
       with the pre-menu behaviour, since "Delete" via ⋮ → click is
       one step more). Both paths flow through the same `deletePage`
       emit (the parent's confirm dialog gates both).

  Plan: docs/superpowers/plans/2026-08-06-design-pages-in-workspace-tree.md
        (initial row)
        docs/superpowers/plans/2026-08-06-rename-design-pages.md
        (⋮ menu added 2026-08-06 — design page rename menu)

  Why this component instead of reusing WorkspaceItemTaskRow?
  WorkspaceItemTaskRow is a 262-line component built around the
  task/routine/pin/drop-indicator mental model. Pages don't have any
  of that — they're just a name + a delete + a rename. Reusing the
  task row would pull in useTaskActions and 9 conditional template
  branches for state that doesn't exist. A 80-line dedicated
  component is cheaper to read AND to test.

  Why a <div role="button"> instead of a <button> for the row?
  The row contains nested interactive elements (⋮ menu trigger, ×
  delete button). HTML forbids nested interactive elements
  (button-inside-button), so we use a div with role="button" +
  tabindex=0 + keyboard handler (Enter/Space activates selectPage).
  The inner ⋮ and × stay real <button>s for proper focus/focus-ring
  + native form behaviour.

  Why a click-outside listener on the ⋮ menu?
  Same UX as the kanban-column ⋮ menu (kanban-sort-by plan,
  2026-08-06): the dropdown closes when the user clicks anywhere
  outside the menuRef container. Without it, the menu stays open
  until the user clicks an item or another ⋮ trigger.

  Public API:
    props:
      page           DesignPage    the page to render
      workspaceId    string        parent workspace id (for emits)
      itemId         string        parent design item id (for emits)
      isActivePage   boolean       true when this page is the active page
                                   (kept for backwards-compat with
                                   non-URL consumers; visual style is
                                   URL-driven via useCurrentMainView)
    emits:
      selectPage    [page: DesignPage]
      renamePage    [page: DesignPage]
      deletePage    [page: DesignPage]
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import type { DesignPage } from '../../api'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import OpenInNewTabMenu from '../shell/OpenInNewTabMenu.vue'
import { useContextMenu } from '../../composables/useContextMenu'
import { isBackgroundOpenEvent } from '../../helpers/tabTarget'

const props = defineProps<{
  page: DesignPage
  workspaceId: string
  itemId: string
  isActivePage: boolean
}>()

const emit = defineEmits<{
  selectPage: [page: DesignPage]
  renamePage: [page: DesignPage]
  deletePage: [page: DesignPage]
  openDesignPageInBackground: [page: DesignPage]
}>()

// URL-driven "what is the main content area showing?". The active
// styling is now sourced from the URL (?view=workspace&pageId=X) rather
// than the `isActivePage` prop (which is still passed by the parent for
// backwards-compat with other consumers). When the URL changes, the
// computed re-runs and the row styling updates — no watcher needed, the
// template binding is enough.
const currentMainView = useCurrentMainView()
const isCurrentMainView = computed(
  () =>
    currentMainView.value.kind === 'workspace' && currentMainView.value.pageId === props.page.id,
)

// ⋮ menu state — mirrors the kanban-column ⋮ menu pattern (kanban-sort-by plan, 2026-08-06). The
// dropdown closes when the user clicks anywhere outside the menuRef container (document mousedown
// handler attached on open, removed on close).
const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)

const toggleMenu = () => {
  menuOpen.value = !menuOpen.value
  if (menuOpen.value) {
    // Attach the document listener lazily so the menu works even when the component is mounted with
    // menuOpen=false (the default). Removed on close to avoid leaking global listeners across the
    // row list.
    document.addEventListener('mousedown', handleClickOutside)
  } else {
    document.removeEventListener('mousedown', handleClickOutside)
  }
}

const closeMenu = () => {
  if (menuOpen.value) {
    menuOpen.value = false
    document.removeEventListener('mousedown', handleClickOutside)
  }
}

const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as Node | null
  if (!target) return
  if (menuRef.value && !menuRef.value.contains(target)) {
    closeMenu()
  }
}

const handleSelect = (): void => {
  emit('selectPage', props.page)
}

// Right-click "Open in new tab" on a design page row. The row only
// knows the page — WorkspaceItem fills in workspaceId/itemId so
// Sidebar can build the page URL without touching store state.
const { menuPos, openAt, close: closePageMenu } = useContextMenu()

const onPageRowContextMenu = (event: MouseEvent): void => {
  openAt(event)
}

const onPageRowAuxClick = (event: MouseEvent): void => {
  if (event.button !== 1) return
  event.preventDefault()
  emit('openDesignPageInBackground', props.page)
}

const onPageRowClick = (event: MouseEvent): void => {
  if (isBackgroundOpenEvent(event)) {
    emit('openDesignPageInBackground', props.page)
    return
  }
  handleSelect()
}

const openPageMenuInBackground = (): void => {
  closePageMenu()
  emit('openDesignPageInBackground', props.page)
}

// "Rename" item in the ⋮ menu. Closes the menu and emits the
// renamePage event (the parent — WorkspaceItem → Sidebar — owns the
// rename modal lifecycle).
const handleMenuRename = (event: Event): void => {
  event.stopPropagation()
  closeMenu()
  emit('renamePage', props.page)
}

// "Delete" item in the ⋮ menu. Closes the menu first (else the
// menu's mousedown listener would race with the delete's confirm
// dialog), then emits deletePage.
const handleMenuDelete = (event: Event): void => {
  event.stopPropagation()
  closeMenu()
  emit('deletePage', props.page)
}

// Direct × delete button on hover. Same emit as the menu path.
const handleDelete = (event: Event): void => {
  // Stop propagation so the click doesn't ALSO fire `selectPage`
  // (the outer row handler runs on click — clicking × would
  // otherwise navigate to this page right before deleting it).
  event.stopPropagation()
  emit('deletePage', props.page)
}

const handleKeydown = (event: KeyboardEvent): void => {
  // Enter / Space activate the row (matches the <button> keyboard
  // contract without using a real <button> — see the header comment).
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    handleSelect()
  }
}
</script>

<template>
  <div
    role="button"
    tabindex="0"
    class="flex items-center gap-2 px-3 py-1 rounded text-dense group/page cursor-pointer transition-all duration-200 w-full text-left"
    :style="{
      color: isCurrentMainView ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: isCurrentMainView ? 'var(--semantic-active-bg)' : 'transparent',
      boxShadow: isCurrentMainView ? 'inset 2px 0 0 0 var(--color-violet)' : 'none',
    }"
    :data-testid="`design-page-row-${page.id}`"
    :data-active-page="isCurrentMainView ? 'true' : undefined"
    :data-page-id="page.id"
    @click="onPageRowClick"
    @auxclick="onPageRowAuxClick"
    @contextmenu.prevent="onPageRowContextMenu"
    @keydown="handleKeydown"
  >
    <!--
      Subtle 6×6 dot in the same slot as the kanban task's processing
      spinner. For pages, it's a static visual marker (NOT a live
      spinner) — the page is just a child of the design item, not a
      running worker. Same lane as the task row so the visual rhythm
      matches.
    -->
    <span
      class="w-1.5 h-1.5 rounded-full shrink-0"
      style="background-color: currentColor; opacity: 0.5"
      aria-hidden="true"
    />
    <span class="flex-1 truncate">{{ page.name }}</span>
    <!--
      ⋮ menu trigger — hover-revealed via the `group/page` modifier.
      Sits in the same hover-revealed slot as the × delete button.
      The menu's dropdown anchors to this element (position
      absolute, top-full, right-0).

      Click handler uses `@click.stop` so the click doesn't ALSO fire
      the outer row's `selectPage` handler — without stopPropagation
      the user would navigate to the page right before opening the
      menu.
    -->
    <div ref="menuRef" class="relative shrink-0">
      <button
        type="button"
        class="w-6 h-6 flex items-center justify-center rounded opacity-60 hover:opacity-100 transition-opacity hover:opacity-80"
        style="color: var(--semantic-text-dim)"
        :data-testid="`design-page-menu-${page.id}`"
        aria-label="Design page actions"
        @click.stop="toggleMenu"
        @keydown.stop
      >
        <span class="text-lead leading-none">⋮</span>
      </button>
      <!--
        Dropdown — same width + style as the kanban-column menu
        (kanban-sort-by plan, 2026-08-06) for visual consistency.
      -->
      <ul
        v-if="menuOpen"
        class="absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-10 min-w-[120px]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        :data-testid="`design-page-menu-list-${page.id}`"
      >
        <li>
          <button
            type="button"
            class="w-full px-3 py-2 text-left text-body hover:opacity-80"
            style="color: var(--semantic-text)"
            :data-testid="`design-page-menu-rename-${page.id}`"
            @click="handleMenuRename"
          >
            Rename
          </button>
        </li>
        <li>
          <button
            type="button"
            class="w-full px-3 py-2 text-left text-body hover:opacity-80"
            style="color: #ef4444"
            :data-testid="`design-page-menu-delete-${page.id}`"
            @click="handleMenuDelete"
          >
            Delete
          </button>
        </li>
      </ul>
    </div>
    <!--
      × delete button (hover-revealed via `group/page`). Kept as a
      direct second affordance alongside the ⋮ menu so one-click
      deletion still works (the menu requires two clicks). Both paths
      share the same `deletePage` emit.

      Real <button> (not role="button") so focus / focus-ring /
      native form behaviour work as expected.
    -->
    <button
      type="button"
      class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-60 hover:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-red-400"
      style="color: var(--semantic-text-dim)"
      title="Delete page"
      aria-label="Delete page"
      :data-testid="`design-page-delete-${page.id}`"
      @click="handleDelete"
    >
      ×
    </button>
    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      open-label="Open in new tab"
      @open="openPageMenuInBackground"
    />
  </div>
</template>
