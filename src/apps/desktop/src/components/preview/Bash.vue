<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
/** Bash.vue — legacy-compat wrapper around the canonical ShellTool renderer. */
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
