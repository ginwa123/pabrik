<script setup lang="ts">
defineProps<{
  dirty: boolean
  unsavedCount: number
  saving: boolean
}>()

const emit = defineEmits<{
  reset: []
  save: []
}>()
</script>

<template>
  <Transition
    enter-active-class="transition-all duration-180 ease-out"
    enter-from-class="-translate-y-2 opacity-0"
    enter-to-class="translate-y-0 opacity-100"
    leave-active-class="transition-all duration-150 ease-in"
    leave-from-class="translate-y-0 opacity-100"
    leave-to-class="-translate-y-2 opacity-0"
  >
    <div
      v-if="dirty"
      data-testid="save-bar"
      class="sticky top-0 left-0 right-0 flex items-center justify-between gap-4 px-4 h-12 border-b backdrop-blur-sm"
      style="background-color: rgba(24, 22, 22, 0.92); border-color: var(--color-border);"
    >
      <div class="flex items-center gap-2 text-dense font-mono" style="color: var(--semantic-text-muted);">
        <span
          class="w-1.5 h-1.5 rounded-full"
          style="background-color: var(--color-yellow);"
          aria-hidden="true"
        />
        <span data-testid="unsaved-count">{{ unsavedCount }} unsaved change{{ unsavedCount === 1 ? '' : 's' }}</span>
      </div>
      <div class="flex items-center gap-2">
        <button
          type="button"
          data-testid="reset-btn"
          :disabled="saving"
          @click="emit('reset')"
          class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
          style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
        >Reset</button>
        <button
          type="button"
          data-testid="save-btn"
          :disabled="saving"
          @click="emit('save')"
          class="px-4 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
          style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
        >{{ saving ? 'Saving…' : 'Save changes' }}</button>
      </div>
    </div>
  </Transition>
</template>
