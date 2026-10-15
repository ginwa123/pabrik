import { describe, expect, it } from 'vitest'

import { stripAnsiEscapes } from './stripAnsiEscapes'

/** Mirrors the Zig tests in `src/helpers/ansi.zig`. These are the byte
 * sequences real toolchains emit — MSBuild, PowerShell, cargo, pytest —
 * not synthetic regex bait. If the two implementations ever drift on
 * what counts as an escape, one of these suites goes red. */

describe('stripAnsiEscapes — MSBuild colour codes', () => {
  // Byte-for-byte what `dotnet build … | Select-String …` hands back:
  // reverse-video "warning", bold "MSB", then reset. This is the exact
  // shape in the bug report that rendered as `?[7mwarning ?[0m`.
  const msbuild =
    'C:\\src\\Microsoft.Common.CurrentVersion.targets(4919,5): \x1b[7mwarning \x1b[0m\x1b[1mMSB\x1b[0m3026: Could not copy the file'

  it('drops the escape codes and keeps the words', () => {
    expect(stripAnsiEscapes(msbuild)).toBe(
      'C:\\src\\Microsoft.Common.CurrentVersion.targets(4919,5): warning MSB3026: Could not copy the file',
    )
  })

  it('leaves no ESC, no "[7m"/"[0m" fragment, and no U+FFFD', () => {
    const out = stripAnsiEscapes(msbuild)
    expect(out).not.toContain('\x1b')
    expect(out).not.toContain('[7m')
    expect(out).not.toContain('[0m')
    expect(out).not.toContain('�')
  })
})

describe('stripAnsiEscapes — sequence families', () => {
  it('removes erase-screen and cursor moves', () => {
    expect(stripAnsiEscapes('\x1b[2J\x1b[HBuilding...\x1b[1;1HDone')).toBe('Building...Done')
  })

  it('removes private-mode sequences including the "?" parameter byte', () => {
    // `ESC[?` — '?' is 0x3F, BELOW the 0x40 terminator. A scanner that
    // stops at the first "not a digit" leaks `?25l` into the output,
    // which is the classic half-stripped tail.
    expect(stripAnsiEscapes('\x1b[?25lhidden\x1b[?25h')).toBe('hidden')
  })

  it('removes OSC window titles through both BEL and ST terminators', () => {
    expect(stripAnsiEscapes('\x1b]0;my title\x07visible\x1b]7;file:///tmp\x1b\\tail')).toBe(
      'visibletail',
    )
  })

  it('removes two-byte and intermediate escapes without eating payload', () => {
    // Charset designation `ESC ( B`, DECALN `ESC # 8`, RIS `ESC c`,
    // keypad application mode `ESC =`.
    expect(stripAnsiEscapes('\x1b(B\x1b#8\x1bc\x1b=ok')).toBe('ok')
  })
})

describe('stripAnsiEscapes — malformed and edge input', () => {
  it('drops a lone trailing ESC', () => {
    expect(stripAnsiEscapes('text\x1b')).toBe('text')
  })

  it('never leaks a fragment from a sequence truncated mid-flight', () => {
    // The capture cap in run_shell_command cuts at max_output bytes, so
    // a real capture CAN end mid-sequence.
    expect(stripAnsiEscapes('good\x1b[7m')).toBe('good')
    expect(stripAnsiEscapes('good\x1b]0;title')).toBe('good')
  })

  it('returns escape-free input unchanged, by identity on the fast path', () => {
    const plain = 'Build succeeded.\n    0 Warning(s)\n    0 Error(s)\n'
    expect(stripAnsiEscapes(plain)).toBe(plain)
  })

  it('is total on the empty string', () => {
    expect(stripAnsiEscapes('')).toBe('')
  })

  it('leaves multi-byte UTF-8 intact (a Windows path with an accented name)', () => {
    // Stripping must not corrupt UTF-8 — a build log with
    // C:\Users\gilang is exactly the case that regressed into mojibake.
    const input = '\x1b[32m✓ C:\\Users\\gilang\\proyek — 3 done\x1b[0m'
    expect(stripAnsiEscapes(input)).toBe('✓ C:\\Users\\gilang\\proyek — 3 done')
  })
})
