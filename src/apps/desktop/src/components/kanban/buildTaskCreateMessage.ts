/** Build the `create_and_run` user message. */
export function buildTaskCreateMessage(
  name: string,
  description: string,
  useGitWorktree: boolean,
  worktreePath?: string,
  baseBranch?: string,
  autoMerge?: boolean,
  autoMergeMethod?: string,
): string {
  const lines: string[] = [`Task : ${name}`]
  const desc = description.trim()
  if (desc !== '') {
    lines.push(`Description: ${desc}`)
  }
  if (useGitWorktree) {
    lines.push('', '#Notes UseGitWorktree')
    const wp = (worktreePath ?? '').trim()
    if (wp !== '') {
      lines.push(`Path: ${wp}`)
    }
    const base = (baseBranch ?? '').trim()
    if (base !== '') {
      lines.push(`Base: ${base}`)
    }
  }
  if (autoMerge) {
    if (!useGitWorktree) lines.push('')
    lines.push('#Notes AutoMerge')
    const method = (autoMergeMethod ?? '').trim()
    if (method !== '') {
      lines.push(`Method: ${method}`)
    }
  }
  // No `#Skill` line here: the backend appends one per skill from the task's
  // skill_names, so the agent receives each directive exactly once.
  return lines.join('\n')
}
