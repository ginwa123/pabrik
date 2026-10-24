import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import AccountSecuritySection from '../components/pabrik/AccountSecuritySection.vue'
import { ApiError } from '../api'

const { mockChangePassword, mockGetAuthMeCached } = vi.hoisted(() => ({
  mockChangePassword: vi.fn(),
  mockGetAuthMeCached: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    changePassword: (...args: unknown[]) => mockChangePassword(...args),
  }
})

vi.mock('../helpers/authMe', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../helpers/authMe')>()
  return { ...actual, getAuthMeCached: () => mockGetAuthMeCached() }
})

const AUTH_ON = {
  status: 200,
  data: { authenticated: true, auth_enabled: true, user: { id: 'u1' } },
  fromCache: false,
}

function okMe() {
  return AUTH_ON
}

async function mountSection(): Promise<VueWrapper> {
  const wrapper = mount(AccountSecuritySection)
  await flushPromises()
  return wrapper
}

async function fill(
  wrapper: VueWrapper,
  fields: { current?: string; next?: string; confirm?: string },
): Promise<void> {
  if (fields.current !== undefined) {
    await wrapper.find('[data-testid="input-current-password"]').setValue(fields.current)
  }
  if (fields.next !== undefined) {
    await wrapper.find('[data-testid="input-new-password"]').setValue(fields.next)
  }
  if (fields.confirm !== undefined) {
    await wrapper.find('[data-testid="input-confirm-password"]').setValue(fields.confirm)
  }
}

function submitButton(wrapper: VueWrapper) {
  return wrapper.find('[data-testid="change-password-submit"]')
}

describe('AccountSecuritySection', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    mockChangePassword.mockReset()
    mockGetAuthMeCached.mockReset()
    mockGetAuthMeCached.mockImplementation(okMe)
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('keeps Change password disabled until all three fields are valid', async () => {
    wrapper = await mountSection()
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()

    await fill(wrapper, { current: 'old-password', next: 'new-password-1' })
    // Confirmation still empty.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()

    await fill(wrapper, { confirm: 'new-password-1' })
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined()
  })

  it('says how many characters a short new password is still missing', async () => {
    wrapper = await mountSection()
    await fill(wrapper, { current: 'old-password', next: 'abc' })

    expect(wrapper.find('[data-testid="error-new-password"]').text()).toContain('5 more characters')
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()
  })

  it('refuses a new password longer than bcrypt can hash rather than truncating it', async () => {
    wrapper = await mountSection()
    await fill(wrapper, { current: 'old-password', next: 'x'.repeat(73), confirm: 'x'.repeat(73) })

    expect(wrapper.find('[data-testid="error-new-password"]').text()).toContain('72')
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()
  })

  it('refuses a new password that is the current one', async () => {
    wrapper = await mountSection()
    await fill(wrapper, {
      current: 'old-password',
      next: 'old-password',
      confirm: 'old-password',
    })

    expect(wrapper.find('[data-testid="error-new-password"]').text()).toContain('already use')
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()
  })

  it('reports a mismatched confirmation and sends nothing', async () => {
    wrapper = await mountSection()
    await fill(wrapper, {
      current: 'old-password',
      next: 'new-password-1',
      confirm: 'new-password-2',
    })

    expect(wrapper.find('[data-testid="error-confirm-password"]').text()).toContain('do not match')
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined()
    expect(mockChangePassword).not.toHaveBeenCalled()
  })

  it('clears the form and names the devices a successful change signed out', async () => {
    mockChangePassword.mockResolvedValue({ ok: true, sessions_revoked: 2 })
    wrapper = await mountSection()
    await fill(wrapper, {
      current: 'old-password',
      next: 'new-password-1',
      confirm: 'new-password-1',
    })

    await wrapper.find('[data-testid="change-password-form"]').trigger('submit')
    await flushPromises()

    expect(mockChangePassword).toHaveBeenCalledWith({
      current_password: 'old-password',
      new_password: 'new-password-1',
    })
    expect(wrapper.find('[data-testid="change-password-success"]').text()).toContain(
      '2 other devices were signed out',
    )
    const input = wrapper.find('[data-testid="input-new-password"]').element as HTMLInputElement
    expect(input.value).toBe('')
    expect(wrapper.emitted('notification')?.[0]).toEqual(['Password changed', 'success'])
  })

  it('shows a rejected current password in the form and keeps what was typed', async () => {
    mockChangePassword.mockRejectedValue(
      new ApiError(403, 'Forbidden', JSON.stringify({ error: 'WrongCurrentPassword' })),
    )
    wrapper = await mountSection()
    await fill(wrapper, {
      current: 'not-my-password',
      next: 'new-password-1',
      confirm: 'new-password-1',
    })

    await wrapper.find('[data-testid="change-password-form"]').trigger('submit')
    await flushPromises()

    expect(wrapper.find('[data-testid="change-password-error"]').text()).toContain(
      'not your current password',
    )
    const current = wrapper.find('[data-testid="input-current-password"]')
      .element as HTMLInputElement
    expect(current.value).toBe('not-my-password')
    expect(wrapper.emitted('notification')).toBeUndefined()
  })

  it('drops the server rejection as soon as the user edits the form', async () => {
    mockChangePassword.mockRejectedValue(
      new ApiError(403, 'Forbidden', JSON.stringify({ error: 'WrongCurrentPassword' })),
    )
    wrapper = await mountSection()
    await fill(wrapper, {
      current: 'not-my-password',
      next: 'new-password-1',
      confirm: 'new-password-1',
    })
    await wrapper.find('[data-testid="change-password-form"]').trigger('submit')
    await flushPromises()
    expect(wrapper.find('[data-testid="change-password-error"]').exists()).toBe(true)

    await fill(wrapper, { current: 'not-my-password-' })

    expect(wrapper.find('[data-testid="change-password-error"]').exists()).toBe(false)
  })

  it('offers a notice instead of a form when the server runs without accounts', async () => {
    mockGetAuthMeCached.mockResolvedValue({
      status: 200,
      data: { authenticated: false, auth_enabled: false },
      fromCache: false,
    })
    wrapper = await mountSection()

    expect(wrapper.find('[data-testid="security-auth-disabled"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="change-password-form"]').exists()).toBe(false)
  })

  it('reveals a password on request and masks it again', async () => {
    const mounted = await mountSection()
    wrapper = mounted
    const input = () => mounted.find('[data-testid="input-new-password"]')
    expect(input().attributes('type')).toBe('password')

    await wrapper.find('[data-testid="toggle-new-password"]').trigger('click')
    expect(input().attributes('type')).toBe('text')

    await wrapper.find('[data-testid="toggle-new-password"]').trigger('click')
    expect(input().attributes('type')).toBe('password')
  })
})
