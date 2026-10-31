<script setup lang="ts">
// Workspace secrets — the body of the Settings → Secrets tab. THE ONE RULE THIS COMPONENT EXISTS TO
// KEEP: a value reaches the screen only because the user asked for THAT row, and only through the
// `reveal` event — never from the list payload.
import { computed, ref } from 'vue'
import type { Secret } from '../../api'
import EmptyState from '../pabrik/EmptyState.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import RotateSecretDialog from './RotateSecretDialog.vue'

const props = withDefaults(
  defineProps<{
    secrets: Secret[]
    loading?: boolean
    /** True once a list has been fetched — separates "none" from "unknown". */
    loaded?: boolean
    /** Rendered verbatim. Never swallowed into an empty list. */
    error?: string | null
    saving?: boolean
    /** Plaintexts the store has unsealed, keyed by secret id. Absent = hidden. */
    revealed?: Record<string, string>
    /** Id whose reveal is in flight, so its button says so. */
    revealing?: string | null
  }>(),
  { loading: false, loaded: false, error: null, saving: false, revealed: () => ({}), revealing: null },
)

const emit = defineEmits<{
  /** New secret. The value is forwarded to the API and forgotten. */
  add: [payload: { name: string; value: string }]
  /** Rotate in place: same id, brand-new credential. */
  rotate: [payload: { id: string; name: string; value: string }]
  /** Delete by NAME — the label the user sees, so the confirm reads right. */
  delete: [name: string]
  /** Ask the server to unseal ONE value. The component never fetches by itself. */
  reveal: [id: string]
  /** Put it away again. */
  hide: [id: string]
  retry: []
}>()

const nameInput = ref('')
const valueInput = ref('')
const addError = ref<string | null>(null)

const rotateTarget = ref<Secret | null>(null)
const deleteTarget = ref<Secret | null>(null)

/** An empty value is not a secret. Silently swallowing the click would look
 * like a success that never happened, so the form says why instead. */
const canAdd = computed(() => nameInput.value.trim().length > 0 && valueInput.value.length > 0)

function handleAdd(): void {
  const name = nameInput.value.trim()
  const value = valueInput.value
  if (!name || !value) {
    addError.value = 'A secret needs both a name and a value.'
    return
  }
  addError.value = null
  emit('add', { name, value })
  // Clear BEFORE the await — the caller may take a moment to answer, and a
  // credential sitting in a ref in the meantime is a credential sitting in
  // a ref. Nothing else reads these once the payload has been emitted.
  nameInput.value = ''
  valueInput.value = ''
}

function openRotate(secret: Secret): void {
  rotateTarget.value = secret
}

function closeRotate(): void {
  rotateTarget.value = null
}

function handleRotate(value: string): void {
  const target = rotateTarget.value
  if (!target || value.length === 0) return
  emit('rotate', { id: target.id, name: target.name, value })
  closeRotate()
}

function openDelete(secret: Secret): void {
  deleteTarget.value = secret
}

function closeDelete(): void {
  deleteTarget.value = null
}

function handleDelete(): void {
  const target = deleteTarget.value
  if (!target) return
  emit('delete', target.name)
  closeDelete()
}

/** True when this row's plaintext is on screen. */
function isRevealed(secret: Secret): boolean {
  return props.revealed[secret.id] !== undefined
}

function toggleReveal(secret: Secret): void {
  if (isRevealed(secret)) {
    emit('hide', secret.id)
    return
  }
  emit('reveal', secret.id)
}

