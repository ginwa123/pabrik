<template>
  <div class="login-wrap">
    <form class="login-card" @submit.prevent="onSubmit">
      <h1>Welcome back</h1>
      <p v-if="authDisabled" class="muted">Authentication is disabled on this server.</p>
      <div class="field">
        <label for="login-email">Email</label>
        <input
          id="login-email"
          ref="emailInput"
          v-model="email"
          type="email"
          autocomplete="username"
          autocapitalize="off"
          spellcheck="false"
          placeholder="you@example.com"
          required
          :disabled="busy"
        />
      </div>
      <div class="field">
        <label for="login-password">Password</label>
        <div class="input-shell">
          <input
            id="login-password"
            v-model="password"
            :type="showPassword ? 'text' : 'password'"
            autocomplete="current-password"
            placeholder="••••••••"
            required
            :disabled="busy"
          />
          <button
            type="button"
            class="reveal-btn"
            :disabled="busy"
            :aria-label="showPassword ? 'Hide password' : 'Show password'"
            :aria-pressed="showPassword"
            @click="showPassword = !showPassword"
          >
            <UiIcon :name="showPassword ? 'lock-open' : 'lock'" :size="15" />
          </button>
        </div>
      </div>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
      <button type="submit" class="primary-btn" :disabled="busy || !canSubmit">
        {{ busy ? 'Signing in…' : 'Sign in' }}
      </button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getAuthMeCached, invalidateAuthMe } from '../helpers/authMe'
import { useSseBus } from '../helpers/sseBus'
import UiIcon from '../components/ui/UiIcon.vue'

const route = useRoute()
const router = useRouter()
const email = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)
const authDisabled = ref(false)
const showPassword = ref(false)
const emailInput = ref<HTMLInputElement | null>(null)

const canSubmit = computed(() => email.value.trim().length > 0 && password.value.length > 0)

function redirectTarget(): string {
  const r = route.query.redirect
  return typeof r === 'string' && r.startsWith('/') ? r : '/app'
}

function kickSseAfterLogin(): void {
  // The global SSE bus connects at app boot (App.vue) — possibly BEFORE login, while /api/events
  // still 401s.
  try {
    const bus = useSseBus()
    if (bus.state.value === 'failed' || bus.state.value === 'closed') {
      bus.reconnectGlobal()
    }
  } catch {
    // Bus not installed (e.g. unit tests) — a fresh mount connects with cookie.
  }
}

onMounted(async () => {
  // The only field on the page: a sign-in should never need a click before the first keystroke.
  emailInput.value?.focus()
  // Already logged in? Skip the form (deep-linkable ?redirect= is honored).
  // Cached: mount must not stall on a slow /me (see helpers/authMe).
  try {
    const { data } = await getAuthMeCached()
    if (data && (data.authenticated === true || data.auth_enabled === false)) {
      if (data.auth_enabled === false) authDisabled.value = true
      else {
        await router.replace(redirectTarget())
        return
      }
    }
  } catch {
    /* offline — show the form */
  }
})

async function onSubmit() {
  if (!canSubmit.value || busy.value) return
  error.value = ''
  busy.value = true
  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ email: email.value.trim(), password: password.value }),
    })
    if (!res.ok) {
      error.value = 'Invalid email or password'
      return
    }
    // New session cookie: drop any pre-login cached /me (401) so the
    // guard sees the fresh authenticated state on the redirect.
    invalidateAuthMe()
    await router.replace(redirectTarget())
    kickSseAfterLogin()
  } catch {
    error.value = 'Network error — is the server running?'
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.login-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  padding: 24px;
  background: var(--semantic-content-bg);
  color: var(--semantic-text);
}
.login-card {
  display: flex;
  flex-direction: column;
  gap: 16px;
  width: 320px;
  max-width: 100%;
  padding: 24px;
  border-radius: 12px;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.32);
}
.login-card h1 {
  font-size: var(--text-title-sm);
  font-weight: 600;
  letter-spacing: -0.01em;
  margin: 0;
  color: var(--semantic-text);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field label {
  font-size: var(--text-dense);
  font-weight: 500;
  color: var(--semantic-text-muted);
}
.field input {
  box-sizing: border-box;
  width: 100%;
  padding: 8px 11px;
  border-radius: 8px;
  border: 1px solid var(--color-border);
  background: var(--color-bg-dim);
  color: var(--semantic-text);
  font-size: var(--text-body);
  outline: none;
}
.field input::placeholder {
  color: var(--semantic-text-dim);
}
.field input:focus {
  border-color: var(--semantic-link);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--semantic-link) 18%, transparent);
}
.field input:disabled {
  opacity: 0.6;
}
.input-shell {
  position: relative;
  display: flex;
}
.input-shell input {
  padding-right: 38px;
}
.reveal-btn {
  position: absolute;
  top: 50%;
  right: 4px;
  transform: translateY(-50%);
  display: grid;
  place-items: center;
  width: 26px;
  height: 26px;
  padding: 0;
  border: none;
  border-radius: 6px;
  background: transparent;
  color: var(--semantic-text-dim);
  cursor: pointer;
}
.reveal-btn:hover:not(:disabled) {
  color: var(--semantic-text);
  background: var(--semantic-active-bg);
}
.reveal-btn:focus-visible {
  outline: 2px solid var(--semantic-link);
  outline-offset: 1px;
}
.reveal-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.error {
  color: var(--semantic-error);
  font-size: var(--text-dense);
  margin: 0;
  padding: 7px 10px;
  border-radius: 8px;
  background: color-mix(in srgb, var(--semantic-error) 12%, transparent);
  border: 1px solid color-mix(in srgb, var(--semantic-error) 35%, transparent);
}
.muted {
  font-size: var(--text-dense);
  color: var(--semantic-text-muted);
  margin: 0;
}
.primary-btn {
  padding: 9px 12px;
  border-radius: 8px;
  border: none;
  background: var(--semantic-accent);
  color: var(--color-bg-dim);
  font-size: var(--text-body);
  font-weight: 600;
  cursor: pointer;
}
.primary-btn:hover:not(:disabled) {
  background: var(--semantic-accent-hover);
}
.primary-btn:focus-visible {
  outline: 2px solid var(--semantic-link);
  outline-offset: 2px;
}
.primary-btn:disabled {
  background: var(--color-bg-p1);
  color: var(--semantic-text-dim);
  cursor: not-allowed;
}
</style>
