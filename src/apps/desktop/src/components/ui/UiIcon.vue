<script setup lang="ts">
/**
 * The one component every non-brand glyph in the app renders through.
 *
 * It replaces the emoji that used to stand in for icons. The rule this
 * enforces (`AGENTS.md` — "No Emoji as Icons; Use Inline SVG") is not
 * taste: an emoji's pixel height comes from the platform's emoji font,
 * so a row built from 📝 ➕ 🗑️ 🔄 📋 ❓ was six sizes tall instead of one,
 * and the same commit drew differently on Windows, macOS and Linux. An
 * SVG inherits `currentColor` and its box from the `size` prop, so a
 * panel that mixes a label and an icon gets one row height and one
 * palette.
 *
 * What it also buys is assertability. A spec can pin `data-icon="trash"`
 * and the registry can answer "is `trash` a name?"; neither is possible
 * against an emoji, which is why the emoji status column was untestable.
 */
import { computed } from 'vue'
import { ICON_PATHS, type UiIconName } from './icons'

const props = withDefaults(
  defineProps<{
    /** A key of `ICON_PATHS`. */
    name: UiIconName
    /** Rendered size in px. Ignored when `sizeClass` is set. */
    size?: number
    /** Tailwind box class, e.g. `w-5 h-5`. Wins over `size`. */
    sizeClass?: string | null
    /** Accessible name. Leave unset when a visible label already names
     * the thing — the icon is then decorative and must stay
     * `aria-hidden`, not announced as "Trash" after "Delete". */
    title?: string | null
    /** Stroke weight. 1.75 is the house default: Lucide ships 2, which
     * reads heavy next to 12px monospace in the muted palette. */
    strokeWidth?: number
  }>(),
  { size: 16, sizeClass: null, title: null, strokeWidth: 1.75 },
)

const paths = computed<readonly string[]>(() => ICON_PATHS[props.name] ?? [])

// An inline SVG sits on the text baseline and opens up descender space below it, which is how a
// 16px glyph quietly grows a 20px row. These three classes keep the box equal to the glyph and stop
// flex/grid parents from squashing it.
const baseClass = 'inline-block shrink-0 align-middle'
</script>

<template>
  <svg
    :class="sizeClass ? `${baseClass} ${sizeClass}` : baseClass"
    :width="sizeClass ? undefined : size"
    :height="sizeClass ? undefined : size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    :stroke-width="strokeWidth"
    stroke-linecap="round"
    stroke-linejoin="round"
    xmlns="http://www.w3.org/2000/svg"
    :role="title ? 'img' : undefined"
    :aria-hidden="title ? undefined : 'true'"
    focusable="false"
    data-testid="ui-icon"
    :data-icon="name"
  >
    <title v-if="title">{{ title }}</title>
    <path v-for="(d, i) in paths" :key="i" :d="d" />
  </svg>
</template>
