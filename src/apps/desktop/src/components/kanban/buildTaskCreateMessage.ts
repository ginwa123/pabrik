/** Build the `create_and_run` user message. */
export function buildTaskCreateMessage(
  name: string,
  description: string,
  useGitWorktree: boolean,
  worktreePath?: string,
  baseBranch?: string,
  skillName?: string,
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
  const skill = (skillName ?? '').trim()
  if (skill !== '') {
    lines.push('', `#Skill ${skill}`)
  }
  return lines.join('\n')
}
