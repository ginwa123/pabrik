<script setup lang="ts">
defineProps<{ items: readonly string[]; active: number }>()
const emit = defineEmits<{ pick: [name: string]; hover: [index: number] }>()
</script>

<template>
  <div
    data-testid="secret-suggestions"
    class="mt-1.5 rounded-md border overflow-hidden"
    style="background-color: var(--semantic-card-bg); border-color: var(--color-border)"
    role="listbox"
    aria-label="Workspace secrets"
  >
    <div
      class="text-micro font-mono px-3 py-1.5 border-b"
      style="color: var(--semantic-text-dim); border-color: var(--color-border)"
    >
      Workspace secrets — click to insert
    </div>
    <button
      v-for="(name, index) in items"
      :key="name"
      type="button"
      role="option"
      :aria-selected="index === active"
      data-testid="secret-suggestion"
      :data-secret-name="name"
      class="w-full flex items-center justify-between gap-3 px-3 py-1.5 text-left font-mono text-dense"
      :style="{
        color: index === active ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
        backgroundColor: index === active ? 'var(--semantic-content-bg)' : 'transparent',
      }"
      @mousedown.prevent="emit('pick', name)"
      @mouseenter="emit('hover', index)"
    >
      <span class="truncate">{{ name }}</span>
    </button>
  </div>
</template>
