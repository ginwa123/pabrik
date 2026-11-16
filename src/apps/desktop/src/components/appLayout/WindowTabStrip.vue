<script setup lang="ts">
import { computed } from 'vue'
import { useTabsStore } from '../../stores/tabs'
import SessionTabStrip from '../session/SessionTabStrip.vue'

/** The window's own row — documents, boards, Settings — has no ChatView to draw its strip, so the layout draws it above the page. */
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
    class="window-tab-strip"
    owner=""
    title="Pabrik"
    :show-sidebar-toggle="false"
    :show-close="false"
  />
</template>

<style scoped>
/* A phone carries ONE bar: the mobile top bar already names the surface and owns the menu, so a
   second strip over it would eat 40px of a 844px screen for a title nobody needs twice. */
@media (max-width: 767px) {
  .window-tab-strip {
    display: none;
  }
}
</style>
