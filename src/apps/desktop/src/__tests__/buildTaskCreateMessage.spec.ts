/**
 * Tests for buildTaskCreateMessage — the `create_and_run` user-message
 * formatter (plan: 2026-09-11-kanban-create-task-message-format-worktree-toggle).
 *
 * Format contract:
 *   Task : <name>
 *   Description: <description>   <- omitted when empty/whitespace
 *                                  <- blank line +
 *   #Notes UseGitWorktree         <- only when useGitWorktree is true
 *   Path: <worktreePath>          <- only when useGitWorktree is true
 *                                    AND worktreePath is non-empty
 *   #Skill <skillName>            <- only when skillName is non-empty.
 *                                    The exact `skills.name` the user
 *                                    picked in the New-task dialog. The
 *                                    agent reads this line and calls
 *                                    `use_skill({ name })` with it.
 */
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

// Migration 110 - the `#Skill <name>` directive. Independent of the
// worktree toggle: a task can ask for a skill without a worktree, and
// vice versa.
describe('buildTaskCreateMessage - #Skill directive (Migration 110)', () => {
  it('no skill produces no #Skill line (the canonical sentinel)', () => {
    expect(buildTaskCreateMessage('My task', 'desc', false, '', '', '')).toBe(
      'Task : My task\nDescription: desc',
    )
  })

  it('undefined skill produces no #Skill line', () => {
    expect(buildTaskCreateMessage('My task', 'desc', false)).toBe(
      'Task : My task\nDescription: desc',
    )
  })

  it('skill alone appends the #Skill line after a blank line', () => {
    expect(buildTaskCreateMessage('My task', '', false, '', '', 'pdf')).toBe(
      'Task : My task\n\n#Skill pdf',
    )
  })

  it('skill + description appends the #Skill line after Description', () => {
    expect(buildTaskCreateMessage('My task', 'desc', false, '', '', 'pdf')).toBe(
      'Task : My task\nDescription: desc\n\n#Skill pdf',
    )
  })

  it('whitespace-only skill degrades to no #Skill line', () => {
    expect(buildTaskCreateMessage('My task', 'desc', false, '', '', '   ')).toBe(
      'Task : My task\nDescription: desc',
    )
  })

  it('trims a padded skill name', () => {
    expect(buildTaskCreateMessage('My task', '', false, '', '', '  pdf  ')).toBe(
      'Task : My task\n\n#Skill pdf',
    )
  })

  it('skill + worktree emits both directives, worktree block first', () => {
    expect(
      buildTaskCreateMessage('My task', 'desc', true, '/tmp/wt/x', 'origin/main', 'pdf'),
    ).toBe(
      'Task : My task\nDescription: desc\n\n#Notes UseGitWorktree\nPath: /tmp/wt/x\nBase: origin/main\n\n#Skill pdf',
    )
  })

  it('skill + bare worktree emits both bare directives', () => {
    expect(buildTaskCreateMessage('My task', '', true, '', '', 'pdf')).toBe(
      'Task : My task\n\n#Notes UseGitWorktree\n\n#Skill pdf',
    )
  })

  it('a dotted skill name survives verbatim', () => {
    // Skill names allow dots (e.g. `pdf.tools.v2`) - the name is the
    // row's identity, so it must not be normalized away.
    expect(buildTaskCreateMessage('My task', '', false, '', '', 'pdf.tools.v2')).toBe(
      'Task : My task\n\n#Skill pdf.tools.v2',
    )
  })
})
