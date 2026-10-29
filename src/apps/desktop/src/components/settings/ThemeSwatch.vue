<script setup lang="ts">
import type { ThemeDefinition } from '../../theme/themes'

/** The four-colour preview tile for a theme. Literal colours, not tokens: the tile can show a theme
 * that is not the applied one, so it cannot read the live cascade. */
const props = withDefaults(defineProps<{ swatch: ThemeDefinition['swatch']; large?: boolean }>(), {
  large: false,
})
</script>

<template>
  <span class="flex items-center gap-0.5 shrink-0" aria-hidden="true">
    <span
      class="rounded-sm"
      :class="props.large ? 'w-5 h-5' : 'w-4 h-4'"
      :style="{ backgroundColor: props.swatch.bg, border: `1px solid ${props.swatch.accent}` }"
    ></span>
    <span
      class="rounded-sm"
      :class="props.large ? 'w-5 h-5' : 'w-4 h-4'"
      :style="{ backgroundColor: props.swatch.card }"
    ></span>
    <span
      class="rounded-sm"
      :class="props.large ? 'w-5 h-5' : 'w-4 h-4'"
      :style="{ backgroundColor: props.swatch.fg }"
    ></span>
    <span
      class="rounded-sm"
      :class="props.large ? 'w-5 h-5' : 'w-4 h-4'"
      :style="{ backgroundColor: props.swatch.accent }"
    ></span>
  </span>
</template>
