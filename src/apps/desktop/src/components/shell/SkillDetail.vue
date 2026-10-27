<!--
  SkillDetail — one workspace's skill, read and deleted by name.

  There is no `(global)` badge and no path line any more: both described
  a directory, and a skill is a row. What replaced the path is the
  companion-file count, shown only when it is non-zero — a bundled skill
  such as `pdf` (11 files) or `skill-creator` (17) is not one file, and
  telling the user so is the difference between "why does this skill keep
  talking about scripts I don't have" and a legible answer.

  The metadata chips are the SKILL.md frontmatter keys that have no column
  of their own (`origin`, `tags`, `license`). They arrive from the
  `skill_metadata` table, so this pane renders them instead of parsing the
  fence out of `content` a second time — and they are edited through the
  body's own textarea, because the fence IS the file.

  Load and delete keep both outcomes: `runSyncResult` hands back either the
  payload or the reason, and the reason is rendered (or emitted), so a
  failed read cannot present as an empty detail pane.

  Edit mode is a form over the same two fields the row stores. The name is
  NOT one of them: it is the URL path segment, the `use_skill({ name })`
  argument and the `skill_eval` identity, so renaming here would break
  every one of those silently. The form therefore edits description and
  content only, and says so rather than showing a disabled name input
  that invites the attempt.
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import { Effect } from 'effect'
import UiIcon from '../ui/UiIcon.vue'
import SkillAutoImproveToggle from '../ui/SkillAutoImproveToggle.vue'
import { getSkillDetail, deleteSkill, updateSkill, type SkillDetail } from '../../api'
import { countBodyMatches, extractSections, findInBody } from '../../helpers/skillBody'
import { useWorkspacesStore } from '../../stores/workspaces'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  skillName: string | null
  /** Explicit workspace binding. When set, detail reads/deletes in this
   * workspace instead of the active one — the workspace settings page binds
   * the route workspace. Absent = previous behaviour (active workspace). */
  workspaceId?: string | null
}>()

const emit = defineEmits<{
  skillDeleted: [skillName: string]
  /** A save that changed the row, so the list can re-read its description. */
  skillSaved: [skillName: string]
  error: [message: string]
}>()

// The RESOLVED workspace, not the raw `activeWorkspaceId` ref — see
// RightSideBarSkillList.vue / DocumentsView.vue for why. An explicit prop
// wins over the store so a page can show a non-active workspace.
const workspacesStore = useWorkspacesStore()
const workspaceId = computed(() => props.workspaceId ?? workspacesStore.activeWorkspace?.id ?? null)

const skillDetail = ref<SkillDetail | null>(null)
const isLoading = ref(false)
const isDeleting = ref(false)
const isSaving = ref(false)
const error = ref<string | null>(null)
const showDeleteConfirm = ref(false)

// Edit mode. `draft*` are the form's own state, seeded from the loaded row
// when the form opens — never bound straight to `skillDetail`, or a
// half-typed description would render in the read-only header above it.
const isEditing = ref(false)
const draftDescription = ref('')
const draftContent = ref('')
const saveError = ref<string | null>(null)

/** A load needs both halves of the identity; either one missing means
 *  "nothing to show", which is not the same as "nothing there". */
const loadTarget = computed(() => {
  const name = props.skillName
  const ws = workspaceId.value
  return name && ws ? { name, workspaceId: ws } : null
})

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

// Reload when the skill identity changes (prev-value guard on update —
// same fetch the watcher did; the mount call covers the initial load).
async function syncSkillTarget(target: { name: string; workspaceId: string } | null) {
  if (!target) {
    skillDetail.value = null
    error.value = null
    showDeleteConfirm.value = false
    isLoading.value = false
    return
  }

  isLoading.value = true
  error.value = null
  showDeleteConfirm.value = false

  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => getSkillDetail(target.workspaceId, target.name),
      catch: (e) => new SyncRemoteError({ op: 'skills.detail', reason: fail(e) }),
    }),
    'skills.detail',
  )

  isLoading.value = false
  if (!result.ok) {
    skillDetail.value = null
    error.value = result.reason
    return
  }
  if (result.value.error_message) {
    skillDetail.value = null
    error.value = result.value.error_message
    return
  }
  if (result.value.skill) {
    skillDetail.value = result.value.skill
    return
  }
  // Neither a skill nor a reason: say so rather than leaving a blank
  // pane that reads like the load failed.
  skillDetail.value = null
  error.value = `Skill "${target.name}" not found in this workspace`
}

