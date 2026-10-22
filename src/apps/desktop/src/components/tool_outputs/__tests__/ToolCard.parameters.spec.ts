/** Static contract: every tool-card branch in the tool dispatcher (the v-if/v-else-if chain
 * on message.tool_name) must thread the parameters. The dispatcher lives in ToolCard.vue. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const source = readFileSync(resolve(__dirname, '../ToolCard.vue'), 'utf8')
const template = source.slice(source.indexOf('<template>'))

/** Slice the template window for one dispatcher branch: the `<Tag` occurrence whose tag body
 * carries the branch content (`:content="content"`, or `:message="message"` for the plan
 * cards). */
function branchWindow(marker: string): string {
  let from = 0
  for (;;) {
    const start = template.indexOf(marker, from)
    if (start < 0) throw new Error(`branch marker ${marker} must exist in ToolCard.vue`)
    const end = template.indexOf('/>', start)
    if (end <= start) throw new Error(`branch ${marker} must be self-closing`)
    const window = template.slice(start, end)
    if (window.includes(':content="content"') || window.includes(':message="message"'))
      return window
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

describe('the tool dispatcher — :parameters threading', () => {
  it.each(PARAMETERS_BRANCHES)('%s threads :parameters', (marker) => {
    expect(branchWindow(marker)).toContain(':parameters="parameters"')
  })

  it('<UpdatePlan> uses the :message idiom (no :parameters needed)', () => {
    const window = branchWindow('<UpdatePlan')
    expect(window).toContain(':message="message"')
    expect(window).not.toContain(':parameters')
  })

  it('<GetPlan> uses the :message idiom (no :parameters needed)', () => {
    const window = branchWindow('<GetPlan')
    expect(window).toContain(':message="message"')
    expect(window).not.toContain(':parameters')
  })
})
