<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue'
import type { OfficeKind } from '../../helpers/officeDocument'

const emit = defineEmits<{
  choose: [kind: 'markdown' | OfficeKind]
}>()

const open = ref(false)

const CHOICES: { kind: 'markdown' | OfficeKind; label: string; testId: string }[] = [
  { kind: 'markdown', label: 'Markdown document', testId: 'documents-new-markdown' },
  { kind: 'doc', label: 'Office document', testId: 'documents-new-doc' },
  { kind: 'sheet', label: 'Office spreadsheet', testId: 'documents-new-sheet' },
]

function close() {
  open.value = false
  document.removeEventListener('click', close)
}

function toggle() {
  if (open.value) {
    close()
    return
  }
  open.value = true
  // Registered on the next tick so the click that opened the menu does not
  // immediately close it again.
  setTimeout(() => document.addEventListener('click', close), 0)
}

function choose(kind: 'markdown' | OfficeKind) {
  close()
  emit('choose', kind)
}

onBeforeUnmount(() => document.removeEventListener('click', close))
</script>

<template>
  <div class="relative shrink-0">
    <button
      class="w-[var(--sb-hit)] h-[var(--sb-hit)] text-meta font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center"
      style="color: var(--semantic-text-dim); opacity: 0.7"
      title="New Document"
      aria-label="New Document"
      :aria-expanded="open"
      data-testid="documents-add-button"
      @click.stop="toggle"
    >
      +
    </button>
    <!-- A menu is the one surface allowed to float, so it carries the shadow
         and the raised tone; everything else in the sidebar is separated by a
         tone step alone. -->
    <div
      v-if="open"
      class="absolute right-0 top-full z-30 w-48 py-1 rounded-lg"
      style="
        background: var(--semantic-card-bg);
        border: 1px solid var(--semantic-sidebar-border);
        box-shadow: 0 8px 24px rgb(0 0 0 / 0.35);
      "
      role="menu"
      aria-label="New document"
      data-testid="documents-new-menu"
      @click.stop
    >
      <button
        v-for="choice in CHOICES"
        :key="choice.kind"
        class="w-full text-left px-3 h-[var(--sb-row)] text-dense transition-colors hover:bg-(--semantic-active-bg)"
        style="color: var(--semantic-text-muted)"
        role="menuitem"
        :data-testid="choice.testId"
        @click.stop="choose(choice.kind)"
      >
        {{ choice.label }}
      </button>
    </div>
  </div>
</template>
