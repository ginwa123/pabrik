<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Effect } from 'effect'
import SkillList from '../tool_outputs/SkillList.vue'
import SkillDetail from '../shell/SkillDetail.vue'
import { createSkill } from '../../api'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  /** Explicit workspace binding, forwarded to the list + detail halves.
   * The workspace settings page passes the route workspace id; absent
   * keeps the previous behaviour (active workspace from the store). */
  workspaceId?: string | null
}>()

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const scopeCaption = computed(() =>
  props.workspaceId
    ? 'Skills available to agents in this workspace.'
    : 'Available AI capabilities and workflows.',
)

// The selected skill lives in the URL (`?skill=`), not in a ref. A ref
// loses the selection on refresh, on Back, and on a shared link — and a
// skill is exactly the kind of thing you paste into a chat ("look at how
// this one is written"). Same rule as the kanban board's `?detail=`.
const route = useRoute()
const router = useRouter()

// `route?.query` rather than `route.query`: a unit test that mounts this
// component without a router leaves `route` undefined, and the read must
// degrade to "nothing selected" rather than throw during setup.
const readSkillParam = (): string | null => {
  const raw = route?.query?.skill
  const value = Array.isArray(raw) ? raw[0] : raw
  return typeof value === 'string' && value.length > 0 ? value : null
}

const selectedSkillName = ref<string | null>(readSkillParam())
const skillListRef = ref<InstanceType<typeof SkillList> | null>(null)

/** Every other query param on this page, so a write never drops `section`. */
function flatQuery(): Record<string, string> {
  const out: Record<string, string> = {}
  const src = (route?.query as Record<string, unknown> | undefined) ?? {}
  for (const [k, v] of Object.entries(src)) {
    if (typeof v === 'string') out[k] = v
    else if (Array.isArray(v)) {
      const first = v.find((x): x is string => typeof x === 'string')
      if (first !== undefined) out[k] = first
    }
  }
  return out
}

function writeSkillParam(name: string | null): void {
  const query = flatQuery()
  if (name) query.skill = name
  else delete query.skill
  // replace, not push: clicking through five skills should not bury the
  // previous four under Back.
  router?.replace({ path: route?.path ?? '', query })
}

// The create form. A skill is a row, so "new" is three fields and no
// directory: the name is the natural key inside the workspace, and the
// body is stored verbatim — frontmatter included, because `skill_eval`
// identities are sha256(body) and trimming it would stale every verdict.
const isCreating = ref(false)
const newName = ref('')
const newDescription = ref('')
const newContent = ref('')
const createError = ref<string | null>(null)
const isSaving = ref(false)

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const canCreate = computed(() => newName.value.trim().length > 0)

const openCreate = () => {
  newName.value = ''
  newDescription.value = ''
  newContent.value = ''
  createError.value = null
  isCreating.value = true
}

const closeCreate = () => {
  isCreating.value = false
  createError.value = null
}

const handleCreate = async () => {
  const ws = props.workspaceId
  if (!ws) return
  const name = newName.value.trim()
  if (!name) {
    createError.value = 'A skill needs a name.'
    return
  }

  isSaving.value = true
  createError.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        createSkill(ws, {
          name,
          description: newDescription.value,
          content: newContent.value,
        }),
      catch: (e) => new SyncRemoteError({ op: 'skills.create', reason: fail(e) }),
    }),
    'skills.create',
  )
  isSaving.value = false

  if (!result.ok) {
    // Kept in the form: the user is mid-entry and the reason belongs next
    // to the fields that caused it, not in a toast that outlives them.
    createError.value = result.reason
    return
  }
  isCreating.value = false
  // Select what was just written, so the detail pane shows the stored row
  // rather than an empty state the user has to click out of.
  selectedSkillName.value = result.value.skill.name
  writeSkillParam(result.value.skill.name)
  skillListRef.value?.refresh()
  emit('notification', `Skill "${result.value.skill.name}" created`, 'success')
}

const handleSelectSkill = (skillName: string) => {
  selectedSkillName.value = skillName
  writeSkillParam(skillName)
}

const handleSkillDeleted = () => {
  selectedSkillName.value = null
  writeSkillParam(null)
  skillListRef.value?.refresh()
  emit('notification', 'Skill deleted successfully', 'success')
}

const handleSkillSaved = () => {
  // The description is the list row's second line, so a save that changed
  // it has to re-read or the two halves disagree about the same skill.
  skillListRef.value?.refresh()
}

const handleSkillError = (message: string) => {
  emit('notification', message, 'error')
}

// `/` focuses the list's search box from anywhere on this page — the one
// shortcut a 41-row list needs. Ignored while typing in a field, so the
// keystroke still types a slash where a slash belongs.
const onSlashKey = (event: KeyboardEvent) => {
  if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return
  const target = event.target as HTMLElement | null
  if (target) {
    const tag = target.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable) {
      return
    }
  }
  event.preventDefault()
  skillListRef.value?.focusSearch()
}

onMounted(() => {
  window.addEventListener('keydown', onSlashKey)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onSlashKey)
})
</script>

