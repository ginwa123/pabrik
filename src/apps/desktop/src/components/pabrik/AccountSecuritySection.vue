<script setup lang="ts">
/** AccountSecuritySection — Settings → User → Security. Lets the signed-in
 * user rotate their own password, with the current one as proof of ownership
 * and an honest account of which other devices the change signs out. */
import { computed, onMounted, ref } from 'vue'
import { Cause, Effect, Exit, Option } from 'effect'
import {
  CHANGE_PASSWORD_MAX_LENGTH,
  CHANGE_PASSWORD_MIN_LENGTH,
  changePassword,
  changePasswordErrorCode,
} from '../../api'
import { getAuthMeCached } from '../../helpers/authMe'
import { runEffectExit } from '../../helpers/effectRuntime'
import UiIcon from '../ui/UiIcon.vue'
import PasswordField from './PasswordField.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const currentPassword = ref('')
const newPassword = ref('')
const confirmPassword = ref('')
const busy = ref(false)
const serverError = ref<string | null>(null)
const lastRevoked = ref<number | null>(null)
/** null = not resolved yet (render the form); false = no accounts on this box. */
const authEnabled = ref<boolean | null>(null)

const SERVER_MESSAGES: Record<string, string> = {
  WrongCurrentPassword: 'That is not your current password.',
  PasswordTooShort: `The new password must be at least ${CHANGE_PASSWORD_MIN_LENGTH} characters.`,
  PasswordTooLong: `The new password must be at most ${CHANGE_PASSWORD_MAX_LENGTH} characters.`,
  PasswordUnchanged: 'The new password must differ from the current one.',
  AuthDisabled: 'This server runs without accounts, so there is no password to change.',
  Unauthenticated: 'Your session expired. Sign in again, then retry.',
}

function messageFor(err: unknown): string {
  const code = changePasswordErrorCode(err)
  return (code !== null ? SERVER_MESSAGES[code] : undefined) ?? 'Could not change the password.'
}

/** Shown only once the user has typed something, so an empty form is quiet. */
const newPasswordError = computed<string | null>(() => {
  const next = newPassword.value
  if (next.length === 0) return null
  if (next.length < CHANGE_PASSWORD_MIN_LENGTH) {
    const missing = CHANGE_PASSWORD_MIN_LENGTH - next.length
    return `Too short — ${missing} more ${missing === 1 ? 'character' : 'characters'}.`
  }
  if (next.length > CHANGE_PASSWORD_MAX_LENGTH) {
    return `Too long — ${CHANGE_PASSWORD_MAX_LENGTH} characters is the maximum.`
  }
  if (next === currentPassword.value) return 'That is the password you already use.'
  return null
})

const confirmError = computed<string | null>(() =>
  confirmPassword.value.length > 0 && confirmPassword.value !== newPassword.value
    ? 'The two new passwords do not match.'
    : null,
)

const canSubmit = computed<boolean>(
  () =>
    !busy.value &&
    authEnabled.value !== false &&
    currentPassword.value.length > 0 &&
    newPassword.value.length >= CHANGE_PASSWORD_MIN_LENGTH &&
    newPassword.value.length <= CHANGE_PASSWORD_MAX_LENGTH &&
    newPassword.value !== currentPassword.value &&
    confirmPassword.value === newPassword.value,
)

const successNote = computed<string>(() => {
  const revoked = lastRevoked.value
  if (revoked === null) return ''
  if (revoked === 0) return 'Password changed. No other device was signed in.'
  if (revoked === 1) return 'Password changed. One other device was signed out.'
  return `Password changed. ${revoked} other devices were signed out.`
})

/** The success line disappears as soon as the user starts a second change. */
const showSuccess = computed<boolean>(
  () =>
    lastRevoked.value !== null &&
    currentPassword.value.length === 0 &&
    newPassword.value.length === 0 &&
    confirmPassword.value.length === 0,
)

onMounted(async () => {
  const me = await getAuthMeCached()
  authEnabled.value = me.data ? me.data.auth_enabled : null
})

async function submit(): Promise<void> {
  if (!canSubmit.value) return
  busy.value = true
  serverError.value = null
  // The failure rides the Effect's error channel as the sentence to show, so
  // "could not change it" cannot be mistaken for a success anywhere below.
  const exit = await runEffectExit(
    Effect.tryPromise({
      try: () =>
        changePassword({
          current_password: currentPassword.value,
          new_password: newPassword.value,
        }),
      catch: (cause) => messageFor(cause),
    }),
    'account-security.change-password',
  )
  busy.value = false

  if (Exit.isFailure(exit)) {
    serverError.value = Option.getOrElse(
      Cause.failureOption(exit.cause),
      () => 'Could not change the password.',
    )
    return
  }

  lastRevoked.value = exit.value.sessions_revoked
  currentPassword.value = ''
  newPassword.value = ''
  confirmPassword.value = ''
  emit('notification', 'Password changed', 'success')
}
</script>

<template>
  <div class="space-y-6" data-testid="account-security-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Security</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        The password you sign in with. Changing it signs out every other device.
      </p>
    </div>

    <div
      v-if="authEnabled === false"
      class="rounded-lg p-5 flex items-start gap-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      data-testid="security-auth-disabled"
    >
      <UiIcon name="lock" size-class="w-4 h-4" />
      <div class="flex-1 min-w-0">
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Sign-in is off</h3>
        <p class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
          This server runs without accounts, so there is no password to change.
        </p>
      </div>
    </div>

    <form
      v-else
      class="rounded-lg p-5 space-y-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      data-testid="change-password-form"
      @submit.prevent="submit"
      @input="serverError = null"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="lock" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Password</h3>
      </div>

      <PasswordField
        id="current-password"
        v-model="currentPassword"
        label="Current password"
        autocomplete="current-password"
        :disabled="busy"
      />
      <PasswordField
        id="new-password"
        v-model="newPassword"
        label="New password"
        autocomplete="new-password"
        :hint="`${CHANGE_PASSWORD_MIN_LENGTH} to ${CHANGE_PASSWORD_MAX_LENGTH} characters.`"
        :error="newPasswordError"
        :disabled="busy"
      />
      <PasswordField
        id="confirm-password"
        v-model="confirmPassword"
        label="Confirm new password"
        autocomplete="new-password"
        :error="confirmError"
        :disabled="busy"
      />

      <p
        v-if="serverError"
        role="alert"
        data-testid="change-password-error"
        class="text-dense"
        style="color: var(--color-red)"
      >
        {{ serverError }}
      </p>
      <p
        v-if="showSuccess"
        data-testid="change-password-success"
        class="text-dense"
        style="color: var(--color-green)"
      >
        {{ successNote }}
      </p>

      <div class="flex items-center gap-3">
        <button
          type="submit"
          :disabled="!canSubmit"
          data-testid="change-password-submit"
          class="px-3 h-8 rounded-md text-dense font-medium"
          :style="
            canSubmit
              ? 'background-color: var(--color-violet); color: white;'
              : 'background-color: var(--semantic-content-bg); color: var(--semantic-text-muted); cursor: not-allowed;'
          "
        >
          {{ busy ? 'Saving…' : 'Change password' }}
        </button>
        <span class="text-dense" style="color: var(--semantic-text-muted)">
          You stay signed in here.
        </span>
      </div>
    </form>
  </div>
</template>
