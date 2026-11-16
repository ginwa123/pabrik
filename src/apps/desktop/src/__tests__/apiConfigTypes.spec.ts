/** Type-level tests for the `PabrikConfig` interface. */
import { describe, expect, it } from 'vitest'
import type { PabrikConfig } from '../api'

describe('PabrikConfig', () => {
  it('accepts retry_delay_ms as an optional number', () => {
    const cfg: PabrikConfig = {
      active_profile: 'work',
      retry_delay_ms: 5000,
    }
    expect(cfg.retry_delay_ms).toBe(5000)
  })

  it('allows retry_delay_ms to be omitted (defaults undefined)', () => {
    const cfg: PabrikConfig = { active_profile: 'work' }
    expect(cfg.retry_delay_ms).toBeUndefined()
  })
})