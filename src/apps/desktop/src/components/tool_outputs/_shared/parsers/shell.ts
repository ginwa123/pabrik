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
    // Second, independent escape guard at the parse seam. The backend strips in
    // shell.result_to_json; this covers live/partial payloads and any future raw-bytes producer.
    stdout: stripAnsiEscapes(strField(o, 'stdout')),
    stderr: stripAnsiEscapes(strField(o, 'stderr')),
    exitCode: numOrNullField(o, 'exit_code'),
    truncated: boolField(o, 'truncated', false),
    timedOut: boolField(o, 'timeout', false),
    stdoutLines: numOrNullField(o, 'stdout_lines') ?? 0,
    stderrLines: numOrNullField(o, 'stderr_lines') ?? 0,
  }
}

/** Parse a pwsh (PowerShell Core) tool result. Same JSON `data` shape as bash — per plan D2 + D10
 * the schema is structurally identical, only the `tool` field that wraps the envelope differs. */
export function parsePwsh(data: unknown): ParsedBash {
  return parseBash(data)
}

/** Parse a `command` (unified shell) tool result. */
export function parseCommand(data: unknown): ParsedBash {
  return parseBash(data)
}

/**  * Dispatcher: parse a tool result based on the `toolName` it was registered under. 'bash' / 'pwsh'
 * / 'run_command' (legacy alias) / 'command' (unified shell) all use the same payload. New shells
 * with divergent payload shapes must add their own branch here. */
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
