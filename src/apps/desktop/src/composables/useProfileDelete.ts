/** useProfileDelete — optimistic-update + rollback for LLM profile deletion. On
 * `deleteProfile(name)`: 1. Snapshot the current `profiles` and `activeProfile` so we can roll back
 * if the API call fails. 2. */
import { ref, type Ref } from 'vue'

import { deleteProfile as apiDeleteProfile, type ProfileDeleteResponse } from '../api'

export function useProfileDelete<TProfile extends { name: string }>(
  profiles: Ref<TProfile[]>,
  activeProfile: Ref<string | null>,
  onSuccess?: (message: string) => void,
  onError?: (message: string) => void,
) {
  const isDeleting = ref(false)

  const deleteProfile = async (name: string): Promise<ProfileDeleteResponse> => {
    if (isDeleting.value) {
      // Prevent concurrent deletes from racing the rollback logic.
      // Silently ignore — the UI button is disabled, so this is a
      // belt-and-suspenders guard for programmatic callers.
      return Promise.resolve({
        success: false,
        profile_name: name,
        error_message: 'Another delete is already in progress',
      })
    }

    // Snapshot for rollback.
    const previousProfiles = profiles.value.slice()
    const previousActive = activeProfile.value

    // Optimistic local update (preserves the user's exact snippet at
    // PabrikConfigEditor.vue:290-295 from the original spec).
    isDeleting.value = true
    profiles.value = profiles.value.filter((p) => p.name !== name)
    if (activeProfile.value === name) {
      activeProfile.value = null
    }

    try {
      const result = await apiDeleteProfile(name)
      onSuccess?.(`Profile "${name}" deleted`)
      return result
    } catch (err) {
      // Rollback.
      profiles.value = previousProfiles
      activeProfile.value = previousActive
      onError?.(formatErrorMessage(name, err))
      throw err
    } finally {
      isDeleting.value = false
    }
  }

  return { deleteProfile, isDeleting }
}

function formatErrorMessage(name: string, err: unknown): string {
  if (!(err instanceof Error)) {
    return `Failed to delete profile "${name}"`
  }
  // 404 gets a friendlier message because it's a common case (profile already deleted in another
  // tab, race with another user's delete). All other errors fall through to the generic format
  // which includes the original error message for debuggability.
  if (err.message.includes('HTTP 404')) {
    return `Profile "${name}" not found on server (it may have been already deleted)`
  }
  return `Failed to delete profile "${name}": ${err.message}`
}
