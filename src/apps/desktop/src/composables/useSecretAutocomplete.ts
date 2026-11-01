import { ref, type Ref } from 'vue'

import { applySecretPlaceholder, matchSecretNames, placeholderQueryAt } from '../helpers/secretPlaceholder'

type SecretField = HTMLInputElement | HTMLTextAreaElement

export interface SecretAutocompleteOptions {
  names: Ref<readonly string[]>
  commit: (text: string) => void
}

export function useSecretAutocomplete(options: SecretAutocompleteOptions) {
  const open = ref(false)
  const items = ref<string[]>([])
  const active = ref(0)

  function close(): void {
    open.value = false
    items.value = []
    active.value = 0
  }

  function onInput(field: SecretField): void {
    const hit = placeholderQueryAt(field.value, field.selectionStart ?? field.value.length)
    if (!hit) {
      close()
      return
    }
    const matches = matchSecretNames(options.names.value, hit.query)
    if (matches.length === 0) {
      close()
      return
    }
    items.value = matches
    active.value = 0
    open.value = true
  }

  function choose(name: string, field: SecretField): void {
    const applied = applySecretPlaceholder(field.value, field.selectionStart ?? field.value.length, name)
    close()
    if (!applied) return
    field.value = applied.text
    options.commit(applied.text)
    field.setSelectionRange(applied.caret, applied.caret)
  }

  function onKeydown(event: KeyboardEvent, field: SecretField): boolean {
    if (!open.value || items.value.length === 0) return false
    const last = items.value.length - 1
    switch (event.key) {
      case 'ArrowDown':
        active.value = active.value >= last ? 0 : active.value + 1
        return true
      case 'ArrowUp':
        active.value = active.value <= 0 ? last : active.value - 1
        return true
      case 'Enter':
      case 'Tab': {
        const name = items.value[active.value]
        if (name) choose(name, field)
        return true
      }
      case 'Escape':
        close()
        return true
      default:
        return false
    }
  }

  return { open, items, active, onInput, onKeydown, choose, close }
}