const targetKey = (t: { name: string; workspaceId: string } | null) =>
  t ? `${t.workspaceId}::${t.name}` : ''
let prevSkillTargetKey = targetKey(loadTarget.value)
onMounted(() => {
  prevSkillTargetKey = targetKey(loadTarget.value)
  void syncSkillTarget(loadTarget.value)
})
onUpdated(() => {
  const key = targetKey(loadTarget.value)
  if (key === prevSkillTargetKey) return
  prevSkillTargetKey = key
  void syncSkillTarget(loadTarget.value)
})

/** The frontmatter keys the columns do not hold. Empty hides the row, so a
 *  skill whose fence is just `name`/`description` does not render a strip of
 *  nothing. */
const metadataRows = computed(() => {
  const rows = skillDetail.value?.metadata
  return Array.isArray(rows) ? rows.filter((entry) => entry && entry.key) : []
})

/** Companion files stored beside the body. Zero hides the row entirely. */
const assetCount = computed(() => {
  const raw = skillDetail.value?.asset_count
  const n = typeof raw === 'number' ? raw : Number(raw ?? 0)
  return Number.isFinite(n) && n > 0 ? n : 0
})

// ─── Body navigation ───────────────────────────────────────────────────
// The body was one `<pre>`, so a long skill had no way in but scrolling.
// The outline jumps to a `##` section; the find box lists matching lines.
const bodyQuery = ref('')
const bodyRef = ref<HTMLElement | null>(null)

const sections = computed(() => extractSections(skillDetail.value?.content ?? ''))
const bodyHits = computed(() => findInBody(skillDetail.value?.content ?? '', bodyQuery.value))
const bodyMatchCount = computed(() =>
  countBodyMatches(skillDetail.value?.content ?? '', bodyQuery.value),
)

/** Scroll the body so `line` is at the top, then flash it. */
function jumpToLine(line: number): void {
  const host = bodyRef.value
  if (!host) return
  const target = host.querySelector(`[data-body-line="${line}"]`)
  if (!(target instanceof HTMLElement)) return
  host.scrollTop = Math.max(0, target.offsetTop - host.offsetTop - 8)
  target.classList.add('body-line-flash')
  window.setTimeout(() => target.classList.remove('body-line-flash'), 1200)
}

const onBodyQueryInput = (event: Event) => {
  bodyQuery.value = (event.target as HTMLInputElement).value
}

const clearBodyQuery = () => {
  bodyQuery.value = ''
}

const confirmDelete = () => {
  showDeleteConfirm.value = true
}

const cancelDelete = () => {
  showDeleteConfirm.value = false
}

/** Open the form seeded from the row on screen. */
const startEdit = () => {
  const detail = skillDetail.value
  if (!detail) return
  draftDescription.value = detail.description
  draftContent.value = detail.content
  saveError.value = null
  isEditing.value = true
}

const cancelEdit = () => {
  isEditing.value = false
  saveError.value = null
}

/** A save with nothing changed is refused by the server (409), so the
 * button is disabled rather than letting the user discover that from a
 * toast. Both fields are compared, because either one alone is a change. */
const canSave = computed(() => {
  const detail = skillDetail.value
  if (!detail) return false
  return draftDescription.value !== detail.description || draftContent.value !== detail.content
})

const handleSave = async () => {
  const detail = skillDetail.value
  const ws = workspaceId.value
  if (!detail || !ws) return

  isSaving.value = true
  saveError.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        updateSkill(ws, detail.name, {
          description: draftDescription.value,
          content: draftContent.value,
        }),
      catch: (e) => new SyncRemoteError({ op: 'skills.update', reason: fail(e) }),
    }),
    'skills.update',
  )
  isSaving.value = false

  if (!result.ok) {
    // Kept in the form, not emitted: the user is mid-edit and the reason
    // belongs next to the fields that caused it.
    saveError.value = result.reason
    return
  }
  // The stored row replaces the draft, so the read-only header above
  // shows what was actually written rather than what was typed.
  skillDetail.value = result.value.skill
  isEditing.value = false
  emit('skillSaved', detail.name)
}

