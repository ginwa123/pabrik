<script setup lang="ts">
/** AppearanceSection — the user-scope Settings section that switches the theme. The list comes from
 * the registry (`src/theme/themes.ts`), so a new theme appears here without editing this file. */
import UiIcon from '../ui/UiIcon.vue'
import { useThemeStore } from '../../stores/theme'

const themeStore = useThemeStore()

const cardStyle = (active: boolean): Record<string, string> => ({
  backgroundColor: 'var(--semantic-card-bg)',
  borderColor: active ? 'var(--semantic-accent)' : 'var(--color-border)',
})
</script>

<template>
  <div class="space-y-6" data-testid="appearance-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Appearance</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        How this browser draws the app. A theme applies as soon as you pick it, and this browser
        remembers the choice.
      </p>
    </div>

    <div
      class="rounded-lg p-5 space-y-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="palette" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Theme</h3>
      </div>

      <div
        role="radiogroup"
        aria-label="Theme"
        class="grid gap-3 sm:grid-cols-2"
        data-testid="theme-options"
      >
        <label
          v-for="option in themeStore.options"
          :key="option.id"
          class="flex items-start gap-3 rounded-lg p-3 cursor-pointer transition-colors duration-150"
          :style="cardStyle(themeStore.theme === option.id)"
          :data-testid="`theme-option-${option.id}`"
          :data-active="themeStore.theme === option.id ? 'true' : 'false'"
        >
          <input
            type="radio"
            name="pabrik-theme"
            :value="option.id"
            :checked="themeStore.theme === option.id"
            class="mt-1 w-4 h-4 cursor-pointer"
            style="accent-color: var(--color-violet)"
            :data-testid="`theme-radio-${option.id}`"
            @change="themeStore.setTheme(option.id)"
          />
          <span class="flex-1 min-w-0">
            <span class="block text-body font-medium" style="color: var(--semantic-text)">
              {{ option.label }}
            </span>
            <span class="block text-dense mt-0.5" style="color: var(--semantic-text-muted)">
              {{ option.description }}
            </span>
            <span class="flex items-center gap-1 mt-2" aria-hidden="true">
              <span
                class="w-5 h-5 rounded-sm"
                :style="{ backgroundColor: option.swatch.bg, border: `1px solid ${option.swatch.accent}` }"
              ></span>
              <span class="w-5 h-5 rounded-sm" :style="{ backgroundColor: option.swatch.card }"></span>
              <span class="w-5 h-5 rounded-sm" :style="{ backgroundColor: option.swatch.fg }"></span>
              <span class="w-5 h-5 rounded-sm" :style="{ backgroundColor: option.swatch.accent }"></span>
            </span>
          </span>
        </label>
      </div>

      <p class="text-dense" style="color: var(--semantic-text-dim)">
        Applies to this browser only, and never follows the operating system's appearance.
      </p>
    </div>
  </div>
</template>
