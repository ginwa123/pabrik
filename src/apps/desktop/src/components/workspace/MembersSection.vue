<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useMembersStore } from '../../stores/members'
import { useInvitationsStore } from '../../stores/invitations'
import type { WorkspaceInvitation, WorkspaceMember, WorkspaceRole } from '../../api'
import EmptyState from '../pabrik/EmptyState.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  /** The workspace in the URL. The parent keys on it, so a switch remounts
   * this component rather than showing the previous workspace's members. */
  workspaceId: string
}>()

const membersStore = useMembersStore()
const invitationsStore = useInvitationsStore()

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
const revokeTarget = ref<WorkspaceInvitation | null>(null)

/** One banner for both stores: a refused invite and a refused removal are the
 * same kind of answer to the user. */
const error = computed<string | null>(() => membersStore.error ?? invitationsStore.error)

const ownerCount = computed(
  () => membersStore.members.filter((m) => m.role === 'owner').length,
)
const pending = computed<WorkspaceInvitation[]>(() => invitationsStore.pending)
const canInvite = computed(
  () => emailInput.value.trim().length > 0 && !invitationsStore.saving,
)

/** The one change the server would refuse anyway. Disabling it here is not a
 * substitute for the 409 — it stops the user walking into it. */
function isSoleOwner(member: WorkspaceMember): boolean {
  return member.role === 'owner' && ownerCount.value <= 1
}

function labelFor(member: { email: string; name: string; user_id: string }): string {
  return member.name.trim().length > 0 ? member.name.trim() : member.email || member.user_id
}

function roleLabel(role: string): string {
  return ROLE_OPTIONS.find((r) => r.value === role)?.label ?? role
}

async function handleInvite(): Promise<void> {
  const email = emailInput.value.trim()
  if (!email) {
    formError.value = 'An invite needs an email address.'
    return
  }
  formError.value = null
  const ok = await invitationsStore.invite(props.workspaceId, email, roleInput.value)
  if (!ok) return
  emailInput.value = ''
  roleInput.value = 'viewer'
}

async function handleRoleChange(member: WorkspaceMember, event: Event): Promise<void> {
  const next = (event.target as HTMLSelectElement).value as WorkspaceRole
  if (next === member.role) return
  const ok = await membersStore.setRole(props.workspaceId, member.user_id, next)
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
  await membersStore.removeMember(props.workspaceId, target.user_id)
}

function openRevoke(invitation: WorkspaceInvitation): void {
  revokeTarget.value = invitation
}

function closeRevoke(): void {
  revokeTarget.value = null
}

async function handleRevoke(): Promise<void> {
  const target = revokeTarget.value
  closeRevoke()
  if (!target) return
  await invitationsStore.revoke(props.workspaceId, target.id)
}

function retry(): void {
  void membersStore.fetchMembers(props.workspaceId)
  void invitationsStore.fetchPending(props.workspaceId)
}

onMounted(() => {
  // Clear first: a switch remounts this component, and `loaded` would
  // otherwise paint the previous workspace's rows while the new list loads.
  membersStore.reset()
  invitationsStore.reset()
  retry()
})
</script>

<template>
  <div class="space-y-5" data-testid="members-section-body">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted)">
      People who can open {{ workspaceId }}. An invite is a request: the account you name is asked
      first and gains nothing until it accepts. Owners and Admins can manage this list.
    </p>

    <!-- Failure is NOT an empty list, and it is not a silent no-op: a refused
         invite, role change or revocation lands here too. -->
    <div
      v-if="error"
      data-testid="error-message"
      role="alert"
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
        @click="retry"
      >
        Retry
      </button>
    </div>

    <!-- A member who is not an owner/admin reads the roster and nothing else;
         a form whose every submit would 403 is worse than no form. -->
    <p
      v-if="!invitationsStore.canManage"
      data-testid="read-only-note"
      class="text-dense"
      style="color: var(--semantic-text-muted)"
    >
      Only owners and admins can invite or remove people in this workspace.
    </p>

    <div
      v-if="invitationsStore.canManage"
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

    <!-- Unanswered asks. They are NOT members: nothing here has access yet. -->
    <div
      v-if="pending.length"
      data-testid="pending-invitations"
      class="px-4 py-3 rounded-md space-y-2"
      style="background-color: var(--semantic-content-bg); border: 1px dashed var(--color-border)"
    >
      <h3 class="text-dense font-semibold" style="color: var(--semantic-text)">
        Pending invitations
      </h3>
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        Waiting for an answer. These accounts cannot see this workspace yet.
      </p>
      <ul class="space-y-1.5">
        <li
          v-for="invitation in pending"
          :key="invitation.id"
          data-testid="pending-invitation-row"
          class="flex items-center justify-between gap-3"
        >
          <span class="flex-1 min-w-0 truncate text-dense font-mono" style="color: var(--semantic-text)">
            {{ invitation.invitee_email || invitation.invitee_user_id }}
          </span>
          <span
            data-testid="pending-invitation-role"
            class="text-micro uppercase tracking-wide shrink-0"
            style="color: var(--semantic-text-muted)"
            >{{ roleLabel(invitation.role) }}</span
          >
          <button
            type="button"
            data-testid="revoke-btn"
            :disabled="invitationsStore.saving"
            class="px-2.5 h-7 rounded-md text-dense border shrink-0 transition-colors duration-150 disabled:opacity-40"
            style="
              border-color: var(--color-border);
              color: var(--semantic-text-muted);
              background-color: transparent;
            "
            :aria-label="`Revoke the invitation to ${invitation.invitee_email}`"
            @click="openRevoke(invitation)"
          >
            Revoke
          </button>
        </li>
      </ul>
    </div>

    <p
      v-if="membersStore.loading && !membersStore.loaded"
      class="text-dense"
      style="color: var(--semantic-text-dim)"
    >
      Loading members…
    </p>

    <!-- Only once a fetch has actually completed: before that, "no members"
         would be a claim nobody has verified. -->
    <EmptyState
      v-else-if="membersStore.loaded && membersStore.members.length === 0 && !error"
      glyph="◇"
      title="No members yet"
      description="Invite an account by email to give it access to this workspace."
    />

    <ul v-else-if="membersStore.members.length" class="space-y-2" data-testid="member-list">
      <li
        v-for="member in membersStore.members"
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
              v-if="invitationsStore.canManage"
              :value="member.role"
              data-testid="member-role-select"
              :aria-label="`Role for ${labelFor(member)}`"
              :disabled="membersStore.saving"
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
              v-if="invitationsStore.canManage"
              type="button"
              data-testid="remove-btn"
              :disabled="membersStore.saving || isSoleOwner(member)"
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
      :show="removeTarget !== null || revokeTarget !== null"
      :title="revokeTarget ? 'Revoke invitation' : 'Remove member'"
      :message="
        revokeTarget
          ? `Withdraw the invitation to ${revokeTarget.invitee_email}? They will not be asked again.`
          : removeTarget
            ? `Remove ${labelFor(removeTarget)} from this workspace? They lose access to everything in it.`
            : ''
      "
      :confirm-text="revokeTarget ? 'Revoke' : 'Remove'"
      cancel-text="Cancel"
      @confirm="revokeTarget ? handleRevoke() : handleRemove()"
      @close="
        () => {
          closeRevoke()
          closeRemove()
        }
      "
    />
  </div>
</template>
