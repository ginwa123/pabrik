import { asRecord } from '../toolOutputParser'

export { asRecord }

/**  * Unwrap one level when the input is a full tool envelope (`{tool, parameters, success, data,
 * error, v}` or its JSON string) instead of the bare `data` payload. Otherwise coerce to a record. */
export function unwrapDataRecord(data: unknown): Record<string, unknown> {
  const record = asRecord(data)
  if (
    typeof record.tool === 'string' ||
    (typeof record.success === 'boolean' && 'data' in record)
  ) {
    return asRecord(record.data)
  }
  return record
}

export function strField(o: Record<string, unknown>, key: string): string {
  const v = o[key]
  if (typeof v === 'string') return v
  if (v === null || v === undefined) return ''
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

export function strOrNullField(o: Record<string, unknown>, key: string): string | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

export function numOrNullField(o: Record<string, unknown>, key: string): number | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim())
    return Number.isFinite(n) ? n : null
  }
  return null
}

export function boolField(o: Record<string, unknown>, key: string, defaultValue = false): boolean {
  const v = o[key]
  if (v === null || v === undefined) return defaultValue
  if (typeof v === 'boolean') return v
  if (typeof v === 'string') {
    const t = v.trim()
    if (t === '') return defaultValue
    return t === 'true' || t === '1'
  }
  if (typeof v === 'number') return v !== 0
  return defaultValue
}
