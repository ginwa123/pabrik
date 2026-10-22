/** The one line a tool call shows in the compact view. */
import { tryUnwrapToolOutput } from '../../../helpers/unwrapToolOutput'
import { extractTag } from './toolOutputParser'

/** The argument that identifies a call, per tool. A tool that is not listed
 * falls back to the first argument it was given. */
const PRIMARY_ARG: Record<string, string> = {
  read_file: 'path',
  write_file: 'path',
  text_replace: 'path',
  remove_file: 'path',
  list_directory: 'path',
  search: 'pattern',
  glob: 'pattern',
  command: 'command',
  bash: 'command',
  pwsh: 'command',
  use_skill: 'name',
  add_skill: 'name',
  edit_skill: 'name',
  remove_skill: 'name',
  search_skills: 'query',
  save_memory: 'id',
  load_memory: 'query',
  kanban_move_task: 'task_id',
  spawn_sub_agent: 'instruction',
  present_files: 'files',
  ask_user: 'question',
  web_search: 'query',
  generate_image: 'prompt',
  set_git_worktree: 'path',
  set_pull_request: 'pr_url',
  read_workspace_session: 'query',
}

/** The tags the XML form of the arguments can carry. */
const ARG_TAGS = [
  'path',
  'command',
  'pattern',
  'query',
  'name',
  'id',
  'question',
  'prompt',
  'instruction',
  'pr_url',
  'task_id',
  'files',
]

/** The order the first argument is picked in, for a tool with no rule. */
const FIRST_ARG = ['path', 'command', 'pattern', 'query', 'name', 'id', 'question']

export interface ToolCallSummary {
  /** The tool name, as the dev card's pill shows it. */
  name: string
  /** The one argument that identifies the call. */
  primary: string
  /** How the call ended. */
  status: 'ok' | 'failed' | 'running'
  /** The outcome text on the right of the row. */
  badge: string
}

function argsOf(parameters: string): Record<string, string> {
  const raw = parameters.trim()
  if (raw === '') return {}
  try {
    const parsed: unknown = JSON.parse(raw)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      const out: Record<string, string> = {}
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        if (typeof value === 'string') out[key] = value
      }
      return out
    }
  }
  // eslint-disable-next-line local/no-try-catch -- the arguments are either JSON or XML, so a failed JSON parse IS the XML form, not an error
  catch {
    // The arguments are XML, not JSON.
  }
  const out: Record<string, string> = {}
  for (const tag of ARG_TAGS) {
    const value = extractTag(raw, tag)
    if (value !== null && value.trim() !== '') out[tag] = value.trim()
  }
  return out
}

function exitCodeOf(data: unknown): number | null {
  if (!data || typeof data !== 'object') return null
  const value = (data as { exit_code?: unknown }).exit_code
  return typeof value === 'number' ? value : null
}

/** The one line a tool call shows. */
export function summarizeToolCall(
  tool: string,
  parameters: string,
  content: string,
): ToolCallSummary {
  const args = argsOf(parameters)
  const key = PRIMARY_ARG[tool] ?? FIRST_ARG.find((name) => args[name] !== undefined)
  const primary = key ? (args[key] ?? '') : ''

  const envelope = tryUnwrapToolOutput(content)
  const failed = envelope !== null && !envelope.success
  const running = envelope === null && content.trim() === ''
  const exitCode = exitCodeOf(envelope?.data)

  let status: ToolCallSummary['status'] = 'ok'
  let badge = ''
  if (failed) {
    status = 'failed'
    badge = 'failed'
  } else if (running) {
    status = 'running'
    badge = 'running'
  } else if (exitCode !== null && exitCode !== 0) {
    status = 'failed'
    badge = `exit ${exitCode}`
  }

  return { name: tool, primary, status, badge }
}
