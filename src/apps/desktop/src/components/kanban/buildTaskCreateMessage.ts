/**
 * Build the `create_and_run` user message.
 *
 * Format contract:
 *   Task : <name>
 *   Description: <description>   <- omitted when empty/whitespace
 *                                  <- blank line +
 *   #Notes UseGitWorktree         <- only when useGitWorktree is true
 *   Path: <worktreePath>          <- only when useGitWorktree is true
 *                                    AND worktreePath is non-empty.
 *                                    Canonical root (Option A):
 *                                    $HOME/.config/pabrik/.worktrees/<slug>.
 *                                    Always absolute — the dialog expands
 *                                    `~` before calling this.
 *   Base: <baseBranch>            <- only when useGitWorktree is true
 *                                    AND baseBranch is non-empty.
 *                                    A ref like `origin/main`. The agent
 *                                    reads this line and passes it as the
 *                                    `base` argument of `set_git_worktree`,
 *                                    so the worktree branches FROM it
 *                                    instead of the repo's current HEAD.
 * Pure function — no Vue, no store, trivially unit-testable. The
 * caller (KanbanView.handleCreateTaskSave) passes the already-trimmed
 * task name; the description, worktree path, base branch and skill
 * name are trimmed here so whitespace-only input degrades to the
 * shorter form.
 */
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
