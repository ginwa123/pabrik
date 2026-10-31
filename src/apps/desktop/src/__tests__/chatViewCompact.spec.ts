import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'

import PabrikGeneralSection, {
  type PabrikGeneralSettings,
} from '../components/pabrik/PabrikGeneralSection.vue'
import CompactToolGroup from '../components/tool_outputs/compact/CompactToolGroup.vue'
import {
  buildCompactChains,
  foldedNarrationMessageIds,
  foldedThoughtMessageIds,
  type ChainGroup,
  type CompactChainItem,
} from '../components/tool_outputs/compact/chain'
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

/** The chain items a plain run of calls makes up. */
function itemsOf(cards: ToolCardData[]): CompactChainItem[] {
  return cards.map((card) => ({ kind: 'tool', key: card.expandKey, card }))
}

function thought(messageId: string, text: string): CompactChainItem {
  return { kind: 'thought', key: `thought-${messageId}`, messageId, text }
}

function mountGroup(items: CompactChainItem[]) {
  return mount(CompactToolGroup, {
    props: { items, cwd: '/tmp', sessionId: 'session-1' },
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
    const wrapper = mountGroup(itemsOf([call('read_file', '{"path":"/x/y.ts"}')]))
    expect(wrapper.find('[data-testid="compact-tool-group"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="compact-tool-row-name"]').text()).toBe('read_file')
    expect(wrapper.get('[data-testid="compact-tool-row-primary"]').text()).toBe('/x/y.ts')
  })

  it('folds a run of calls into one group card', () => {
    const wrapper = mountGroup(itemsOf([card('read_file'), card('command'), card('search')]))
    expect(wrapper.get('[data-testid="compact-tool-group-count"]').text()).toBe('3 tool calls')
    expect(wrapper.findAll('[data-testid="compact-tool-row"]')).toHaveLength(0)
  })

  it('announces the failed calls of the run', () => {
    const wrapper = mountGroup(itemsOf([card('read_file'), card('command', { success: false })]))
    expect(wrapper.get('[data-testid="compact-tool-group-failed"]').text()).toBe('1 failed')
  })

  it('shows the total duration of the run', () => {
    const wrapper = mountGroup(
      itemsOf([card('command', { durationMs: 40_000 }), card('command', { durationMs: 2_100 })]),
    )
    expect(wrapper.get('[data-testid="compact-tool-group-duration"]').text()).toBe('42.1s')
  })

  it('shows no duration when the backend recorded none', () => {
    const wrapper = mountGroup(itemsOf([card('command')]))
    expect(wrapper.find('[data-testid="compact-tool-group-duration"]').exists()).toBe(false)
  })

  it('unfolds the run into one row per call', async () => {
    const wrapper = mountGroup(itemsOf([card('read_file'), card('command')]))
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    expect(wrapper.findAll('[data-testid="compact-tool-row"]')).toHaveLength(2)
  })

})

/** A tool-call message of a transcript, as the chain builder sees it. */
function callCard(messageId: string): ToolCardData {
  return { ...card('command'), expandKey: messageId }
}

