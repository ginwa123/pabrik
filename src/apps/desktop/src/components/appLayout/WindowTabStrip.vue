<script setup lang="ts">
import { computed } from 'vue'
import { useTabsStore } from '../../stores/tabs'
import SessionTabStrip from '../session/SessionTabStrip.vue'

/** The window's own row — documents, boards, Settings — has no ChatView to draw its strip, so the
 * layout draws it above the page. A chat surface draws its own (see `chatSurfaceActive` in
 * `AppLayout`), and the two overlays cover the whole surface, so neither gets this one. */
const props = defineProps<{
  /** `AppLayout`'s `currentView`. */
  view: string
  /** True when a ChatView owns the centre column and already draws a strip. */
  chatSurfaceActive: boolean
}>()

const tabsStore = useTabsStore()

const show = computed(
  () =>
    tabsStore.enabled &&
    !props.chatSurfaceActive &&
    tabsStore.activeOwner === '' &&
    props.view !== 'gitfile' &&
    props.view !== 'skill',
)
</script>

<template>
  <SessionTabStrip
    v-if="show"
    owner=""
    title="Pabrik"
    :show-sidebar-toggle="false"
    :show-close="false"
  />
</template>
