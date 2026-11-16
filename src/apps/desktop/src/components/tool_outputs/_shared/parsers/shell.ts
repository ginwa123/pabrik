import { boolField, numOrNullField, strField, strOrNullField, unwrapDataRecord } from './internal'
import { stripAnsiEscapes } from '../../../../helpers/stripAnsiEscapes'

export interface ParsedBash {
  command: string | null
  stdout: string
  stderr: string
  exitCode: number | null
  truncated: boolean
  timedOut: boolean
  stdoutLines: number
  stderrLines: number
}

export function parseBash(data: unknown): ParsedBash {
  const o = unwrapDataRecord(data)
  return {
    command: strOrNullField(o, 'command'),
    // Second, independent escape guard at the parse seam.
    stdout: stripAnsiEscapes(strField(o, 'stdout')),
    stderr: stripAnsiEscapes(strField(o, 'stderr')),
    exitCode: numOrNullField(o, 'exit_code'),
    truncated: boolField(o, 'truncated', false),
    timedOut: boolField(o, 'timeout', false),
    stdoutLines: numOrNullField(o, 'stdout_lines') ?? 0,
    stderrLines: numOrNullField(o, 'stderr_lines') ?? 0,
  }
}

/** Parse a pwsh (PowerShell Core) tool result. */
export function parsePwsh(data: unknown): ParsedBash {
  return parseBash(data)
}

/** Parse a `command` (unified shell) tool result. */
export function parseCommand(data: unknown): ParsedBash {
  return parseBash(data)
}

/** Dispatcher: parse a tool result based on the `toolName` it was registered under. */
export function parseShell(toolName: string, data: unknown): ParsedBash {
  switch (toolName) {
    case 'bash':
      return parseBash(data)
    case 'pwsh':
      return parsePwsh(data)
    case 'run_command':
      return parseBash(data)
    case 'command':
      return parseCommand(data)
    default:
      return parseBash(data)
  }
}
