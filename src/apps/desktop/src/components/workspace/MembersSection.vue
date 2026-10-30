<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useMembersStore } from '../../stores/members'
import type { WorkspaceMember, WorkspaceRole } from '../../api'
import EmptyState from '../pabrik/EmptyState.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  /** The workspace in the URL. The parent keys on it, so a switch remounts
   * this component rather than showing the previous workspace's members. */
  workspaceId: string
}>()

const store = useMembersStore()

const ROLE_OPTIONS: readonly { value: WorkspaceRole; label: string }[] = [
  { value: 'owner', label: 'Owner' },
  { value: 'admin', label: 'Admin' },
  { value: 'editor', label: 'Editor' },
  { value: 'viewer', label: 'Viewer' },
]

const emailInput = ref('')
const roleInput = ref<WorkspaceRole>('viewer')
const formError = ref<string | null>(null)
const removeTarget = ref<WorkspaceMember | null>(null)

const ownerCount = computed(() => store.members.filter((m) => m.role === 'owner').length)
const canInvite = computed(() => emailInput.value.trim().length > 0 && !store.saving)

/** The one change the server would refuse anyway. Disabling it here is not a
 * substitute for the 409 — it stops the user walking into it. */
function isSoleOwner(member: WorkspaceMember): boolean {
  return member.role === 'owner' && ownerCount.value <= 1
}

function labelFor(member: WorkspaceMember): string {
  return member.name.trim().length > 0 ? member.name.trim() : member.email || member.user_id
}

async function handleInvite(): Promise<void> {
  const email = emailInput.value.trim()
  if (!email) {
    formError.value = 'An invite needs an email address.'
    return
  }
  formError.value = null
  const ok = await store.inviteMember(props.workspaceId, email, roleInput.value)
  if (!ok) return
  emailInput.value = ''
  roleInput.value = 'viewer'
}

async function handleRoleChange(member: WorkspaceMember, event: Event): Promise<void> {
  const next = (event.target as HTMLSelectElement).value as WorkspaceRole
  if (next === member.role) return
  const ok = await store.setRole(props.workspaceId, member.user_id, next)
  // A refused change leaves the SELECT showing a role the server never
  // accepted, so put it back.
  if (!ok) (event.target as HTMLSelectElement).value = member.role
}

function openRemove(member: WorkspaceMember): void {
  removeTarget.value = member
}

function closeRemove(): void {
  removeTarget.value = null
}

async function handleRemove(): Promise<void> {
  const target = removeTarget.value
  closeRemove()
  if (!target) return
  await store.removeMember(props.workspaceId, target.user_id)
}

function retry(): void {
  void store.fetchMembers(props.workspaceId)
}

onMounted(() => {
  // Clear first: a switch remounts this component, and `loaded` would
  // otherwise paint the previous workspace's rows while the new list loads.
  store.reset()
  retry()
})
</script>

