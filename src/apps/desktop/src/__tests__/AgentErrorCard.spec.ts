/** Tests for AgentErrorCard.vue — the dedicated renderer for agentic-loop error/retry diagnostics
 * (e.g. `[Retry 1/10] StreamInterrupted … Server said: …`). The component is purely presentational
 * (parses a string, no API calls), so no mocks are needed. */
/** Mirrors the style of `CompactionCard.spec.ts`. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import AgentErrorCard from '../components/chat/AgentErrorCard.vue'

const RETRY_MESSAGE = `[Retry 1/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.
Server said: {"error":{"message":"Provider returned error","code":429}}`

const BAIL_MESSAGE = `[Agent Pabrik System error] workflow halted after 10 consecutive retries.
Reason for last retry: StreamInterrupted (source: callDynamicAgentNew).
Server said: upstream provider rate-limited`

describe('AgentErrorCard', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the card root with the agent-error title', () => {
    wrapper = mount(AgentErrorCard, { props: { content: RETRY_MESSAGE } })
    const root = wrapper.find('[data-testid="agent-error-card"]')
    expect(root.exists()).toBe(true)
    expect(wrapper.text()).toContain('Agent error')
  })

  it('extracts the retry chip from a [Retry N/M] prefix', () => {
    wrapper = mount(AgentErrorCard, { props: { content: RETRY_MESSAGE } })
    const chip = wrapper.find('[data-testid="agent-error-retry"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toContain('1/10')
  })

  it('omits the retry chip when there is no [Retry N/M] marker', () => {
    wrapper = mount(AgentErrorCard, { props: { content: BAIL_MESSAGE } })
    expect(wrapper.find('[data-testid="agent-error-retry"]').exists()).toBe(false)
  })

  it('shows the headline with error name and source', () => {
    wrapper = mount(AgentErrorCard, { props: { content: RETRY_MESSAGE } })
    const headline = wrapper.find('[data-testid="agent-error-headline"]')
    expect(headline.exists()).toBe(true)
    expect(headline.text()).toContain('StreamInterrupted')
    expect(headline.text()).toContain('callDynamicAgentNew')
  })

  it('splits the Server said: suffix into a detail section', () => {
    wrapper = mount(AgentErrorCard, { props: { content: RETRY_MESSAGE } })
    const detail = wrapper.find('[data-testid="agent-error-detail"]')
    expect(detail.exists()).toBe(true)
    expect(detail.text()).toContain('Provider returned error')
  })

  it('renders the retry delay when present', () => {
    wrapper = mount(AgentErrorCard, { props: { content: RETRY_MESSAGE } })
    const delay = wrapper.find('[data-testid="agent-error-delay"]')
    expect(delay.exists()).toBe(true)
    expect(delay.text()).toContain('10000ms')
  })

  it('is expanded by default — detail is visible immediately', () => {
    wrapper = mount(AgentErrorCard, {
      props: { content: RETRY_MESSAGE },
      attachTo: document.body,
    })
    const detailEl = wrapper.find('[data-testid="agent-error-detail"]')
      .element as HTMLElement
    // 2026-08-25 task_1787668954023_2: detail rendered unhidden by
    // default — no toggle, no collapse interaction. The header is
    // informational; the user gets the raw server detail at a glance.
    expect(detailEl.style.display).not.toBe('none')
  })

  it('handles content without a Server said: section gracefully', () => {
    wrapper = mount(AgentErrorCard, {
      props: { content: '[Retry 2/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.' },
    })
    expect(wrapper.find('[data-testid="agent-error-detail"]').exists()).toBe(false)
    // Headline still renders.
    expect(wrapper.find('[data-testid="agent-error-headline"]').text()).toContain('StreamInterrupted')
  })
})
