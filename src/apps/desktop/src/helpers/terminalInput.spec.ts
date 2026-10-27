import { describe, expect, it } from 'vitest'
import { inputForBackend } from './terminalInput'

describe('inputForBackend', () => {
  it('drops a mode report instead of typing it into a pipe-backed shell', () => {
    expect(inputForBackend('pipe', '\x1b[?2004;2$y')).toBe('')
  })

  it('drops a cursor-position and a device-attributes report', () => {
    expect(inputForBackend('pipe', '\x1b[1;1R')).toBe('')
    expect(inputForBackend('pipe', '\x1b[?1;2c')).toBe('')
  })

  it('drops an SGR mouse report and an OSC reply', () => {
    expect(inputForBackend('pipe', '\x1b[<35;29;89M')).toBe('')
    expect(inputForBackend('pipe', '\x1b]11;rgb:0000/0000/0000\x1b\\')).toBe('')
  })

  it('keeps the typing, the Enter and a paste on a pipe-backed shell', () => {
    expect(inputForBackend('pipe', 'clear\r')).toBe('clear\r')
    expect(inputForBackend('pipe', 'a\x1b[?2004;2$yb\n')).toBe('ab\n')
  })

  it('drops a lone Escape, which can never reach a pipe-backed shell', () => {
    expect(inputForBackend('pipe', 'ls\x1b')).toBe('ls')
  })

  it('sends every byte to a real pty backend', () => {
    for (const backend of ['posix-pty', 'conpty', 'guest-pty']) {
      expect(inputForBackend(backend, '\x1b[1;1R')).toBe('\x1b[1;1R')
      expect(inputForBackend(backend, '\x1b[A')).toBe('\x1b[A')
    }
  })
})
