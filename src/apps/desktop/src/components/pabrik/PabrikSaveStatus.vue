<script setup lang="ts">
/** The autosave indicator. Settings save themselves, so this strip has no controls — its whole job
 * is telling the user whether the last change reached the server. */
import { computed } from 'vue'

const props = defineProps<{ state: 'idle' | 'saving' | 'saved' | 'error'; message: string }>()

const label = computed<string>(() => {
  if (props.state === 'saving') return 'Saving…'
  if (props.state === 'saved') return 'Saved'
  if (props.state === 'error') return `Couldn't save — ${props.message}`
  return ''
})

const dotColor = computed<string>(() => {
  if (props.state === 'error') return 'var(--color-red)'
  if (props.state === 'saved') return 'var(--color-green)'
  return 'var(--color-yellow)'
})
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
      v-if="state !== 'idle'"
      data-testid="save-status"
      role="status"
      aria-live="polite"
      class="sticky top-0 left-0 right-0 flex items-center gap-2 px-4 h-9 border-b backdrop-blur-sm"
      style="background-color: rgba(24, 22, 22, 0.92); border-color: var(--color-border)"
    >
      <span
        class="w-1.5 h-1.5 rounded-full"
        :style="{ backgroundColor: dotColor }"
        aria-hidden="true"
      />
      <span
        data-testid="save-status-text"
        class="text-dense font-mono"
        :style="{
          color: state === 'error' ? 'var(--color-red)' : 'var(--semantic-text-muted)',
        }"
        >{{ label }}</span
      >
    </div>
  </Transition>
</template>