describe('the chain one agent turn folds into', () => {
  const group = (
    role: string,
    messages: {
      id: string
      content?: string
      reasoning_content?: string
      finish_reason?: string
    }[],
  ): ChainGroup => ({ role, messages })
  const cardsOf = (g: ChainGroup): ToolCardData[] => g.messages.map((m) => callCard(m.id))
  const kinds = (items: CompactChainItem[]): string[] => items.map((item) => item.kind)

  const turn = (): ChainGroup[] => [
    group('user', [{ id: 'u1' }]),
    group('assistant', [
      { id: 'a1', reasoning_content: 'read it first', finish_reason: 'tool_calls' },
    ]),
    group('tool', [{ id: 't1' }]),
    group('assistant', [
      { id: 'a2', reasoning_content: 'now query it', finish_reason: 'tool_calls' },
    ]),
    group('tool', [{ id: 't2' }]),
    group('assistant', [
      { id: 'a3', reasoning_content: 'totals are wrong', finish_reason: 'stop' },
    ]),
  ]

  it('folds the thoughts between the calls into the same chain as the calls', () => {
    const chains = buildCompactChains(turn(), cardsOf)
    expect([...chains.keys()]).toEqual([2])
    expect(kinds(chains.get(2) ?? [])).toEqual(['thought', 'tool', 'thought', 'tool', 'thought'])
  })

  it('keeps the chain of a turn split at the assistant message that stops', () => {
    const chains = buildCompactChains(
      [
        group('tool', [{ id: 't1' }]),
        group('assistant', [{ id: 'a1', reasoning_content: 'done', finish_reason: 'stop' }]),
        group('user', [{ id: 'u2' }]),
        group('tool', [{ id: 't2' }]),
        group('assistant', [{ id: 'a2', reasoning_content: 'done too', finish_reason: 'stop' }]),
      ],
      cardsOf,
    )
    expect([...chains.keys()]).toEqual([0, 3])
    expect(chains.get(0)?.map((item) => item.key)).toEqual(['t1', 'thought-a1'])
    expect(chains.get(3)?.map((item) => item.key)).toEqual(['t2', 'thought-a2'])
  })

  it('makes no chain for a turn that called nothing', () => {
    const chains = buildCompactChains(
      [
        group('user', [{ id: 'u1' }]),
        group('assistant', [
          { id: 'a1', reasoning_content: 'just thinking', finish_reason: 'stop' },
        ]),
      ],
      cardsOf,
    )
    expect(chains.size).toBe(0)
  })

  it('names the thoughts a chain already draws', () => {
    const folded = foldedThoughtMessageIds(buildCompactChains(turn(), cardsOf))
    expect([...folded].sort()).toEqual(['a1', 'a2', 'a3'])
  })

  const narrated = (): ChainGroup[] => [
    group('user', [{ id: 'u1' }]),
    group('assistant', [
      { id: 'n1', content: 'I will read the schema first.', finish_reason: 'tool_calls' },
    ]),
    group('tool', [{ id: 't1' }]),
    group('assistant', [
      { id: 'n2', content: 'Now let me add up the totals.', finish_reason: 'tool_calls' },
    ]),
    group('tool', [{ id: 't2' }]),
    group('assistant', [
      { id: 'n3', content: 'The tax column is never filled.', finish_reason: 'stop' },
    ]),
  ]

  it('folds the narration on the way to a call into the chain, in the order it happened', () => {
    const chains = buildCompactChains(narrated(), cardsOf)
    expect([...chains.keys()]).toEqual([2])
    expect(kinds(chains.get(2) ?? [])).toEqual(['narration', 'tool', 'narration', 'tool'])
  })

  it('names the narration a chain already draws but not the answer that ends the turn', () => {
    const folded = foldedNarrationMessageIds(buildCompactChains(narrated(), cardsOf))
    expect([...folded].sort()).toEqual(['n1', 'n2'])
  })

  it('keeps the narration of a turn that called nothing in the transcript', () => {
    const chains = buildCompactChains(
      [
        group('user', [{ id: 'u1' }]),
        group('assistant', [{ id: 'n1', content: 'Just an answer.', finish_reason: 'stop' }]),
      ],
      cardsOf,
    )
    expect(chains.size).toBe(0)
    expect(foldedNarrationMessageIds(chains).size).toBe(0)
  })

  it('ends the turn at a message that awaits the user', () => {
    const chains = buildCompactChains(
      [
        group('tool', [{ id: 't1' }]),
        group('assistant', [
          { id: 'n1', content: 'Anything else?', finish_reason: 'awaiting_user' },
        ]),
        group('tool', [{ id: 't2' }]),
        group('assistant', [{ id: 'n2', content: 'Second answer.', finish_reason: 'stop' }]),
      ],
      cardsOf,
    )
    expect([...chains.keys()]).toEqual([0, 2])
    expect(foldedNarrationMessageIds(chains).size).toBe(0)
  })

  it('keeps a presented file out of the chain', () => {
    const chains = buildCompactChains(
      [
        group('user', [{ id: 'u1' }]),
        group('tool', [{ id: 't1' }, { id: 't2' }]),
        group('assistant', [{ id: 'n1', content: 'Here it is.', finish_reason: 'stop' }]),
      ],
      (g) => g.messages.map((m) => (m.id === 't2' ? card('present_files') : callCard(m.id))),
    )
    expect(chains.get(1)?.map((item) => item.key)).toEqual(['t1'])
  })
})

