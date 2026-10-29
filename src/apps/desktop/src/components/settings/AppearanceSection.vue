<script setup lang="ts">
/** AppearanceSection — the user-scope Settings section that switches the theme. The list comes from
 * the registry (`src/theme/themes.ts`), so a new theme appears here without editing this file; the
 * picker is a searchable dropdown because the list is meant to keep growing. */
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import ThemeSwatch from './ThemeSwatch.vue'
import { useThemeStore } from '../../stores/theme'
import type { ThemeDefinition } from '../../theme/themes'

const themeStore = useThemeStore()

const open = ref(false)
const query = ref('')
const highlighted = ref(0)
const pickerRef = ref<HTMLElement | null>(null)
const searchRef = ref<HTMLInputElement | null>(null)

const current = computed<ThemeDefinition | undefined>(() =>
  themeStore.options.find((theme) => theme.id === themeStore.theme),
)

/** Filter as you type — a `computed` over the query ref, never a watcher (`local/no-watch`). */
const matches = computed<readonly ThemeDefinition[]>(() => {
  const needle = query.value.trim().toLowerCase()
  if (!needle) return themeStore.options
  return themeStore.options.filter((theme) =>
    `${theme.label} ${theme.description} ${theme.id}`.toLowerCase().includes(needle),
  )
})

function openPicker(): void {
  query.value = ''
  highlighted.value = 0
  open.value = true
  void nextTick(() => searchRef.value?.focus())
}

function closePicker(): void {
  open.value = false
  query.value = ''
}

function togglePicker(): void {
  if (open.value) closePicker()
  else openPicker()
}

function choose(theme: ThemeDefinition | undefined): void {
  if (!theme) return
  themeStore.setTheme(theme.id)
  closePicker()
}

function moveHighlight(step: number): void {
  const count = matches.value.length
  if (count === 0) return
  highlighted.value = (highlighted.value + step + count) % count
}

function onQueryInput(event: Event): void {
  query.value = (event.target as HTMLInputElement).value
  highlighted.value = 0
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') {
    event.preventDefault()
    closePicker()
    return
  }
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveHighlight(1)
    return
  }
  if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveHighlight(-1)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    choose(matches.value[highlighted.value] ?? matches.value[0])
  }
}

function onDocumentPointerDown(event: MouseEvent): void {
  if (!open.value) return
  const target = event.target as Node | null
  if (pickerRef.value && target && !pickerRef.value.contains(target)) closePicker()
}

onMounted(() => {
  document.addEventListener('mousedown', onDocumentPointerDown)
})

onBeforeUnmount(() => {
  document.removeEventListener('mousedown', onDocumentPointerDown)
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

      <div ref="pickerRef" class="relative max-w-md">
        <button
          type="button"
          class="w-full flex items-center gap-3 px-3 py-2 rounded-md text-left transition-colors duration-150"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          data-testid="theme-picker-trigger"
          aria-haspopup="listbox"
          :aria-expanded="open"
          @click.stop="togglePicker"
        >
          <ThemeSwatch v-if="current" :swatch="current.swatch" large />
          <span class="flex-1 min-w-0">
            <span class="block text-body font-medium" data-testid="theme-picker-label">
              {{ current?.label ?? 'Choose a theme' }}
            </span>
            <span
              class="block text-dense truncate"
              style="color: var(--semantic-text-muted)"
              data-testid="theme-picker-description"
            >
              {{ current?.description ?? '' }}
            </span>
          </span>
          <UiIcon name="chevron-down" size-class="w-4 h-4" />
        </button>

        <div
          v-if="open"
          class="absolute left-0 right-0 top-full mt-1 z-30 rounded-lg p-2"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
            box-shadow: 0 8px 24px rgb(0 0 0 / 0.25);
          "
          data-testid="theme-picker"
        >
          <input
            ref="searchRef"
            type="text"
            role="combobox"
            aria-label="Search themes"
            aria-controls="theme-listbox"
            :aria-expanded="open"
            :value="query"
            placeholder="Search themes…"
            class="w-full px-2 py-1.5 rounded text-body"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            data-testid="theme-search"
            @input="onQueryInput"
            @keydown="onKeydown"
          />

          <ul
            id="theme-listbox"
            role="listbox"
            aria-label="Themes"
            class="mt-2 max-h-64 overflow-y-auto"
            data-testid="theme-options"
          >
            <li v-for="(option, index) in matches" :key="option.id" role="none">
              <button
                type="button"
                role="option"
                :aria-selected="option.id === themeStore.theme"
                :data-testid="`theme-option-${option.id}`"
                :data-highlighted="index === highlighted ? 'true' : 'false'"
                class="w-full flex items-center gap-3 px-2 py-1.5 rounded text-left"
                :style="
                  index === highlighted
                    ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                    : 'color: var(--semantic-text);'
                "
                @mouseenter="highlighted = index"
                @click="choose(option)"
              >
                <ThemeSwatch :swatch="option.swatch" />
                <span class="flex-1 min-w-0">
                  <span class="block text-body font-medium">{{ option.label }}</span>
                  <span
                    class="block text-dense truncate"
                    style="color: var(--semantic-text-muted)"
                  >
                    {{ option.description }}
                  </span>
                </span>
                <UiIcon
                  v-if="option.id === themeStore.theme"
                  name="star"
                  size-class="w-3.5 h-3.5"
                />
              </button>
            </li>
            <li
              v-if="matches.length === 0"
              class="px-2 py-1.5 text-dense"
              style="color: var(--semantic-text-muted)"
              data-testid="theme-picker-empty"
            >
              No theme matches “{{ query.trim() }}”.
            </li>
          </ul>
        </div>
      </div>

      <p class="text-dense" style="color: var(--semantic-text-dim)">
        Applies to this browser only, and never follows the operating system's appearance.
      </p>
    </div>
  </div>
</template>
