/** usePabrikConfig — single source of truth for the Pabrik settings UI. */
import { computed, ref } from 'vue'

import type { PabrikConfig } from '../api'
import { userConfigSource, type PabrikConfigSource } from '../helpers/configSource'

/** @param source where the config is read from and written to. */
export function usePabrikConfig(source: PabrikConfigSource = userConfigSource()) {
  const config = ref<PabrikConfig | null>(null)
  const loaded = ref(false)
  // JSON.stringify of the config as the server last confirmed it.
  const snapshot = ref<string>('')
  const saving = ref(false)

  /** Has the config drifted from the confirmed document? */
  const dirty = computed(() => {
    if (!config.value) return false
    if (!snapshot.value) return false
    return countLeafDiffs(snapshot.value, JSON.stringify(config.value)) > 0
  })

  /** Re-snapshot the config so future edits compare against it. */
  function takeSnapshot() {
    snapshot.value = config.value ? JSON.stringify(config.value) : ''
  }

  async function load() {
    try {
      const data = await source.load()
      config.value = data ?? {}
    } catch {
      // localStorage fallback is handled by the orchestrator.
      config.value = {}
    }
    loaded.value = true
    takeSnapshot()
  }

  /** Set the config directly and take a snapshot of it. */
  function setConfig(c: PabrikConfig) {
    config.value = c
    loaded.value = true
    takeSnapshot()
  }

  /** PUT the config and, on success, confirm exactly what was SENT. */
  async function save() {
    if (!config.value) return
    const body = JSON.stringify(config.value)
    saving.value = true
    try {
      await source.save(JSON.parse(body) as PabrikConfig)
      snapshot.value = body
    } finally {
      saving.value = false
    }
  }

  return {
    config,
    loaded,
    dirty,
    saving,
    load,
    setConfig,
    save,
  }
}

/** Count primitive field differences between two JSON strings. Drives `dirty`. */
function countLeafDiffs(aJson: string, bJson: string): number {
  let a: unknown
  let b: unknown
  try {
    a = JSON.parse(aJson)
    b = JSON.parse(bJson)
  } catch {
    return aJson === bJson ? 0 : 1
  }
  return countDiffs(a, b)
}

function countDiffs(a: unknown, b: unknown): number {
  if (a === b) return 0
  // Treat undefined and missing as equivalent — JSON.stringify already omits undefined keys, so two objects that differ only by presence of an undefined field …
  if (a == null && b == null) return 0
  if (a == null || b == null) return 1
  if (typeof a !== 'object' || typeof b !== 'object') return 1
  if (Array.isArray(a) !== Array.isArray(b)) return 1
  if (Array.isArray(a) && Array.isArray(b)) {
    let n = Math.abs(a.length - b.length)
    const len = Math.min(a.length, b.length)
    for (let i = 0; i < len; i++) n += countDiffs(a[i], b[i])
    return n
  }
  const ao = a as Record<string, unknown>
  const bo = b as Record<string, unknown>
  // Only consider keys whose value is defined on BOTH sides.
  const aKeys = Object.keys(ao).filter(k => ao[k] !== undefined)
  const bKeys = Object.keys(bo).filter(k => bo[k] !== undefined)
  const keys = new Set([...aKeys, ...bKeys])
  let n = 0
  for (const k of keys) n += countDiffs(ao[k], bo[k])
  return n
}
