<script setup lang="ts">
/** Global top loading bar (NProgress-style, zero deps). Visible while the loading store reports
 * route navigation or in-flight API activity. A 150ms show-delay suppresses flicker on fast
 * requests; hide is immediate with a 200ms fade. */
/** The indeterminate slide animation degrades to a static bar under `prefers-reduced-motion`.
 * Mounted once in App.vue above <router-view/> so it covers every route including /login. */
import { ref, onMounted, onUnmounted } from 'vue'
import { useLoadingStore } from '../../stores/loading'

const SHOW_DELAY_MS = 150

const loading = useLoadingStore()
const visible = ref(false)
let showTimer: ReturnType<typeof setTimeout> | null = null

function clearTimer() {
  if (showTimer !== null) {
    clearTimeout(showTimer)
    showTimer = null
  }
}

function syncBarVisibility(busy: boolean) {
  clearTimer()
  if (busy) {
    showTimer = setTimeout(() => {
      visible.value = true
      showTimer = null
    }, SHOW_DELAY_MS)
  } else {
    visible.value = false
  }
}

// The store is the visibility-setting path: subscribe to it (a subscription, not a watcher) and run
// the same start/clear-timer body.
let prevBusy: boolean | null = null
const stopSubscribe = loading.$subscribe(() => {
  const busy = loading.isBarVisible
  if (busy === prevBusy) return
  prevBusy = busy
  syncBarVisibility(busy)
})

onMounted(() => {
  prevBusy = loading.isBarVisible
  syncBarVisibility(loading.isBarVisible)
})

onUnmounted(() => {
  stopSubscribe()
  clearTimer()
})
</script>

<template>
  <div
    v-if="visible"
    data-testid="top-loading-bar"
    role="progressbar"
    aria-label="Page loading"
    class="top-loading-bar"
  >
    <div class="top-loading-bar-fill" />
  </div>
</template>

<style scoped>
.top-loading-bar {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  height: 3px;
  z-index: 9999;
  pointer-events: none;
  background-color: transparent;
  animation: top-loading-bar-fade-in 200ms ease-out;
}

.top-loading-bar-fill {
  height: 100%;
  width: 40%;
  border-radius: 0 2px 2px 0;
  background: linear-gradient(90deg, var(--color-violet), var(--color-aqua));
  animation: top-loading-bar-slide 1.1s ease-in-out infinite;
}

@keyframes top-loading-bar-slide {
  0% {
    margin-left: -40%;
  }
  100% {
    margin-left: 100%;
  }
}

@keyframes top-loading-bar-fade-in {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}

@media (prefers-reduced-motion: reduce) {
  .top-loading-bar-fill {
    width: 100%;
    border-radius: 0;
    animation: none;
  }
}
</style>
