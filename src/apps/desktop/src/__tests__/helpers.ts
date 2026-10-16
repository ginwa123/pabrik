/** Shared test helpers. Keep this file dependency-light — only `vitest` and Node built-ins. Tests
 * in this directory import from `./helpers` to avoid duplicating boilerplate across spec files. */
export function makeLocalStorageStub(): Storage {
  const backing = new Map<string, string>()
  return {
    get length() {
      return backing.size
    },
    clear: () => backing.clear(),
    getItem: (k) => backing.get(k) ?? null,
    key: (i) => Array.from(backing.keys())[i] ?? null,
    removeItem: (k) => {
      backing.delete(k)
    },
    setItem: (k, v) => {
      backing.set(k, v)
    },
  }
}
