/** stripAnsiEscapes. */
const ESC = 0x1b
/** Bell — the legacy terminator for OSC / DCS payloads. */
const BEL = 0x07

/**  * Strip ANSI/ECMA-48 escape sequences from `s`. Pure and total: every input returns a string, no
 * escape is ever re-emitted, and a malformed sequence that runs to the end of the buffer is dropped
 * rather than leaked as a fragment. */
export function stripAnsiEscapes(s: string): string {
  if (!s) return s
  // Fast path — the overwhelming majority of captured output has no
  // escapes at all (git, gh, most build tools on POSIX).
  if (!s.includes('\x1b')) return s

  const out: string[] = []
  const n = s.length
  let i = 0

  while (i < n) {
    if (s.charCodeAt(i) !== ESC) {
      out.push(s.charAt(i))
      i += 1
      continue
    }

    i += 1 // consume the ESC itself
    if (i >= n) break // trailing lone ESC — nothing follows it

    // `charCodeAt` (not `s[i]`) because `noUncheckedIndexedAccess` types
    // an index read as `string | undefined`. Bounds are already proven
    // by the `i >= n` guard above, so this can never be NaN.
    const nextCode = s.charCodeAt(i)
    switch (true) {
      // CSI: ESC '[' params/intermediates, ended by one byte in 0x40..0x7E. Parameter bytes
      // (digits, ';', '?' and the private-mode markers) and intermediates (0x20..0x2F) all sit
      // below 0x40, so "first code unit at or above 0x40" terminates it.
      case nextCode === 0x5b /* '[' */: {
        i += 1
        // Bounded above by 0x7E as well as below by 0x40: the final byte
        // is in 0x40..0x7E, and a stray 0x7F+ must end the scan rather
        // than swallow the rest of the log. Matches ansi.zig exactly.
        while (i < n && (s.charCodeAt(i) < 0x40 || s.charCodeAt(i) > 0x7e)) i += 1
        if (i < n) i += 1 // consume the final byte
        break
      }

      // OSC / DCS / SOS / PM / APC — payload ended by BEL or ST (ESC '\').
      case nextCode === 0x5d /* ']' */:
      case nextCode === 0x50 /* 'P' */:
      case nextCode === 0x58 /* 'X' */:
      case nextCode === 0x5e /* '^' */:
      case nextCode === 0x5f /* '_' */: {
        i = skipStringPayload(s, i + 1)
        break
      }

      // Two-byte escape, optionally with intermediates in 0x20..0x2F
      // before the final byte (charset designation `ESC ( B`, DECALN
      // `ESC # 8`, RIS `ESC c`, keypad application mode `ESC =`).
      case nextCode >= 0x20 && nextCode <= 0x3f: {
        // Only an intermediate byte means another byte follows; `ESC =`
        // is complete at `=` and must not swallow the first character
        // of the payload.
        const hasIntermediates = nextCode >= 0x20 && nextCode <= 0x2f
        i += 1 // the character immediately after ESC
        if (hasIntermediates) {
          while (i < n && s.charCodeAt(i) >= 0x20 && s.charCodeAt(i) <= 0x2f) i += 1
          if (i < n) i += 1 // the final byte
        }
        break
      }

      // A bare ESC followed by anything else: both characters go.
      default:
        i += 1
    }
  }

  return out.join('')
}

/**  * Index just past an OSC/DCS-style string payload starting at `start`. Returns an absolute index,
 * not an offset — the terminator is consumed too, so the caller's cursor lands on the first
 * character after the sequence. */
function skipStringPayload(s: string, start: number): number {
  let i = start
  const n = s.length
  while (i < n) {
    if (s.charCodeAt(i) === BEL) return i + 1
    if (s.charCodeAt(i) === ESC && s.charCodeAt(i + 1) === 0x5c /* '\' */) return i + 2
    i += 1
  }
  return n
}
