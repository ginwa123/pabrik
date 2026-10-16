/** Tests for buildTaskCreateMessage — the `create_and_run` user-message formatter (plan:
 * 2026-09-11-kanban-create-task-message-format-worktree-toggle). */
import { describe, expect, it } from 'vitest'

import { buildTaskCreateMessage } from '@/components/kanban/buildTaskCreateMessage'

describe('buildTaskCreateMessage', () => {
  it('name only, toggle off → single Task line, no Description', () => {
    expect(buildTaskCreateMessage('My task', '', false)).toBe('Task : My task')
  })

  it('whitespace-only description is treated as empty', () => {
    expect(buildTaskCreateMessage('My task', '   \n  ', false)).toBe('Task : My task')
  })

  it('name + description, toggle off → two lines', () => {
    expect(buildTaskCreateMessage('My task', 'blablabla', false)).toBe(
      'Task : My task\nDescription: blablabla',
    )
  })

  it('name + description, toggle on → note appended after a blank line', () => {
    expect(buildTaskCreateMessage('My task', 'blablabla', true)).toBe(
      'Task : My task\nDescription: blablabla\n\n#Notes UseGitWorktree',
    )
  })

  it('name only, toggle on → note appended after a blank line, still no Description', () => {
    expect(buildTaskCreateMessage('My task', '', true)).toBe(
      'Task : My task\n\n#Notes UseGitWorktree',
    )
  })

  it('trims a padded description but keeps inner content verbatim', () => {
    expect(buildTaskCreateMessage('My task', '  padded  ', false)).toBe(
      'Task : My task\nDescription: padded',
    )
  })

  it('toggle on + path → Path line after the note', () => {
    expect(
      buildTaskCreateMessage('My task', 'blablabla', true, '/home/you/.config/pabrik/.worktrees/my-task'),
    ).toBe(
      'Task : My task\nDescription: blablabla\n\n#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/my-task',
    )
  })

  it('toggle on + whitespace-only path degrades to the bare note', () => {
    expect(buildTaskCreateMessage('My task', 'blablabla', true, '   ')).toBe(
      'Task : My task\nDescription: blablabla\n\n#Notes UseGitWorktree',
    )
  })

  it('toggle off + path → path is ignored', () => {
    expect(
      buildTaskCreateMessage('My task', 'blablabla', false, '/home/you/.config/pabrik/.worktrees/my-task'),
    ).toBe('Task : My task\nDescription: blablabla')
  })

  it('trims a padded path', () => {
    expect(
      buildTaskCreateMessage('My task', '', true, '  /home/you/.config/pabrik/.worktrees/x  '),
    ).toBe('Task : My task\n\n#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/x')
  })

  it('toggle on + path + base → Base line after Path', () => {
    expect(
      buildTaskCreateMessage(
        'My task',
        'blablabla',
        true,
        '/home/you/.config/pabrik/.worktrees/my-task',
        'origin/main',
      ),
    ).toBe(
      'Task : My task\nDescription: blablabla\n\n#Notes UseGitWorktree\nPath: /home/you/.config/pabrik/.worktrees/my-task\nBase: origin/main',
    )
  })

  it('toggle on + base without a path → Base line still emitted', () => {
    // The agent may derive the path itself from the task name, but the
    // base ref is only knowable from this line.
    expect(buildTaskCreateMessage('My task', '', true, '', 'origin/main')).toBe(
      'Task : My task\n\n#Notes UseGitWorktree\nBase: origin/main',
    )
  })

  it('trims a padded base ref', () => {
    expect(
      buildTaskCreateMessage('My task', '', true, '/tmp/wt/x', '  origin/main  '),
    ).toBe('Task : My task\n\n#Notes UseGitWorktree\nPath: /tmp/wt/x\nBase: origin/main')
  })

  it('toggle on + whitespace-only base degrades to no Base line', () => {
    expect(buildTaskCreateMessage('My task', '', true, '/tmp/wt/x', '   ')).toBe(
      'Task : My task\n\n#Notes UseGitWorktree\nPath: /tmp/wt/x',
    )
  })

  it('toggle off + base → base is ignored', () => {
    expect(
      buildTaskCreateMessage('My task', 'blablabla', false, '/tmp/wt/x', 'origin/main'),
    ).toBe('Task : My task\nDescription: blablabla')
  })

  it('toggle on without a base keeps the pre-existing message shape', () => {
    // Regression guard: existing tasks (no Base line) must produce the
    // exact same bytes as before this option existed.
    expect(
      buildTaskCreateMessage('My task', 'blablabla', true, '/tmp/wt/x'),
    ).toBe(
      'Task : My task\nDescription: blablabla\n\n#Notes UseGitWorktree\nPath: /tmp/wt/x',
    )
  })
})
