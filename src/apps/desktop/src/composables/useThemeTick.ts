import { onUnmounted, ref } from 'vue'
import { onThemeApplied } from '../theme/runtime'

/** A counter that bumps on every theme change. */
export function useThemeTick() {
  const tick = ref(0)
  const off = onThemeApplied(() => {
    tick.value += 1
  })
  onUnmounted(off)
  return tick
}
