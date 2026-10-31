<script setup lang="ts">
// The rotate modal, teleported to <body> so it is not clipped by the settings
// pane. The typed value lives here and is dropped as soon as it is emitted: the
// parent passes a NEW key per target, so a remount is what clears the field.
import { ref } from 'vue'

const props = defineProps<{
  /** The secret being rotated, or null when the dialog is closed. */
  name: string | null
}>()

const emit = defineEmits<{
  save: [value: string]
  close: []
}>()

const value = ref('')

function handleSave(): void {
  if (value.value.length === 0) return
  emit('save', value.value)
  value.value = ''
}
</script>

<template>
  <Teleport to="body">
    <div
      v-if="props.name"
      data-testid="rotate-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center"
      @click.self="emit('close')"
    >
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="emit('close')" />
      <div
        class="relative w-full max-w-sm mx-4 rounded-xl shadow-2xl px-5 py-5 space-y-3"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">
          Rotate {{ props.name }}
        </h3>
        <p class="text-dense leading-relaxed" style="color: var(--semantic-text-muted)">
          Paste the new credential. The current one is overwritten and is not shown to you again.
        </p>
        <input
          v-model="value"
          data-testid="rotate-value-input"
          type="password"
          autocomplete="new-password"
          spellcheck="false"
          class="w-full px-3 h-8 rounded-md text-dense font-mono"
          style="background-color: var(--semantic-bg); color: var(--semantic-text); border: 1px solid var(--color-border)"
        />
        <div class="flex justify-end gap-2 pt-1">
          <button
            type="button"
            data-testid="rotate-cancel-btn"
            class="px-3 h-8 rounded-md text-dense border transition-colors duration-150"
            style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent"
            @click="emit('close')"
          >
            Cancel
          </button>
          <button
            type="button"
            data-testid="rotate-save-btn"
            :disabled="value.length === 0"
            class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150 disabled:opacity-50"
            style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent"
            @click="handleSave"
          >
            Save
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