<template>
  <div class="space-y-5" data-testid="members-section-body">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted)">
      People who can open {{ workspaceId }}. An invite adds an existing account by email — Owners
      and Admins can manage this list, Editors and Viewers cannot.
    </p>

    <!-- Failure is NOT an empty list, and it is not a silent no-op: a refused
         invite or role change lands here too. -->
    <div
      v-if="store.error"
      data-testid="error-message"
      role="alert"
      class="px-4 py-3 rounded-md flex items-start justify-between gap-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-red)"
    >
      <p class="text-dense" style="color: var(--color-red)">{{ store.error }}</p>
      <button
        type="button"
        data-testid="retry-btn"
        class="px-3 h-7 rounded-md text-dense border shrink-0 transition-colors duration-150"
        style="
          border-color: var(--color-border);
          color: var(--semantic-text-muted);
          background-color: transparent;
        "
        @click="retry"
      >
        Retry
      </button>
    </div>

    <div
      class="px-4 py-3 rounded-md space-y-2"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex flex-wrap items-end gap-2">
        <div class="flex-1 min-w-[14rem]">
          <label
            class="text-dense block mb-1"
            style="color: var(--semantic-text-muted)"
            for="invite-email"
          >
            Email
          </label>
          <input
            id="invite-email"
            v-model="emailInput"
            data-testid="invite-email-input"
            type="email"
            autocomplete="off"
            spellcheck="false"
            placeholder="teammate@example.com"
            class="w-full px-3 h-8 rounded-md text-dense"
            style="
              background-color: var(--semantic-bg);
              color: var(--semantic-text);
              border: 1px solid var(--color-border);
            "
            @keyup.enter="handleInvite"
          />
        </div>
        <div class="min-w-[8rem]">
          <label
            class="text-dense block mb-1"
            style="color: var(--semantic-text-muted)"
            for="invite-role"
          >
            Role
          </label>
          <select
            id="invite-role"
            v-model="roleInput"
            data-testid="invite-role-select"
            class="w-full px-2 h-8 rounded-md text-dense"
            style="
              background-color: var(--semantic-bg);
              color: var(--semantic-text);
              border: 1px solid var(--color-border);
            "
          >
            <option v-for="role in ROLE_OPTIONS" :key="role.value" :value="role.value">
              {{ role.label }}
            </option>
          </select>
        </div>
        <button
          type="button"
          data-testid="invite-btn"
          :disabled="!canInvite"
          class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150 disabled:opacity-50"
          style="
            border-color: var(--color-violet);
            color: var(--color-violet);
            background-color: transparent;
          "
          @click="handleInvite"
        >
          <span class="inline-flex items-center gap-1.5">
            <UiIcon name="plus" size-class="w-3.5 h-3.5" />
            Invite
          </span>
        </button>
      </div>
      <p v-if="formError" data-testid="invite-error" class="text-dense" style="color: var(--color-red)">
        {{ formError }}
      </p>
    </div>

    <p v-if="store.loading && !store.loaded" class="text-dense" style="color: var(--semantic-text-dim)">
      Loading members…
    </p>

    <!-- Only once a fetch has actually completed: before that, "no members"
         would be a claim nobody has verified. -->
    <EmptyState
      v-else-if="store.loaded && store.members.length === 0 && !store.error"
      glyph="◇"
      title="No members yet"
      description="Invite an account by email to give it access to this workspace."
    />

    <ul v-else-if="store.members.length" class="space-y-2" data-testid="member-list">
      <li
        v-for="member in store.members"
        :key="member.user_id"
        data-testid="member-row"
        :data-user-id="member.user_id"
        class="px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-body font-medium truncate" style="color: var(--semantic-text)">
              {{ labelFor(member) }}
            </div>
            <div
              data-testid="member-email"
              class="text-dense mt-0.5 font-mono truncate"
              style="color: var(--semantic-text-dim)"
            >
              {{ member.email || member.user_id }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <select
              :value="member.role"
              data-testid="member-role-select"
              :aria-label="`Role for ${labelFor(member)}`"
              :disabled="store.saving"
              class="px-2 h-7 rounded-md text-dense disabled:opacity-50"
              style="
                background-color: var(--semantic-bg);
                color: var(--semantic-text);
                border: 1px solid var(--color-border);
              "
              @change="handleRoleChange(member, $event)"
            >
              <option v-for="role in ROLE_OPTIONS" :key="role.value" :value="role.value">
                {{ role.label }}
              </option>
            </select>
            <button
              type="button"
              data-testid="remove-btn"
              :disabled="store.saving || isSoleOwner(member)"
              :title="isSoleOwner(member) ? 'A workspace must keep at least one owner' : undefined"
              class="px-2.5 h-7 rounded-md text-dense transition-colors duration-150 disabled:opacity-40"
              style="color: var(--color-red)"
              :aria-label="`Remove ${labelFor(member)}`"
              @click="openRemove(member)"
            >
              ⌫
            </button>
          </div>
        </div>
      </li>
    </ul>

    <ConfirmDialog
      :show="removeTarget !== null"
      title="Remove member"
      :message="
        removeTarget
          ? `Remove ${labelFor(removeTarget)} from this workspace? They lose access to everything in it.`
          : ''
      "
      confirm-text="Remove"
      cancel-text="Cancel"
      @confirm="handleRemove"
      @close="closeRemove"
    />
  </div>
</template>
