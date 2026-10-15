/** Unit tests for the `useProfileDelete` composable. Mocks the
 * `api.deleteProfile` module function (NOT `global.fetch`) so we can
 * assert the composable's optimistic-update + rollback behavior in
 * isolation. */
import { ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { useProfileDelete } from '../composables/useProfileDelete'
import * as api from '../api'

// Mock the whole `../api` module so we control the return value of
// `api.deleteProfile` without hitting the network.
vi.mock('../api', () => ({
  deleteProfile: vi.fn(),
}))

const mockDeleteProfile = api.deleteProfile as unknown as ReturnType<typeof vi.fn>

interface Profile {
  name: string
  model: string
}

describe('useProfileDelete', () => {
  beforeEach(() => {
    mockDeleteProfile.mockReset()
  })

  it('removes the profile from local state immediately (optimistic)', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteProfile.mockResolvedValueOnce({
      success: true,
      profile_name: 'alpha',
      active_profile_was_cleared: true,
    })

    const { deleteProfile } = useProfileDelete(profiles, active, onSuccess, onError)
    await deleteProfile('alpha')

    expect(profiles.value.map((p) => p.name)).toEqual(['beta'])
    expect(active.value).toBeNull()
    expect(mockDeleteProfile).toHaveBeenCalledWith('alpha')
    expect(onSuccess).toHaveBeenCalledTimes(1)
    expect(onError).not.toHaveBeenCalled()
  })

  it('rolls back local state when the API call throws', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteProfile.mockRejectedValueOnce(new Error('HTTP 500'))

    const { deleteProfile } = useProfileDelete(profiles, active, onSuccess, onError)
    await expect(deleteProfile('alpha')).rejects.toThrow('HTTP 500')

    // Rolled back: alpha is back, active is restored.
    expect(profiles.value.map((p) => p.name)).toEqual(['alpha', 'beta'])
    expect(active.value).toBe('alpha')
    expect(onSuccess).not.toHaveBeenCalled()
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.calls[0]![0]).toMatch(/Failed to delete profile.*HTTP 500/)
  })

  it('preserves active_profile when deleting a non-active profile', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    mockDeleteProfile.mockResolvedValueOnce({
      success: true,
      profile_name: 'beta',
      active_profile_was_cleared: false,
    })

    const { deleteProfile } = useProfileDelete(profiles, active)
    await deleteProfile('beta')

    expect(profiles.value.map((p) => p.name)).toEqual(['alpha'])
    expect(active.value).toBe('alpha')
  })

  it('reports isDeleting=true during the in-flight call and false after', async () => {
    const profiles = ref<Profile[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    let resolveApi!: (v: unknown) => void
    mockDeleteProfile.mockReturnValueOnce(
      new Promise((r) => {
        resolveApi = r
      }),
    )

    const { deleteProfile, isDeleting } = useProfileDelete(profiles, active)
    const p = deleteProfile('alpha')

    // Optimistic update happened, isDeleting is true.
    expect(profiles.value).toEqual([])
    expect(isDeleting.value).toBe(true)

    resolveApi({ success: true, profile_name: 'alpha', active_profile_was_cleared: false })
    await p

    expect(isDeleting.value).toBe(false)
  })

  it('emits a friendly "not found" message on HTTP 404', async () => {
    const profiles = ref<Profile[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    const onError = vi.fn()
    mockDeleteProfile.mockRejectedValueOnce(new Error('HTTP 404'))

    const { deleteProfile } = useProfileDelete(profiles, active, undefined, onError)
    await expect(deleteProfile('alpha')).rejects.toThrow('HTTP 404')

    expect(onError.mock.calls[0]![0]).toMatch(/not found/i)
  })

  it('does nothing when isDeleting is already true (prevents concurrent deletes)', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>(null)
    let resolveFirst!: (v: unknown) => void
    mockDeleteProfile.mockReturnValueOnce(
      new Promise((r) => {
        resolveFirst = r
      }),
    )

    const { deleteProfile } = useProfileDelete(profiles, active)
    const first = deleteProfile('alpha')
    // Second call while first is in flight — should be a no-op.
    await deleteProfile('beta')

    expect(mockDeleteProfile).toHaveBeenCalledTimes(1)
    expect(mockDeleteProfile).toHaveBeenCalledWith('alpha')

    resolveFirst({ success: true, profile_name: 'alpha', active_profile_was_cleared: false })
    await first
  })
})
