/** Static contract: every tool-card branch in ChatView's tool dispatcher (the v-if/v-else-if chain
 * on msg.tool_name) must thread `:parameters="getParametersForMessage(msg)"`. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const src = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

/** Slice the template window for one dispatcher branch: the `<Tag` occurrence whose tag body
 * carries the branch content (`:content="innerToolData(msg)"`, or `:message="msg"` for the plan
 * cards). */
function branchWindow(marker: string): string {
  let from = 0
  for (;;) {
    const start = src.indexOf(marker, from)
    if (start < 0) throw new Error(`branch marker ${marker} must exist in ChatView.vue`)
    const end = src.indexOf('/>', start)
    if (end <= start) throw new Error(`branch ${marker} must be self-closing`)
    const window = src.slice(start, end)
    if (window.includes('innerToolData(') || window.includes(':message="msg"')) return window
    // Comment/script mention — keep looking for the real branch.
    from = start + marker.length
  }
}

// Every branch rendering a tool_outputs / preview card with :content.
const PARAMETERS_BRANCHES = [
  '<ReadFile',
  '<WriteFile',
  '<UpdateActivity',
  '<Search\n',
  '<ReadWorkspaceSession',
  '<Glob',
  '<TextReplace',
  '<ShellTool',
  '<UseSkill',
  '<SearchSkills',
  '<AddSkill',
  '<EditSkill',
  '<RemoveSkill',
  '<RemoveFile',
  '<SpawnSubAgent',
  '<SetGitWorktree',
  '<ReadCompactedMessages',
  '<KanbanMove',
  '<KanbanList',
  '<ListDirectory',
  '<SaveMemory',
  '<LoadMemory',
  '<PresentFiles',
  '<GenerateImage',
  '<WebSearch',
  '<ListSearchProviders',
  '<McpTool',
]

describe('ChatView tool dispatcher — :parameters threading', () => {
  it.each(PARAMETERS_BRANCHES)('%s threads :parameters', (marker) => {
    expect(branchWindow(marker)).toContain(':parameters="getParametersForMessage(msg)"')
  })

  it('<UpdatePlan> uses the :message idiom (no :parameters needed)', () => {
    const window = branchWindow('<UpdatePlan')
    expect(window).toContain(':message="msg"')
    expect(window).not.toContain(':parameters')
  })

  it('<GetPlan> uses the :message idiom (no :parameters needed)', () => {
    const window = branchWindow('<GetPlan')
    expect(window).toContain(':message="msg"')
    expect(window).not.toContain(':parameters')
  })
})
