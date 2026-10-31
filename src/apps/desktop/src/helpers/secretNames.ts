import { computed, inject, provide, toValue, type ComputedRef, type InjectionKey, type MaybeRefOrGetter } from 'vue'

const NO_NAMES: readonly string[] = []

const SECRET_NAMES: InjectionKey<() => readonly string[]> = Symbol('pabrik:secret-names')

export function provideSecretNames(names: MaybeRefOrGetter<readonly string[]>): void {
  provide(SECRET_NAMES, () => toValue(names))
}

export function useSecretNames(): ComputedRef<readonly string[]> {
  const read = inject(SECRET_NAMES, () => NO_NAMES)
  return computed(() => read())
}
