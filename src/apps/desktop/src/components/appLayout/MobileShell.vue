<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import MobileTopBar from './MobileTopBar.vue'
import { useMobileDrawer } from './useMobileDrawer'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useResponsiveLayout } from '../../composables/useResponsiveLayout'

const props = defineProps<{ mobile?: boolean }>()

const router = useRouter()
const navigationStore = useNavigationStore()
const workspacesStore = useWorkspacesStore()

const { isMobile: viewportIsMobile } = useResponsiveLayout(undefined, {
  onChange: (mobile) => {
    if (!mobile) navigationStore.closeMobileNav()
  },
})

const isMobile = computed(() => props.mobile === true || viewportIsMobile.value)
const open = computed(() => navigationStore.mobileNavOpen)

useMobileDrawer({
  host: {
    isOpen: () => navigationStore.mobileNavOpen,
    close: () => navigationStore.closeMobileNav(),
  },
  route: { onNavigate: (listener) => router?.afterEach?.(() => listener()) ?? (() => {}) },
})

const title = computed(
  () =>
    workspacesStore.activeTask?.name ||
    navigationStore.activeChatName ||
    workspacesStore.activeWorkspaceItem?.name ||
    workspacesStore.activeWorkspace?.name ||
    '',
)
</script>

<template>
  <template v-if="isMobile">
    <div
      v-if="open"
      class="mobile-nav-backdrop"
      data-testid="mobile-nav-backdrop"
      aria-hidden="true"
      @click="navigationStore.closeMobileNav()"
    />
    <MobileTopBar
      :title="title"
      :nav-open="open"
      @toggle-nav="navigationStore.toggleMobileNav()"
    />
  </template>
</template>
