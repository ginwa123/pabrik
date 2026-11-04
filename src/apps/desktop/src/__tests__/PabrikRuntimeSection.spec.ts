/** Tests for PabrikRuntimeSection.vue — the Runtime tab in WORKSPACE settings. The behaviour under
 * test is the seconds↔milliseconds conversion and the [0, 60 000] clamp the backend also enforces. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PabrikRuntimeSection, {
  type PabrikRuntimeSettings,
} from '../components/pabrik/PabrikRuntimeSection.vue'

function mountSection(settings: PabrikRuntimeSettings) {
  return mount(PabrikRuntimeSection, { props: { modelValue: { ...settings } } })
}

function emittedMs(wrapper: ReturnType<typeof mountSection>, index = 0): number {
  const payload = wrapper.emitted('update:modelValue')?.[index]?.[0] as PabrikRuntimeSettings
  return payload.retry_delay_ms
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
})
