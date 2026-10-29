import { ref } from 'vue'
import { defineStore } from 'pinia'
import { THEMES, isThemeName, readStoredTheme, type ThemeName } from '../theme/themes'
import { applyTheme, persistTheme } from '../theme/runtime'

export const useThemeStore = defineStore('theme', () => {
  const theme = ref<ThemeName>(
    readStoredTheme(typeof localStorage === 'undefined' ? null : localStorage),
  )

  /** Every theme the registry knows, in display order — the settings UI renders this list. */
  const options = THEMES

  function setTheme(next: ThemeName): void {
    if (!isThemeName(next)) return
    theme.value = next
    persistTheme(next)
    applyTheme(document.documentElement, next)
  }

  return { theme, options, setTheme }
})