function formatTimestamp(value: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

// The empty state's CTA focuses the name field. Kept as a function in the script block rather than
// an inline arrow in the template: `document` is not on the component's instance type, so a
// template expression fails the `vue-tsc --build` type-check that the pre-push hook runs.
function focusAddName(): void {
  document.getElementById('secret-name')?.focus()
}
</script>

<template>
  <div class="space-y-5" data-testid="secrets-section-body">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted)">
      Named credentials the agent's tools can substitute into requests made for this workspace.
      Values are encrypted on disk and never leave the server in a list; Reveal asks for one value
      on demand, and only a member of this workspace can do that. Rotating a secret replaces it.
    </p>

    <!-- Failure is NOT an empty list. This block is why the two look different. -->
    <div
      v-if="error"
      data-testid="error-message"
      class="px-4 py-3 rounded-md flex items-start justify-between gap-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-red)"
    >
      <p class="text-dense" style="color: var(--color-red)">{{ error }}</p>
      <button
        type="button"
        data-testid="retry-btn"
        class="px-3 h-7 rounded-md text-dense border shrink-0 transition-colors duration-150"
        style="
          border-color: var(--color-border);
          color: var(--semantic-text-muted);
          background-color: transparent;
        "
        @click="emit('retry')"
      >
        Retry
      </button>
    </div>

    <!-- Add form. The field holds what the user is typing right now; there is
         nothing stored behind it yet, so it has no toggle of its own. -->
    <div
      class="px-4 py-3 rounded-md space-y-2"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex flex-wrap items-end gap-2">
        <div class="flex-1 min-w-[12rem]">
          <label
            class="text-dense block mb-1"
            style="color: var(--semantic-text-muted)"
            for="secret-name"
          >
            Name
          </label>
          <input
            id="secret-name"
            v-model="nameInput"
            data-testid="name-input"
            type="text"
            autocomplete="off"
            spellcheck="false"
            placeholder="STRIPE_API_KEY"
            class="w-full px-3 h-8 rounded-md text-dense font-mono"
            style="
              background-color: var(--semantic-bg);
              color: var(--semantic-text);
              border: 1px solid var(--color-border);
            "
          />
        </div>
        <div class="flex-1 min-w-[12rem]">
          <label
            class="text-dense block mb-1"
            style="color: var(--semantic-text-muted)"
            for="secret-value"
          >
            Value
          </label>
          <input
            id="secret-value"
            v-model="valueInput"
            data-testid="value-input"
            type="password"
            autocomplete="new-password"
            spellcheck="false"
            placeholder="Paste the credential"
            class="w-full px-3 h-8 rounded-md text-dense font-mono"
            style="
              background-color: var(--semantic-bg);
              color: var(--semantic-text);
              border: 1px solid var(--color-border);
            "
          />
        </div>
        <button
          type="button"
          data-testid="add-btn"
          :disabled="!canAdd || saving"
          class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150 disabled:opacity-50"
          style="
            border-color: var(--color-violet);
            color: var(--color-violet);
            background-color: transparent;
          "
          @click="handleAdd"
        >
          + Add secret
        </button>
      </div>
      <p v-if="addError" data-testid="add-error" class="text-dense" style="color: var(--color-red)">
        {{ addError }}
      </p>
    </div>

    <p v-if="loading && !loaded" class="text-dense" style="color: var(--semantic-text-dim)">
      Loading secrets…
    </p>

    <!-- Empty state renders only once a fetch has actually completed. Before
         that, "No secrets yet" would be a claim nobody has verified. -->
    <EmptyState
      v-else-if="loaded && props.secrets.length === 0 && !error"
      glyph="⚿"
      title="No secrets yet"
      description="Add a credential to let this workspace's agent tools authenticate against your services. It is stored encrypted; use Reveal when you need to check it."
      cta-label="+ Add secret"
      :cta-action="focusAddName"
    />

    <ul v-else-if="props.secrets.length" class="space-y-2" data-testid="secret-list">
      <li
        v-for="secret in props.secrets"
        :key="secret.id"
        data-testid="secret-row"
        class="px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div
              class="text-body font-medium flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <span class="font-mono truncate">{{ secret.name }}</span>
              <span
                data-testid="configured-badge"
                class="text-micro px-1.5 h-4 inline-flex items-center rounded font-medium uppercase tracking-wide shrink-0"
                style="
                  color: var(--color-green, var(--color-violet));
                  border: 1px solid var(--color-border);
                "
                >Configured</span
              >
            </div>
            <div
              data-testid="secret-updated-at"
              class="text-dense mt-0.5"
              style="color: var(--semantic-text-dim)"
            >
              Updated {{ formatTimestamp(secret.updated_at) }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="reveal-btn"
              :disabled="revealing === secret.id"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150 disabled:opacity-50"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent"
              :aria-label="isRevealed(secret) ? `Hide ${secret.name}` : `Reveal ${secret.name}`"
              @click="toggleReveal(secret)"
            >
              {{ revealing === secret.id ? 'Revealing…' : isRevealed(secret) ? 'Hide' : 'Reveal' }}
            </button>
            <button
              type="button"
              data-testid="rotate-btn"
              :disabled="saving"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150 disabled:opacity-50"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
              :aria-label="`Rotate ${secret.name}`"
              @click="openRotate(secret)"
            >
              Rotate
            </button>
            <button
              type="button"
              data-testid="delete-btn"
              :disabled="saving"
              class="px-2.5 h-7 rounded-md text-dense transition-colors duration-150 disabled:opacity-50"
              style="color: var(--color-red)"
              :aria-label="`Delete ${secret.name}`"
              @click="openDelete(secret)"
            >
              ⌫
            </button>
          </div>
        </div>
        <div
          v-if="isRevealed(secret)"
          data-testid="revealed-value"
          class="mt-2 px-2 py-1.5 rounded-md text-dense font-mono break-all select-all"
          style="background-color: var(--semantic-bg); color: var(--semantic-text); border: 1px solid var(--color-border)"
        >
          {{ revealed[secret.id] }}
        </div>
      </li>
    </ul>

    <!-- One dialog per target: the component is keyed on the id, so opening a
         different secret remounts it with an empty field. -->
    <RotateSecretDialog
      :key="rotateTarget?.id ?? 'closed'"
      :name="rotateTarget?.name ?? null"
      @save="handleRotate"
      @close="closeRotate"
    />

    <ConfirmDialog
      :show="deleteTarget !== null"
      title="Delete secret"
      :message="
        deleteTarget
          ? `Delete ${deleteTarget.name}? Its stored credential is destroyed and cannot be recovered.`
          : ''
      "
      confirm-text="Delete"
      cancel-text="Cancel"
      @confirm="handleDelete"
      @close="closeDelete"
    />
  </div>
</template>