const handleAutoImproveChanged = (isCanAutoImprove: boolean) => {
  const detail = skillDetail.value
  if (!detail) return
  detail.is_can_auto_improve = isCanAutoImprove
  // The list row owns its own copy of the flag, so the left pane has to
  // re-read or the two halves disagree about who may edit this skill.
  emit('skillSaved', detail.name)
}

const handleToggleError = (message: string) => {
  emit('error', message)
}

const handleDelete = async () => {
  const detail = skillDetail.value
  const ws = workspaceId.value
  if (!detail || !ws) return

  isDeleting.value = true
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => deleteSkill(ws, detail.name),
      catch: (e) => new SyncRemoteError({ op: 'skills.delete', reason: fail(e) }),
    }),
    'skills.delete',
  )
  isDeleting.value = false

  if (!result.ok) {
    emit('error', result.reason)
    return
  }
  if (result.value.success) {
    showDeleteConfirm.value = false
    emit('skillDeleted', detail.name)
  } else {
    emit('error', result.value.error_message || 'Failed to delete skill')
  }
}
</script>

<template>
  <div class="skill-detail h-full flex flex-col overflow-hidden" data-testid="skill-detail">
    <!-- Empty State -->
    <div
      v-if="!skillName"
      class="flex-1 flex items-center justify-center"
      data-testid="skill-detail-empty"
    >
      <p class="text-body" style="color: var(--semantic-text-muted)">
        Select a skill to view details
      </p>
    </div>

    <!-- Loading State — skeleton holds the detail pane's height (header +
         body) instead of collapsing it to one centered row. -->
    <div
      v-else-if="isLoading"
      class="flex-1 overflow-y-auto p-4"
      data-testid="skill-detail-skeleton"
    >
      <div class="space-y-3">
        <div
          class="h-6 w-1/2 rounded animate-pulse"
          style="background-color: var(--semantic-active-bg)"
        />
        <div
          class="h-4 w-1/3 rounded animate-pulse"
          style="background-color: var(--semantic-active-bg)"
        />
        <div
          v-for="w in ['100%', '96%', '88%', '92%', '70%']"
          :key="w"
          class="h-4 rounded animate-pulse"
          :style="{ width: w, backgroundColor: 'var(--semantic-active-bg)' }"
        />
      </div>
    </div>

    <!-- Error State. A failed read renders as a failure, never as an
         empty skill. -->
    <div
      v-else-if="error"
      class="flex-1 flex items-center justify-center"
      data-testid="skill-detail-error"
    >
      <p class="text-body" style="color: var(--color-red)">{{ error }}</p>
    </div>

    <!-- Skill Content -->
    <div v-else-if="skillDetail" class="flex-1 flex flex-col overflow-hidden">
      <!-- Header -->
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border)">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-3">
            <UiIcon name="tools" size-class="w-4.5 h-4.5" />
            <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">
              {{ skillDetail.name }}
            </h3>
          </div>
          <div class="flex items-center gap-2">
            <button
              v-if="!isEditing"
              @click="startEdit"
              class="px-3 h-8 rounded-lg flex items-center gap-2 text-body font-medium transition-colors duration-200"
              style="
                background-color: var(--semantic-content-bg);
                color: var(--semantic-text-muted);
                border: 1px solid var(--color-border);
              "
              data-testid="skill-edit-btn"
              title="Edit skill"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
              Edit
            </button>
            <button
              @click="confirmDelete"
              class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200"
              style="background-color: rgba(239, 68, 68, 0.1); color: var(--color-red)"
              title="Delete skill"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </button>
          </div>
        </div>
        <p v-if="!isEditing" class="text-body" style="color: var(--semantic-text-muted)">
          {{ skillDetail.description }}
        </p>
        <!-- Edit mode: the description is an input, and the name is
             deliberately absent. It is the `use_skill` argument and the
             `skill_eval` identity, so a rename here would break both
             silently — the form says so instead of offering a disabled
             field that invites the attempt. -->
        <div v-else class="space-y-2">
          <label
            class="text-dense block"
            style="color: var(--semantic-text-muted)"
            for="skill-description"
          >
            Description
          </label>
          <input
            id="skill-description"
            v-model="draftDescription"
            data-testid="skill-edit-description"
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
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            The name is fixed — it is what <code>use_skill</code> and every saved evaluation refer
            to.
          </p>
        </div>
        <!-- Only a bundle has companions. Showing "0 files" on every
             single-file skill would be noise, so the row is conditional. -->
        <p
          v-if="assetCount > 0"
          class="text-dense mt-2"
          style="color: var(--semantic-text-dim)"
          data-testid="skill-detail-assets"
        >
          <span class="font-medium">{{ assetCount }}</span>
          bundled file{{ assetCount === 1 ? '' : 's' }}
        </p>
        <!-- Frontmatter metadata: `origin`, `tags`, `license` and whatever
             else the fence carries beyond name and description. -->
        <div
          v-if="metadataRows.length > 0"
          class="mt-2 flex flex-wrap items-center gap-1.5"
          data-testid="skill-detail-metadata"
        >
          <span
            v-for="entry in metadataRows"
            :key="entry.key"
            class="px-2 py-0.5 rounded text-dense font-mono"
            style="
              background-color: var(--semantic-content-bg);
              color: var(--semantic-text-muted);
              border: 1px solid var(--color-border);
            "
            :data-testid="`skill-metadata-${entry.key}`"
            :title="`${entry.key}: ${entry.value}`"
          >
            <span style="color: var(--semantic-text-dim)">{{ entry.key }}</span>
            <span aria-hidden="true">: </span>{{ entry.value }}
          </span>
        </div>
        <!-- Shown in read AND edit mode: it is a property of the skill, not
             one of the two fields the form edits. -->
        <SkillAutoImproveToggle
          v-if="workspaceId"
          class="mt-2"
          :workspace-id="workspaceId"
          :skill-name="skillDetail.name"
          :checked="skillDetail.is_can_auto_improve"
          @changed="handleAutoImproveChanged"
          @error="handleToggleError"
        />
      </div>

      <!-- Content -->
      <div class="flex-1 overflow-hidden flex flex-col">
        <div class="flex items-center gap-2 px-4 pt-4 pb-2 shrink-0">
          <h4 class="text-body font-medium" style="color: var(--semantic-text)">Content</h4>
          <!-- Find in body. Only in read mode: in edit mode the textarea
               owns the pane and the browser's own find does the job. -->
          <div v-if="!isEditing" class="relative flex items-center ml-auto">
            <input
              :value="bodyQuery"
              @input="onBodyQueryInput"
              @keydown.escape="clearBodyQuery"
              type="text"
              placeholder="Find in body…"
              aria-label="Find text in the skill body"
              class="w-44 pl-2 pr-6 py-1 rounded text-dense outline-none focus:ring-1"
              style="
                background-color: var(--semantic-content-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              data-testid="skill-body-find"
            />
            <button
              v-if="bodyQuery"
              type="button"
              @click="clearBodyQuery"
              class="absolute right-1 w-4 h-4 flex items-center justify-center rounded hover:opacity-80"
              style="color: var(--semantic-text-dim)"
              aria-label="Clear find"
            >
              <span aria-hidden="true">✕</span>
            </button>
          </div>
        </div>

        <!-- Outline + hits. A long skill is a document, and a document
             needs a table of contents more than it needs a scrollbar. -->
        <div
          v-if="!isEditing && (sections.length > 0 || bodyHits.length > 0)"
          class="px-4 pb-2 shrink-0 flex flex-wrap gap-1"
          data-testid="skill-body-nav"
        >
          <button
            v-for="section in sections"
            :key="section.line"
            type="button"
            class="px-2 py-0.5 rounded text-dense hover:opacity-80"
            :style="
              section.depth === 3
                ? 'color: var(--semantic-text-dim); margin-left: 10px;'
                : 'color: var(--semantic-text-muted);'
            "
            @click="jumpToLine(section.line)"
            :data-testid="`skill-body-section-${section.line}`"
          >
            {{ section.title }}
          </button>
        </div>

        <div
          v-if="!isEditing && bodyQuery && bodyHits.length > 0"
          class="px-4 pb-2 shrink-0"
          data-testid="skill-body-hits"
        >
          <p class="text-dense mb-1" style="color: var(--semantic-text-dim)">
            {{ bodyMatchCount }} match{{ bodyMatchCount === 1 ? '' : 'es' }}
          </p>
          <div class="max-h-24 overflow-y-auto space-y-0.5">
            <button
              v-for="hit in bodyHits"
              :key="hit.line"
              type="button"
              class="block w-full text-left px-2 py-0.5 rounded text-dense truncate hover:opacity-80"
              style="color: var(--semantic-text-muted); background-color: var(--semantic-content-bg)"
              @click="jumpToLine(hit.line)"
              :data-testid="`skill-body-hit-${hit.line}`"
            >
              <span class="mono" style="color: var(--semantic-text-dim)">{{ hit.line }}</span>
              {{ hit.text }}
            </button>
          </div>
        </div>

        <div v-if="isEditing" class="flex-1 overflow-y-auto p-4">
          <textarea
            v-model="draftContent"
            data-testid="skill-edit-content"
            spellcheck="false"
            class="w-full h-full min-h-[16rem] p-4 rounded text-dense font-mono resize-y"
            style="
              background-color: var(--semantic-content-bg);
              color: var(--semantic-text-muted);
              border: 1px solid var(--color-border);
            "
          ></textarea>
        </div>

        <!-- The body, one row per line, so a jump has somewhere to land
             and a line can be named in a review comment. -->
        <div
          v-else
          ref="bodyRef"
          class="flex-1 overflow-y-auto px-4 pb-4"
          data-testid="skill-body"
        >
          <pre
            class="text-dense rounded whitespace-pre-wrap break-words"
            style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted)"
          ><template
            v-for="(line, index) in (skillDetail.content ?? '').split('\n')"
            :key="index"
            ><span
              :data-body-line="index + 1"
              :class="{ 'body-line-hit': bodyQuery && line.toLowerCase().includes(bodyQuery.trim().toLowerCase()) }"
              >{{ line }}
