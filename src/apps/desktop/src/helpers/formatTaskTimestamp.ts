// Human-readable "time since" for the per-task surfaces (kanban card, kanban row-mode row).
export function formatTaskTimestamp(input: Date | string | number | null | undefined): string {
  if (input === null || input === undefined) return ''
  let d: Date
  if (input instanceof Date) {
    d = input
  } else if (typeof input === 'string') {
    // Tolerate the "YYYY-MM-DD HH:MM:SS" format the backend uses by
    // replacing the space with 'T' and marking it UTC. ISO strings
    // ('...Z' / '...+00:00') are handled natively by the Date ctor.
    const normalized = input.includes('T') ? input : input.replace(' ', 'T')
    d = new Date(
      normalized.endsWith('Z') || /[+-]\d{2}:?\d{2}$/.test(normalized)
        ? normalized
        : normalized + 'Z',
    )
  } else {
    d = new Date(input)
  }
  const ms = Date.now() - d.getTime()
  if (Number.isNaN(ms)) return ''
  const abs = Math.abs(ms)
  // Future timestamps render with the same shape, just negated — the
  // canonical input is `updatedAt` (always past), this is defensive.
  const sign = ms < 0 ? '-' : ''
  if (abs < 45_000) return 'just now' // <45s rounds to "just now"
  const min = Math.floor(abs / 60_000)
  if (min < 60) return `${sign}${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${sign}${hr}h ago`
  const day = Math.floor(hr / 24)
  if (day === 1) return `${sign}yesterday`
  if (day < 7) return `${sign}${day}d ago`
  if (day < 30) return `${sign}${Math.floor(day / 7)}w ago`
  // Older than ~a month: show an absolute date so the user has a stable
  // reference. Pinned to en-US short so every teammate sees the same
  // format (no "5/7/26" vs "7 May" surprises).
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

/** The raw timestamp behind the "X ago" string, for the row's `title` tooltip. */
export function taskTimestampTooltip(input: Date | string | number | null | undefined): string {
  if (input === null || input === undefined) return ''
  if (input instanceof Date) return input.toISOString()
  return String(input)
}
