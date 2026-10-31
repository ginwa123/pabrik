/** An opencode-CLI step is a `shell` tool row. The dispatcher must draw it with the
 * shell card — the command and its output — not the raw-JSON fallback. */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'

import ToolCard from '../ToolCard.vue'

const envelope = {
  tool: 'shell',
  parameters: { command: 'ls -la' },
  success: true,
  data: { stdout: 'total 292\ndrwxr-xr-x 1 ginwa ginwa 612 .', stderr: '', exit_code: 0, _raw: 'total 292' },
  error: null,
  v: 1,
}

function mountCard(toolName: string) {
  return mount(ToolCard, {
    props: {
      message: {
        id: 'h1',
        role: 'tool',
        content: JSON.stringify(envelope),
        tool_name: toolName,
        tool_call_id: 'cli-1',
        finish_reason: 'tool',
      },
      content: envelope.data,
      parameters: JSON.stringify(envelope.parameters),
      expanded: true,
      expandKey: 'h1',
      cwd: '/tmp',
      sessionId: 'sess_1',
      subAgentProgress: null,
      subAgentArgs: null,
    },
  })
}

describe('ToolCard — an opencode CLI step', () => {
  it('draws a shell step with its command and its output', () => {
    const text = mountCard('shell').text()
    expect(text).toContain('ls -la')
    expect(text).toContain('total 292')
  })

  it('still draws a pabrik `command` step the same way', () => {
    const text = mountCard('command').text()
    expect(text).toContain('ls -la')
    expect(text).toContain('total 292')
  })
})
