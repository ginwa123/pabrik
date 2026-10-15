// Format a date string to relative time (e.g., "5m", "2h", "3d", "1w", "6mo", "2y")
//
// Accepts:
//   - SQLite datetime UTC format ("YYYY-MM-DD HH:MM:SS")
//     - the canonical wire shape for `updated_at` (Migration 017+)
//     - also the SELECT-converted wire shape for
//       `last_human_touched_at` (Migration 082: SELECT casts via
//       strftime from unix-ms to SQLite datetime)
//   - Unix-ms integer as a string ("1788008400000")
//     - the raw storage shape for `last_human_touched_at_nano`
//       (Migration 075 convention; Migration 082 column)
//     - also the SSE event emit shape (the SSE emit path bypasses
//       the SELECT conversion - see on_event_sent.zig doc comment).
//     - detected as a string of >=10 digits with no separator chars.
//
// Returns 'now' for empty / invalid / unparseable inputs.
export const formatRelativeTime = (dateWillBeRelative: string): string => {
  if (!dateWillBeRelative || dateWillBeRelative.trim() === '') return 'now'

  // Migration 082: detect unix-ms shape (digits-only, length >= 10) before falling through to the
  // SQLite datetime path. The SSE event emit passes the raw unix-ms integer string; the REST GET
  // path passes the SQLite datetime string. Both must render correctly.
  const trimmed = dateWillBeRelative.trim()
  if (/^\d{10,}$/.test(trimmed)) {
    const unixMs = Number(trimmed)
    const diffMs = Date.now() - unixMs
    return formatDiff(diffMs)
  }

  // SQLite datetime path ("YYYY-MM-DD HH:MM:SS" UTC).
  // Handle the space -> 'T' separator and explicit 'Z' (UTC).
  const normalizedDate = trimmed.replace(' ', 'T')
  const date = new Date(normalizedDate + 'Z') // Append 'Z' to treat as UTC

  // Check if date is valid
  if (isNaN(date.getTime())) return 'now'

  const diffMs = Date.now() - date.getTime()
  return formatDiff(diffMs)
}

// Shared formatter for the diff-in-ms -> "5m"/"2h"/... path.
// Extracted so both the SQLite datetime + unix-ms branches share the
// exact same buckets, formatting, and "now" short-circuit.
function formatDiff(diffMs: number): string {
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHour = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHour / 24)
  const diffWeek = Math.floor(diffDay / 7)
  const diffMonth = Math.floor(diffDay / 30)
  const diffYear = Math.floor(diffDay / 365)

  if (diffSec < 60) return 'now'
  if (diffMin < 60) return `${diffMin}m`
  if (diffHour < 24) return `${diffHour}h`
  if (diffDay < 7) return `${diffDay}d`
  if (diffMonth < 12) return `${diffWeek}w`
  if (diffYear < 12) return `${diffMonth}mo`
  return `${diffYear}y`
}