/** Unsent composer text, keyed by draft key (usually `chat:<sessionId>`). Pure: the store owns the ref. */
export type DraftBox = Record<string, string>

export function readDraft(box: DraftBox, key: string): string {
  if (!key) return ''
  return box[key] ?? ''
}

/** The next box, or null when nothing changed (so the caller can skip a write). */
export function writeDraft(box: DraftBox, key: string, text: string): DraftBox | null {
  if (!key) return null
  if (!text) return dropDraft(box, key)
  if (box[key] === text) return null
  return { ...box, [key]: text }
}

export function dropDraft(box: DraftBox, key: string): DraftBox | null {
  if (!key || !(key in box)) return null
  const next = { ...box }
  delete next[key]
  return next
}
