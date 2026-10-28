import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import {
  backgroundToShellData,
  parseBackgroundCommandOutput,
} from '../../../helpers/isBackgroundCommandOutput'
import ShellTool from '../ShellTool.vue'

const wire = (over: Record<string, unknown> = {}): string =>
  JSON.stringify({
    pid: 1234,
    command: 'sleep 10',
    stdout: 'hello\nworld',
    truncated: false,
    total_bytes: null,
    log_path: null,
    ...over,
  })

const backgroundCard = (content: string, expanded = false) => {
  const parsed = parseBackgroundCommandOutput(content)
  return mount(ShellTool, {
    props: {
      toolName: 'command',
      content: parsed === null ? content : backgroundToShellData(parsed),
      parameters: '{}',
      expanded,
    },
  })
}

describe('ShellTool.vue — a finished background command', () => {
  it('names the command the process ran instead of "unknown"', () => {
    const wrapper = backgroundCard(wire())

    expect(wrapper.get('[data-testid="shell-tool-pill"]').text()).toBe('command')
    expect(wrapper.text()).toContain('$ sleep 10')
    expect(wrapper.text()).not.toContain('unknown')
  })

  it('shows the output the process wrote', () => {
    const wrapper = backgroundCard(wire(), true)

    expect(wrapper.text()).toContain('hello\nworld')
  })

  it('marks a completion whose log was truncated', () => {
    const wrapper = backgroundCard(
      wire({ truncated: true, total_bytes: 99999, log_path: '/tmp/full.log' }),
    )

    expect(wrapper.text()).toContain('$ sleep 10')
    expect(wrapper.text()).toContain('truncated')
  })

  it('keeps the raw row when it is not a background completion', () => {
    const parsed = parseBackgroundCommandOutput('just a sentence')
    expect(parsed).toBeNull()
  })
})
