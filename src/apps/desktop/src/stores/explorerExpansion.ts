import { defineStore } from 'pinia'
import { ref } from 'vue'
import { Effect, Either } from 'effect'

const STORAGE_KEY = 'pabrik-explorer-expanded:v1'
const MAX_CWDS = 20

type ExpandedByCwd = Record<string, string[]>

function attempt<T>(run: () => T): T | null {
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: run,
        catch: () => null,
      }),
    ),
  )
  return Either.isLeft(outcome) ? null : outcome.right
}

function normalize(raw: unknown): ExpandedByCwd {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const result: ExpandedByCwd = {}
  for (const [cwd, paths] of Object.entries(raw as Record<string, unknown>)) {
    if (!cwd || !Array.isArray(paths)) continue
    const clean = paths.filter((p): p is string => typeof p === 'string' && p.length > 0)
    if (clean.length > 0) result[cwd] = clean
  }
  return result
}

function readStored(): ExpandedByCwd {
  const raw = attempt(() => localStorage.getItem(STORAGE_KEY))
  if (raw === null) return {}
  const parsed = attempt(() => JSON.parse(raw) as unknown)
  return normalize(parsed)
}

function writeStored(byCwd: ExpandedByCwd): void {
  attempt(() => localStorage.setItem(STORAGE_KEY, JSON.stringify(byCwd)))
}

function withCwd(byCwd: ExpandedByCwd, cwd: string, paths: string[]): ExpandedByCwd {
  const next: ExpandedByCwd = {}
  for (const [key, value] of Object.entries(byCwd)) {
    if (key !== cwd) next[key] = value
  }
  next[cwd] = paths
  return next
}

export const useExplorerExpansionStore = defineStore('explorerExpansion', () => {
  const byCwd = ref<ExpandedByCwd>(readStored())

  function commit(next: ExpandedByCwd): void {
    byCwd.value = next
    writeStored(next)
  }

  function evictOverCap(byCwd: ExpandedByCwd): ExpandedByCwd {
    const keys = Object.keys(byCwd)
    if (keys.length <= MAX_CWDS) return byCwd
    const next: ExpandedByCwd = {}
    for (const key of keys.slice(keys.length - MAX_CWDS)) next[key] = byCwd[key]!
    return next
  }

  function expandedFor(cwd: string): string[] {
    if (!cwd) return []
    return byCwd.value[cwd] ?? []
  }

  function isExpanded(cwd: string, path: string): boolean {
    return expandedFor(cwd).includes(path)
  }

  function expand(cwd: string, path: string): void {
    if (!cwd || !path) return
    const current = expandedFor(cwd)
    if (current.includes(path)) return
    commit(evictOverCap(withCwd(byCwd.value, cwd, [...current, path])))
  }

  function collapse(cwd: string, path: string): void {
    const current = byCwd.value[cwd]
    if (!current || !current.includes(path)) return
    commit(
      withCwd(
        byCwd.value,
        cwd,
        current.filter((p) => p !== path),
      ),
    )
  }

  function toggle(cwd: string, path: string): boolean {
    if (isExpanded(cwd, path)) {
      collapse(cwd, path)
      return false
    }
    expand(cwd, path)
    return true
  }

  return { expandedFor, isExpanded, expand, collapse, toggle }
})
