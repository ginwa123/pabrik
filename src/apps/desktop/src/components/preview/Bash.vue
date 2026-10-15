<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
/** Bash.vue — legacy-compat wrapper around the canonical ShellTool renderer.
 * The 2026-08-14 pwsh-tool refactor parameterised Bash.vue as ShellTool.vue
 * with a `toolName` prop. Bash.vue stays as a thin wrapper that hardcodes
 * `tool-name="bash"` so existing imports
 * (`import Bash from '../preview/Bash.vue'`) keep compiling unchanged.
 * New code should import ShellTool directly with an explicit toolName. */
import ShellTool from './ShellTool.vue'

defineProps<{
  content: unknown
  expanded?: boolean
  parameters?: string
}>()
</script>

<template>
  <ShellTool tool-name="bash" :content="content" :expanded="expanded" :parameters="parameters" />
</template>