describe('the thoughts inside a group card', () => {
  it('stays shut on a run of calls, thoughts and all', () => {
    const wrapper = mountGroup([
      thought('a1', 'read it first'),
      ...itemsOf([card('read_file')]),
      thought('a2', 'now query it'),
      ...itemsOf([card('command')]),
    ])
    expect(wrapper.find('[data-testid="compact-thought-row"]').exists()).toBe(false)
  })

  it('draws the thoughts between the calls, in the order they happened', async () => {
    const wrapper = mountGroup([
      thought('a1', 'read it first'),
      ...itemsOf([card('read_file')]),
      thought('a2', 'now query it'),
      ...itemsOf([card('command')]),
    ])
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    const rows = wrapper.findAll(
      '[data-testid="compact-thought-row"], [data-testid="compact-tool-row"]',
    )
    expect(rows.map((row) => row.attributes('data-testid'))).toEqual([
      'compact-thought-row',
      'compact-tool-row',
      'compact-thought-row',
      'compact-tool-row',
    ])
  })

  it('opens one thought to the text the model wrote', async () => {
    const wrapper = mountGroup([
      thought('a1', 'The schema lives in main.go.\nThen the query.'),
      ...itemsOf([card('read_file'), card('command')]),
    ])
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    expect(wrapper.get('[data-testid="compact-thought-preview"]').text()).toBe(
      'The schema lives in main.go.',
    )
    await wrapper.get('[data-testid="compact-thought-head"]').trigger('click')
    expect(wrapper.get('[data-testid="compact-thought-body"]').text()).toBe(
      'The schema lives in main.go.\nThen the query.',
    )
  })
})

describe('the narration inside a group card', () => {
  const narration = (messageId: string, text: string): CompactChainItem => ({
    kind: 'narration',
    key: `narration-${messageId}`,
    messageId,
    text,
  })

  it('stays shut on a run of calls, narration and all', () => {
    const wrapper = mountGroup([
      narration('n1', 'I will read the schema first.'),
      ...itemsOf([card('read_file')]),
      narration('n2', 'Now let me add up the totals.'),
      ...itemsOf([card('command')]),
    ])
    expect(wrapper.find('[data-testid="compact-narration-row"]').exists()).toBe(false)
  })

  it('marks the narration apart from the thoughts when the card is opened', async () => {
    const wrapper = mountGroup([
      thought('a1', 'The schema lives in main.go.'),
      narration('n1', 'I will read the schema first.'),
      ...itemsOf([card('read_file'), card('command')]),
    ])
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    expect(wrapper.get('[data-testid="compact-narration-label"]').text()).toBe('said')
    expect(wrapper.get('[data-testid="compact-narration-preview"]').text()).toBe(
      'I will read the schema first.',
    )
    expect(wrapper.get('[data-testid="compact-thought-label"]').text()).toBe('thought')
  })

  it('opens one narration line to the text the model wrote', async () => {
    const wrapper = mountGroup([
      narration('n1', 'I will read the schema first.\nThen the totals.'),
      ...itemsOf([card('read_file'), card('command')]),
    ])
    await wrapper.get('[data-testid="compact-tool-group-header"]').trigger('click')
    await wrapper.get('[data-testid="compact-narration-head"]').trigger('click')
    expect(wrapper.get('[data-testid="compact-narration-body"]').text()).toBe(
      'I will read the schema first.\nThen the totals.',
    )
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
