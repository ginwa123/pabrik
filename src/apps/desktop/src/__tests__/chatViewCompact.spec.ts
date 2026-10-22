import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'

import PabrikGeneralSection, {
  type PabrikGeneralSettings,
} from '../components/pabrik/PabrikGeneralSection.vue'
import CompactToolGroup from '../components/tool_outputs/compact/CompactToolGroup.vue'
import type { ToolCardData } from '../components/tool_outputs/ToolCard.vue'
import { summarizeToolCall } from '../components/tool_outputs/_shared/toolSummary'
import { unwrapToolOutput } from '../helpers/unwrapToolOutput'
import { chatViewModeFrom, useChatViewStore } from '../stores/chatView'

interface CardOptions {
  success?: boolean
  durationMs?: number
  content?: string
  toolCallId?: string
}

/** One tool call of a run, with the envelope the backend wrote. */
function card(tool: string, options: CardOptions = {}): ToolCardData {
  const envelope: Record<string, unknown> = {
    tool,
    parameters: '{}',
    success: options.success ?? true,
    data: {},
    error: null,
    v: 1,
  }
  if (options.durationMs !== undefined) envelope.duration_ms = options.durationMs
  const content = options.content ?? JSON.stringify(envelope)
  return {
    message: {
      id: `${tool}-1`,
      role: 'tool',
      content,
      tool_name: tool,
      tool_call_id: options.toolCallId,
    },
    content: {},
    parameters: '{}',
    expanded: false,
    expandKey: `${tool}-1`,
    subAgentProgress: null,
    subAgentArgs: null,
  }
}

/** A call with the arguments the agent passed. */
function call(tool: string, parameters: string, options: CardOptions = {}): ToolCardData {
  const base = card(tool, options)
  return { ...base, parameters }
}

function mountGroup(cards: ToolCardData[]) {
  return mount(CompactToolGroup, {
    props: { cards, cwd: '/tmp', sessionId: 'session-1' },
  })
}

describe('the chat view mode', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('takes the compact mode from the config that carries it', () => {
    expect(chatViewModeFrom({ chat_view: 'compact' })).toBe('compact')
  })

  it('takes the dev mode when the config carries no chat view', () => {
    expect(chatViewModeFrom({})).toBe('dev')
  })

  it('takes the dev mode when the config carries an unknown mode', () => {
    expect(chatViewModeFrom({ chat_view: 'fancy' })).toBe('dev')
  })

  it('keeps the mode the user just saved', () => {
    const store = useChatViewStore()
    store.setMode('compact')
    expect(store.mode).toBe('compact')
  })
})

describe('the one line a tool call shows', () => {
  it('names the tool and the file it read', () => {
    const summary = summarizeToolCall('read_file', '{"path":"/x/y.ts"}', '{"tool":"read_file"}')
    expect(summary.name).toBe('read_file')
    expect(summary.primary).toBe('/x/y.ts')
  })

  it('shows the command a shell call ran', () => {
    const summary = summarizeToolCall('command', '{"command":"ls -la"}', '{"tool":"command"}')
    expect(summary.primary).toBe('ls -la')
  })

  it('shows the pattern a search looked for', () => {
    const summary = summarizeToolCall('search', '{"pattern":"foo"}', '{"tool":"search"}')
    expect(summary.primary).toBe('foo')
  })

  it('reads the arguments when they are XML', () => {
    const summary = summarizeToolCall('command', '<command>ls</command>', '{"tool":"command"}')
    expect(summary.primary).toBe('ls')
  })

  it('marks a call that failed', () => {
    const envelope = JSON.stringify({
      tool: 'command',
      parameters: '{}',
      success: false,
      data: null,
      error: 'boom',
      v: 1,
    })
    const summary = summarizeToolCall('command', '{"command":"boom"}', envelope)
    expect(summary.status).toBe('failed')
    expect(summary.badge).toBe('failed')
  })

  it('shows the exit code of a shell call', () => {
    const envelope = JSON.stringify({
      tool: 'command',
      parameters: '{}',
      success: true,
      data: { command: 'boom', stdout: '', stderr: '', exit_code: 1 },
      error: null,
      v: 1,
    })
    const summary = summarizeToolCall('command', '{"command":"boom"}', envelope)
    expect(summary.badge).toBe('exit 1')
  })
})