</span
            ></template
          ></pre>
        </div>
      </div>

      <!-- Save bar. Only in edit mode, and only once something actually
           changed — the server answers 409 to a no-op patch, so a
           permanently-enabled Save would be a button that fails. -->
      <div
        v-if="isEditing"
        class="p-4 shrink-0 flex items-center justify-between gap-4"
        style="border-top: 1px solid var(--color-border)"
      >
        <p
          v-if="saveError"
          class="text-dense"
          style="color: var(--color-red)"
          data-testid="skill-save-error"
        >
          {{ saveError }}
        </p>
        <p v-else class="text-dense" style="color: var(--semantic-text-dim)">
          The body is stored verbatim, frontmatter included.
        </p>
        <div class="flex gap-2 shrink-0">
          <button
            @click="cancelEdit"
            class="px-4 h-8 rounded-lg text-body font-medium transition-colors duration-200"
            style="
              background-color: var(--semantic-content-bg);
              color: var(--semantic-text-muted);
              border: 1px solid var(--color-border);
            "
            :disabled="isSaving"
            data-testid="skill-edit-cancel"
          >
            Cancel
          </button>
          <button
            @click="handleSave"
            class="px-4 h-8 rounded-lg text-body font-medium transition-colors duration-200 disabled:opacity-50"
            style="background-color: var(--color-violet); color: white"
            :disabled="!canSave || isSaving"
            data-testid="skill-edit-save"
          >
            {{ isSaving ? 'Saving...' : 'Save' }}
          </button>
        </div>
      </div>

      <!-- Delete Confirmation Modal -->
      <div
        v-if="showDeleteConfirm"
        class="absolute inset-0 flex items-center justify-center z-10"
        style="background-color: rgba(0, 0, 0, 0.5)"
      >
        <div
          class="rounded-xl p-6 max-w-sm mx-4"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <h3 class="text-lead font-semibold mb-2" style="color: var(--semantic-text)">
            Delete Skill?
          </h3>
          <p class="text-body mb-4" style="color: var(--semantic-text-muted)">
            Are you sure you want to delete "<strong>{{ skillDetail.name }}</strong
            >"? This action cannot be undone.
          </p>
          <div class="flex gap-3 justify-end">
            <button
              @click="cancelDelete"
              class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
              style="
                background-color: var(--semantic-content-bg);
                color: var(--semantic-text-muted);
                border: 1px solid var(--color-border);
              "
              :disabled="isDeleting"
            >
              Cancel
            </button>
            <button
              @click="handleDelete"
              class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
              style="background-color: var(--color-red); color: white"
              :disabled="isDeleting"
            >
              {{ isDeleting ? 'Deleting...' : 'Delete' }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* A line the find box matched. A tone step, not a colour: the body is
   read as prose, and a saturated highlight fights the text. */
.body-line-hit {
  background-color: var(--semantic-active-bg);
}

/* The line a jump landed on, so the reader sees where they arrived. */
.body-line-flash {
  background-color: var(--color-blue-1);
}
</style>
