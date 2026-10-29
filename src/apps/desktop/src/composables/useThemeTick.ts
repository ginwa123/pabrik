import { onUnmounted, ref } from 'vue'
import { onThemeApplied } from '../theme/runtime'

/** A counter that bumps on every theme change. Read it inside a `computed` or a render-time function
 * whose output is baked (an iframe `srcdoc`, an SVG) so that output is rebuilt for the new palette:
 * the DOM attribute alone repaints CSS, never a string that already holds hexes. */
export function useThemeTick() {
  const tick = ref(0)
  const off = onThemeApplied(() => {
    tick.value += 1
  })
  onUnmounted(off)
  return tick
}