describe('the compact group', () => {
  it('draws a lone call as one row, not as a group of one', () => {
    const wrapper = mountGroup([call('read_file', '{"path":"/x/y.ts"}')])
    expect(wrapper.find('[data-testid="compact-tool-group"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="compact-tool-row-name"]').text()).toBe('read_file')
    expect(wrapper.get('[data-testid="compact-tool-row-primary"]').text()).toBe('/x/y.ts')
  })

  it('folds a run of calls into one group card', () => {
    const wrapper = mountGroup([card('read_file'), card('command'), card('search')])
    expect(wrapper.get('[data-testid="compact-tool-group-count"]').text()).toBe('3 tool calls')
    expect(wrapper.findAll('[data-testid="compact-tool-row"]')).toHaveLength(0)
  })

  it('announces the failed calls of the run', () => {
    const wrapper = mountGroup([card('read_file'), card('command', { success: false })])
    expect(wrapper.get('[data-testid="compact-tool-group-failed"]').text()).toBe('1 failed')
  })

  it('shows the total duration of the run', () => {
    const wrapper = mountGroup([
      card('command', { durationMs: 40_000 }),
      card('command', { durationMs: 2_100 }),
    ])
    expect(wrapper.get('[data-testid="compact-tool-group-duration"]').text()).toBe('42.1s')
  })

  it('shows no duration when the backend recorded none', () => {
    const wrapper = mountGroup([card('command')])
    expect(wrapper.find('[data-testid="compact-tool-group-duration"]').exists()).toBe(false)
  })

  it('unfolds the run into one row per call', async () => {
    const wrapper = mountGroup([card('read_file'), card('command')])
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    expect(wrapper.findAll('[data-testid="compact-tool-row"]')).toHaveLength(2)
  })

  it('opens itself when the run holds a question for the human', () => {
    const wrapper = mountGroup([card('read_file'), card('ask_user')])
    expect(wrapper.findAll('[data-testid="compact-tool-row"]')).toHaveLength(1)
    expect(wrapper.find('[data-testid="ask-user-card"]').exists()).toBe(true)
  })
})

describe('the chat view setting', () => {
  const settings = (chat_view: 'dev' | 'compact'): PabrikGeneralSettings => ({
    notify_on_complete: false,
    notify_on_error: false,
    retry_delay_ms: 0,
    web_launch_enabled: false,
    chat_view,
  })

  it('shows the mode the settings carry', () => {
    const wrapper = mount(PabrikGeneralSection, { props: { modelValue: settings('compact') } })
    const compact = wrapper.get('[data-testid="chat-view-compact"]')
    expect(compact.attributes('aria-checked')).toBe('true')
  })

  it('marks the chat view as compact when the user picks it', async () => {
    const wrapper = mount(PabrikGeneralSection, { props: { modelValue: settings('dev') } })
    await wrapper.get('[data-testid="chat-view-compact"]').trigger('click')
    const emitted = wrapper.emitted('update:modelValue')
    expect(emitted?.[0]?.[0]).toMatchObject({ chat_view: 'compact' })
  })
})

describe('the tool result envelope', () => {
  it('carries the duration the backend recorded', () => {
    const envelope = unwrapToolOutput(
      '{"tool":"read_file","parameters":"{}","success":true,"data":{},"error":null,"v":1,"duration_ms":42}',
    )
    expect(envelope.duration_ms).toBe(42)
  })

  it('has no duration when the backend recorded none', () => {
    const envelope = unwrapToolOutput(
      '{"tool":"read_file","parameters":"{}","success":true,"data":{},"error":null,"v":1}',
    )
    expect(envelope.duration_ms).toBeUndefined()
  })
})