<template>
  <div class="flex h-full gap-6">
    <!-- Skill List Panel -->
    <div class="w-80 shrink-0 flex flex-col overflow-hidden">
      <div
        class="rounded-xl p-6 flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <h2 class="text-lead font-semibold mb-4 shrink-0" style="color: var(--semantic-text)">
          Skills
        </h2>
        <p class="text-body mb-4 shrink-0" style="color: var(--semantic-text-muted)">
          {{ scopeCaption }}
        </p>
        <button
          @click="openCreate"
          class="mb-4 px-3 h-8 rounded-lg flex items-center justify-center gap-2 text-body font-medium transition-colors duration-200 shrink-0"
          style="
            background-color: transparent;
            color: var(--color-violet);
            border: 1px solid var(--color-violet);
          "
          data-testid="new-skill-btn"
        >
          <svg
            class="w-4 h-4"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="2"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
          </svg>
          New skill
        </button>
        <div class="flex-1 overflow-y-auto min-h-0">
          <SkillList
            ref="skillListRef"
            :selected-skill-name="selectedSkillName"
            :workspace-id="props.workspaceId"
            @select-skill="handleSelectSkill"
            @error="handleSkillError"
          />
        </div>
      </div>
    </div>

    <!-- Skill Detail Panel -->
    <div class="flex-1 flex flex-col overflow-hidden">
      <div
        class="rounded-xl flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <h2
          class="text-lead font-semibold p-4 shrink-0"
          style="color: var(--semantic-text); border-bottom: 1px solid var(--color-border)"
        >
          {{ isCreating ? 'New Skill' : 'Skill Detail' }}
        </h2>
        <div class="flex-1 overflow-hidden">
          <SkillDetail
            v-if="!isCreating"
            :skill-name="selectedSkillName"
            :workspace-id="props.workspaceId"
            @skill-deleted="handleSkillDeleted"
            @skill-saved="handleSkillSaved"
            @error="handleSkillError"
          />
          <!-- Create form. Replaces the detail pane rather than opening a
               dialog over it: the two are the same shape (name, description,
               body), and a modal would hide the list the new row lands in. -->
          <div v-else class="h-full overflow-y-auto p-4 space-y-4" data-testid="skill-create-form">
            <div>
              <label
                class="text-dense block mb-1"
                style="color: var(--semantic-text-muted)"
                for="new-skill-name"
              >
                Name
              </label>
              <input
                id="new-skill-name"
                v-model="newName"
                data-testid="new-skill-name"
                type="text"
                autocomplete="off"
                spellcheck="false"
                placeholder="my-skill"
                class="w-full px-3 h-8 rounded-md text-dense font-mono"
                style="
                  background-color: var(--semantic-bg);
                  color: var(--semantic-text);
                  border: 1px solid var(--color-border);
                "
              />
              <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
                Letters, digits, dot, dash and underscore. This is what <code>use_skill</code> is
                called with, and it cannot be changed later.
              </p>
            </div>

            <div>
              <label
                class="text-dense block mb-1"
                style="color: var(--semantic-text-muted)"
                for="new-skill-description"
              >
                Description
              </label>
              <input
                id="new-skill-description"
                v-model="newDescription"
                data-testid="new-skill-description"
                type="text"
                autocomplete="off"
                spellcheck="false"
                placeholder="One line on when to reach for this skill"
                class="w-full px-3 h-8 rounded-md text-dense"
                style="
                  background-color: var(--semantic-bg);
                  color: var(--semantic-text);
                  border: 1px solid var(--color-border);
                "
              />
            </div>

            <div>
              <label
                class="text-dense block mb-1"
                style="color: var(--semantic-text-muted)"
                for="new-skill-content"
              >
                Content
              </label>
              <textarea
                id="new-skill-content"
                v-model="newContent"
                data-testid="new-skill-content"
                spellcheck="false"
                placeholder="---&#10;name: my-skill&#10;description: ...&#10;---&#10;&#10;When to use this, and how."
                class="w-full min-h-[16rem] p-4 rounded text-dense font-mono resize-y"
                style="
                  background-color: var(--semantic-bg);
                  color: var(--semantic-text);
                  border: 1px solid var(--color-border);
                "
              ></textarea>
              <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
                Stored verbatim, frontmatter included.
              </p>
            </div>

            <div class="flex items-center justify-between gap-4">
              <p
                v-if="createError"
                class="text-dense"
                style="color: var(--color-red)"
                data-testid="skill-create-error"
              >
                {{ createError }}
              </p>
              <p v-else></p>
              <div class="flex gap-2 shrink-0">
                <button
                  @click="closeCreate"
                  class="px-4 h-8 rounded-lg text-body font-medium transition-colors duration-200"
                  style="
                    background-color: var(--semantic-content-bg);
                    color: var(--semantic-text-muted);
                    border: 1px solid var(--color-border);
                  "
                  :disabled="isSaving"
                  data-testid="new-skill-cancel"
                >
                  Cancel
                </button>
                <button
                  @click="handleCreate"
                  class="px-4 h-8 rounded-lg text-body font-medium transition-colors duration-200 disabled:opacity-50"
                  style="background-color: var(--color-violet); color: white"
                  :disabled="!canCreate || isSaving"
                  data-testid="new-skill-save"
                >
                  {{ isSaving ? 'Creating...' : 'Create skill' }}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
