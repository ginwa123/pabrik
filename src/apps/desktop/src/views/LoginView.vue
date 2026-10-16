<template>
  <div class="login-wrap">
    <form class="login-card" @submit.prevent="onSubmit">
      <div class="login-brand">
        <span class="login-mark">A</span>
        <div>
          <h1>Welcome back</h1>
          <p class="login-sub">Sign in to AnakMagang</p>
        </div>
      </div>
      <p v-if="authDisabled" class="muted">
        Auth is disabled on this server — you should not see this page.
      </p>
      <label class="field">
        <span>Email</span>
        <input
          v-model="email"
          type="email"
          autocomplete="username"
          placeholder="you@example.com"
          required
          :disabled="busy"
        />
      </label>
      <label class="field">
        <span>Password</span>
        <div class="password-row">
          <input
            v-model="password"
            :type="showPassword ? 'text' : 'password'"
            autocomplete="current-password"
            placeholder="••••••••"
            required
            :disabled="busy"
          />
          <button
            type="button"
            class="ghost-btn"
            :disabled="busy"
            :aria-label="showPassword ? 'Hide password' : 'Show password'"
            @click="showPassword = !showPassword"
          >
            {{ showPassword ? 'Hide' : 'Show' }}
          </button>
        </div>
      </label>
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

const route = useRoute()
const router = useRouter()
const email = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)
const authDisabled = ref(false)
const showPassword = ref(false)

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
  gap: 14px;
  width: 360px;
  max-width: 100%;
  padding: 28px;
  border-radius: 14px;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
}
.login-brand {
  display: flex;
  align-items: center;
  gap: 12px;
}
.login-mark {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 10px;
  font-weight: 700;
  font-size: var(--text-title-sm);
  color: var(--semantic-text);
  background: var(--color-bg-dim);
  border: 1px solid var(--color-border);
  flex-shrink: 0;
}
.login-card h1 {
  font-size: var(--text-title-sm);
  font-weight: 650;
  letter-spacing: -0.01em;
  margin: 0;
  color: var(--semantic-text);
}
.login-sub {
  font-size: var(--text-dense);
  margin: 2px 0 0;
  color: var(--semantic-text-muted);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: var(--text-dense);
  font-weight: 500;
  color: var(--semantic-text-muted);
}
.field input {
  padding: 9px 12px;
  border-radius: 9px;
  border: 1px solid var(--color-border);
  background: var(--color-bg-dim);
  color: var(--semantic-text);
  font-size: var(--text-body);
  outline: none;
  width: 100%;
  box-sizing: border-box;
}
.field input::placeholder {
  color: var(--semantic-text-dim);
}
.field input:focus {
  border-color: var(--semantic-link);
}
.field input:disabled {
  opacity: 0.6;
}
.password-row {
  display: flex;
  gap: 8px;
}
.password-row input {
  flex: 1;
  min-width: 0;
}
.ghost-btn {
  padding: 0 12px;
  border-radius: 9px;
  border: 1px solid var(--color-border);
  background: transparent;
  color: var(--semantic-text-dim);
  font-size: var(--text-dense);
  font-weight: 600;
  cursor: pointer;
  white-space: nowrap;
}
.ghost-btn:hover:not(:disabled) {
  color: var(--semantic-text);
  border-color: var(--color-border-light);
}
.error {
  color: var(--semantic-error);
  font-size: var(--text-dense);
  margin: 0;
  padding: 8px 12px;
  border-radius: 9px;
  background: color-mix(in srgb, var(--semantic-error) 12%, transparent);
  border: 1px solid color-mix(in srgb, var(--semantic-error) 35%, transparent);
}
.muted {
  font-size: var(--text-dense);
  color: var(--semantic-text-muted);
  margin: 0;
}
.primary-btn {
  padding: 10px 12px;
  border-radius: 9px;
  border: none;
  background: var(--semantic-accent);
  color: #12120f;
  font-size: var(--text-body);
  font-weight: 650;
  cursor: pointer;
}
.primary-btn:hover:not(:disabled) {
  background: var(--semantic-accent-hover);
}
.primary-btn:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}
</style>
