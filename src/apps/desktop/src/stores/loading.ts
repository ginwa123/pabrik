import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

/** Global loading store — drives the top loading bar. Two independent counters (route navigation +
 * in-flight apiFetch calls) instead of booleans so concurrent requests overlap without flicker: the
 * bar is visible while EITHER counter is non-zero. */
export const useLoadingStore = defineStore('loading', () => {
  const routeDepth = ref(0)
  const apiPending = ref(0)

  const isNavigating = computed(() => routeDepth.value > 0)
  const isApiBusy = computed(() => apiPending.value > 0)
  const isBarVisible = computed(() => isNavigating.value || isApiBusy.value)

  function startRoute() {
    routeDepth.value += 1
  }

  function finishRoute() {
    if (routeDepth.value > 0) routeDepth.value -= 1
  }

  function startApi() {
    apiPending.value += 1
  }

  function finishApi() {
    if (apiPending.value > 0) apiPending.value -= 1
  }

  function reset() {
    routeDepth.value = 0
    apiPending.value = 0
  }

  return {
    routeDepth,
    apiPending,
    isNavigating,
    isApiBusy,
    isBarVisible,
    startRoute,
    finishRoute,
    startApi,
    finishApi,
    reset,
  }
})
