/** Tests for PabrikRuntimeSection.vue — the Runtime tab in WORKSPACE settings. The behaviour under
 * test is the seconds↔milliseconds conversion and the [0, 60 000] clamp the backend also enforces,
 * plus the agent auto-compaction switch. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PabrikRuntimeSection, {
  type PabrikRuntimeSettings,
} from '../components/pabrik/PabrikRuntimeSection.vue'

function mountSection(settings: Partial<PabrikRuntimeSettings>) {
  return mount(PabrikRuntimeSection, {
    props: {
      modelValue: {
        retry_delay_ms: 0,
        llm_read_timeout_ms: 900_000,
        agent_auto_compaction: true,
        ...settings,
      },
    },
  })
}

function emittedMs(wrapper: ReturnType<typeof mountSection>, index = 0): number {
  const payload = wrapper.emitted('update:modelValue')?.[index]?.[0] as PabrikRuntimeSettings
  return payload.retry_delay_ms
}

function emittedReadTimeoutMs(wrapper: ReturnType<typeof mountSection>, index = 0): number {
  const payload = wrapper.emitted('update:modelValue')?.[index]?.[0] as PabrikRuntimeSettings
  return payload.llm_read_timeout_ms
}

describe('PabrikRuntimeSection', () => {
  it('shows the stored delay in seconds, and the raw milliseconds underneath', () => {
    const wrapper = mountSection({ retry_delay_ms: 15000 })
    expect(
      Number(
        (wrapper.find('[data-testid="input-retry-delay-seconds"]').element as HTMLInputElement)
          .value,
      ),
    ).toBe(15)
    expect(wrapper.find('[data-testid="retry-delay-ms-readout"]').text()).toContain('15000 ms')
  })

  it('a delay under a second still renders as 0 seconds rather than a fraction', () => {
    const wrapper = mountSection({ retry_delay_ms: 400 })
    expect(
      Number(
        (wrapper.find('[data-testid="input-retry-delay-seconds"]').element as HTMLInputElement)
          .value,
      ),
    ).toBe(0)
    expect(wrapper.find('[data-testid="retry-delay-ms-readout"]').text()).toContain('400 ms')
  })

  it('typing a new delay in seconds emits the millisecond value', async () => {
    const wrapper = mountSection({ retry_delay_ms: 0 })
    await wrapper.find('[data-testid="input-retry-delay-seconds"]').setValue('5')
    expect(emittedMs(wrapper)).toBe(5000)
  })

  it('clamps a delay above 60 seconds to 60 000 ms', async () => {
    const wrapper = mountSection({ retry_delay_ms: 0 })
    await wrapper.find('[data-testid="input-retry-delay-seconds"]').setValue('999')
    expect(emittedMs(wrapper)).toBe(60_000)
  })

  it('clamps a negative delay to 0 ms', async () => {
    const wrapper = mountSection({ retry_delay_ms: 30000 })
    await wrapper.find('[data-testid="input-retry-delay-seconds"]').setValue('-5')
    expect(emittedMs(wrapper)).toBe(0)
  })

  it('an emptied input means "retry immediately", not a cleared field', async () => {
    const wrapper = mountSection({ retry_delay_ms: 5000 })
    await wrapper.find('[data-testid="input-retry-delay-seconds"]').setValue('')
    expect(emittedMs(wrapper)).toBe(0)
  })

  it('shows the streaming deadline in seconds, and the raw milliseconds underneath', () => {
    const wrapper = mountSection({ llm_read_timeout_ms: 1_800_000 })
    expect(
      Number(
        (wrapper.find('[data-testid="input-read-timeout-seconds"]').element as HTMLInputElement)
          .value,
      ),
    ).toBe(1800)
    expect(wrapper.find('[data-testid="read-timeout-ms-readout"]').text()).toContain('1800000 ms')
  })

  it('typing a new streaming deadline in seconds emits the millisecond value', async () => {
    const wrapper = mountSection({ llm_read_timeout_ms: 900_000 })
    await wrapper.find('[data-testid="input-read-timeout-seconds"]').setValue('600')
    expect(emittedReadTimeoutMs(wrapper)).toBe(600_000)
  })

  it('clamps a streaming deadline above 30 minutes to 1 800 000 ms', async () => {
    const wrapper = mountSection({ llm_read_timeout_ms: 900_000 })
    await wrapper.find('[data-testid="input-read-timeout-seconds"]').setValue('99999')
    expect(emittedReadTimeoutMs(wrapper)).toBe(1_800_000)
  })

  it('clamps a streaming deadline below one second to 1 000 ms', async () => {
    const wrapper = mountSection({ llm_read_timeout_ms: 900_000 })
    await wrapper.find('[data-testid="input-read-timeout-seconds"]').setValue('0')
    expect(emittedReadTimeoutMs(wrapper)).toBe(1_000)
  })

  it('an emptied streaming deadline falls back to the 15-minute default', async () => {
    const wrapper = mountSection({ llm_read_timeout_ms: 60_000 })
    await wrapper.find('[data-testid="input-read-timeout-seconds"]').setValue('')
    expect(emittedReadTimeoutMs(wrapper)).toBe(900_000)
  })

  it('renders the agent auto-compaction switch from the stored value', () => {
    const on = mountSection({ agent_auto_compaction: true })
    expect(
      (on.find('[data-testid="toggle-agent-auto-compaction"]').element as HTMLInputElement).checked,
    ).toBe(true)

    const off = mountSection({ agent_auto_compaction: false })
    expect(
      (off.find('[data-testid="toggle-agent-auto-compaction"]').element as HTMLInputElement)
        .checked,
    ).toBe(false)
  })

  it('clicking the agent auto-compaction switch emits the flipped boolean', async () => {
    const wrapper = mountSection({ agent_auto_compaction: true })
    await wrapper.find('[data-testid="toggle-agent-auto-compaction"]').setValue(false)

    const payload = wrapper.emitted('update:modelValue')?.[0]?.[0] as PabrikRuntimeSettings
    expect(payload.agent_auto_compaction).toBe(false)
    // The siblings ride along untouched: the toggle must not reset a delay the
    // user set in the other card.
    expect(payload.retry_delay_ms).toBe(0)
    expect(payload.llm_read_timeout_ms).toBe(900_000)
  })
})
