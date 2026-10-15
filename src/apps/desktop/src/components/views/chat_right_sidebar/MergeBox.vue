<!--
  MergeBox — the merge action for the PR tab, as a sticky footer.

  WHY A FOOTER: the box belongs under the thing it acts on, and the PR tab's
  file list is the thing. It costs the list nothing until the tab is open, it
  stays put while the list scrolls, and it grows into the confirm step without
  reflowing anything. At the panel's 200px minimum a two-column GitHub box
  (status left, button right) does not fit, so this is one column with a
  full-width button.

  WHY IT READS `status` AND NOT THE CHECKS LIST: `GET /api/git/pr/status`
  already returns `mergeable` + `merge_state` and the tab already polls it
  every 30 s, so the box knows whether it may merge — and why not — with zero
  new requests. The Checks tab is `v-if`-mounted only when clicked, so its data
  does not exist here.

  FALLIBILITY IS IN THE TYPE (no try/catch): `mergePr`'s Effect keeps the
  failure, and the failure is RENDERED — the server's own words ("Pull request
  is not mergeable") land in the strip above the button, never in a toast that
  scrolls away and never as a silent no-op.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { Effect } from 'effect'
import { mergePr, type GitPrStatus } from '../../../api'
import { forgeWording } from '../../../helpers/forgeWording'
import { invalidatePrStatus } from '../../../helpers/prStatusCache'
import {
  MERGE_METHODS,
  mergeWording,
  methodDetail,
  methodLabel,
  rememberedMethod,
  rememberMethod,
  repoKeyFor,
  type MergeMethod,
} from '../../../helpers/mergeWording'
import { SyncRemoteError } from '../../../sync/SyncError'
import { runSyncResult } from '../../../sync/runtime'

const props = defineProps<{
  cwd: string
  prUrl: string
  prProvider?: string
  /** The live status payload from the PR tab's 30 s poll. */
  status: GitPrStatus | null
}>()

const emit = defineEmits<{
  /** A merge was attempted and the forge answered. The owner re-reads status. */
  merged: []
}>()

const forge = computed(() => forgeWording(props.prProvider))

const wording = computed(() =>
  mergeWording({
    status: props.status?.status ?? '',
    mergeable: props.status?.mergeable ?? '',
    mergeState: props.status?.merge_state ?? '',
    forge: forge.value,
    baseRef: props.status?.base_ref ?? '',
  }),
)

/** The PR's already-known merge state, so the box never renders a spinner for
 *  something the poll already answered. */
const ready = computed(() => props.status !== null)

const dotClass = computed(() => {
  switch (wording.value.state) {
    case 'ready':
    case 'merged':
      return 'bg-[var(--color-green)]'
    case 'caution':
      return 'bg-[var(--color-yellow)]'
    case 'blocked':
    case 'closed':
      return 'bg-[var(--semantic-error)]'
    default:
      return 'bg-[var(--color-border-light)]'
  }
})

const dotGlyph = computed(() => {
  switch (wording.value.state) {
    case 'ready':
    case 'merged':
      return '✓'
    case 'caution':
      return '!'
    case 'blocked':
    case 'closed':
      return '×'
    default:
      return ''
  }
})

// ── the method, remembered per repo ───────────────────────────────────────
const repoKey = computed(() => repoKeyFor(props.prUrl, props.cwd))
/** The method shown and used. No watcher: a `watch` that copies the remembered value into a ref is
 * banned here (local/no-watch), and it is not needed — the remembered value is a pure function of
 * the repo key, so a `computed` reads it lazily. */
/** A pick is tagged with the key it belongs to, so a different change request on the same mounted
 * box falls back to ITS repo's memory instead of carrying the previous choice over. */
const picked = ref<{ key: string; method: MergeMethod } | null>(null)
const method = computed<MergeMethod>(() => {
  const key = repoKey.value
  return picked.value?.key === key ? picked.value.method : rememberedMethod(key)
})

// ── the confirm step ──────────────────────────────────────────────────────
const menuOpen = ref(false)
const confirming = ref(false)
/**  * OFF by default. In this app the source branch is usually the session's OWN worktree branch, so a
 * pre-ticked box could delete the branch the user is standing on. The name is always shown next to
 * it. */
const deleteBranch = ref(false)
const message = ref('')

const target = computed(() => props.status?.base_ref || 'the base branch')

const defaultMessage = computed(() => {
  const n = props.status?.number ? `#${props.status.number}` : 'this change request'
  if (method.value === 'squash') {
    const title = (props.status?.title ?? '').trim()
    return title ? `${title} (${n})` : n
  }
  return `Merge ${forge.value.short} ${n} from ${props.status?.head_ref || 'the head branch'}`
})

function pick(m: MergeMethod) {
  picked.value = { key: repoKey.value, method: m }
  menuOpen.value = false
}

function openConfirm() {
  message.value = defaultMessage.value
  confirming.value = true
  menuOpen.value = false
}

// ── the merge itself ──────────────────────────────────────────────────────
const busy = ref(false)
/** Rendered inline, never swallowed. */
const error = ref<string | null>(null)
/** Accepted, not merged: the forge took the command without merging. */
const pendingNotice = ref(false)

async function submit() {
  if (busy.value) return
  busy.value = true
  error.value = null
  pendingNotice.value = false
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        mergePr(props.cwd, props.prUrl, {
          provider: props.prProvider || undefined,
          method: method.value,
          title: message.value.trim() || undefined,
          // The head guard: merge only the commit the user was looking at.
          head_sha: props.status?.head_sha || undefined,
          delete_branch: deleteBranch.value,
        }),
      catch: (e) =>
        new SyncRemoteError({
          op: 'prMerge',
          reason: e instanceof Error ? e.message : String(e),
        }),
    }),
    'prMerge',
  )
  busy.value = false
  if (!result.ok) {
    error.value = result.reason
    return
  }
  rememberMethod(repoKey.value, method.value)
  confirming.value = false
  // `success` is the FORGE's answer, not an exit code. A zero exit that only armed an auto-merge
  // (GitLab) or joined a merge queue (GitHub) is `pending`, and saying "Merged" for it is the one
  // failure a merge button cannot afford.
  pendingNotice.value = result.value.pending
  // The merge moved this BRANCH's change-request state, and the sidebar's RECENT icon and the
  // kanban card badge read the shared 60s cache — which still holds the `open` answer they fetched
  // before this click. Drop it and call the registered badges back so they re-read now.
  // Without this the icon stays green until the row happens to remount. (The `git_pr_state` SSE
  // event does the same for every OTHER client.)
  if (props.status?.head_ref) invalidatePrStatus(props.cwd, props.status.head_ref)
  emit('merged')
}
</script>

<template>
  <div
    v-if="ready"
    class="shrink-0 border-t"
    style="border-color: var(--color-border); background-color: var(--color-bg)"
    data-testid="pr-merge-box"
  >
    <!-- the verdict -->
    <div class="flex items-start gap-2 px-3 pt-2">
      <span
        class="w-3.5 h-3.5 shrink-0 mt-0.5 rounded-full flex items-center justify-center text-micro font-bold"
        :class="[dotClass, wording.state === 'pending' ? 'animate-spin' : '']"
        :style="{ color: 'var(--color-bg)' }"
        aria-hidden="true"
        >{{ dotGlyph }}</span
      >
      <div class="min-w-0">
        <div
          class="text-dense font-semibold leading-tight"
          style="color: var(--semantic-text)"
          data-testid="pr-merge-headline"
        >
          {{ wording.headline }}
        </div>
        <!-- Disabled is never silent: the reason is a visible sentence, not a
             title attribute. At 200px a tooltip is unreachable anyway. -->
        <div
          v-if="wording.detail"
          class="text-micro leading-snug"
          style="color: var(--semantic-text-muted)"
          data-testid="pr-merge-detail"
        >
          {{ wording.detail }}
        </div>
      </div>
    </div>

    <div
      v-if="pendingNotice"
      class="mx-3 mt-2 px-2 py-1 rounded text-micro"
      style="background-color: color-mix(in srgb, var(--color-yellow) 14%, transparent)"
      data-testid="pr-merge-pending"
    >
      Accepted, but {{ forge.forge }} has not merged it yet. Refresh in a moment to see where it
      landed.
    </div>

    <div
      v-if="error"
      class="mx-3 mt-2 px-2 py-1.5 rounded text-micro break-words"
      style="
        background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
        color: var(--semantic-error);
        white-space: pre-wrap;
      "
      data-testid="pr-merge-error"
    >
      {{ error }}
    </div>

    <!-- the confirm step -->
    <div
      v-if="confirming"
      class="px-3 pt-2 pb-3 border-t mt-2"
      style="border-color: var(--color-border)"
    >
      <div
        class="text-dense font-semibold"
        style="color: var(--semantic-text)"
        data-testid="pr-merge-confirm-heading"
      >
        {{ methodLabel(method) }} into {{ target }}
      </div>
      <div class="text-micro mt-0.5" style="color: var(--semantic-text-muted)">
        {{ methodDetail(method, target) }}
      </div>
      <textarea
        v-model="message"
        spellcheck="false"
        rows="3"
        class="w-full mt-1.5 px-1.5 py-1 rounded font-mono text-micro resize-none"
        style="
          background-color: var(--color-bg-p1);
          color: var(--semantic-text);
          border: 1px solid var(--color-border-light);
        "
        data-testid="pr-merge-message"
      />
      <button
        type="button"
        class="w-full h-7 mt-1.5 rounded text-dense font-semibold disabled:opacity-60"
        style="background-color: var(--color-green); color: var(--color-bg)"
        :disabled="busy"
        data-testid="pr-merge-confirm"
        @click="submit"
      >
        {{ busy ? 'Merging…' : `Confirm ${methodLabel(method).toLowerCase()}` }}
      </button>
      <button
        type="button"
        class="w-full h-6 text-micro"
        style="color: var(--semantic-text-muted)"
        :disabled="busy"
        data-testid="pr-merge-cancel"
        @click="confirming = false"
      >
        Cancel
      </button>
    </div>

    <!-- the button, or why there is no button -->
    <div v-else class="px-3 pt-2 pb-3">
      <label
        v-if="wording.canMerge"
        class="flex items-center gap-1.5 text-micro mb-1.5 cursor-pointer"
        style="color: var(--semantic-text-muted)"
      >
        <input v-model="deleteBranch" type="checkbox" data-testid="pr-merge-delete-branch" />
        <span class="shrink-0">Delete branch</span>
        <span class="truncate font-mono" :title="status?.head_ref || ''">{{
          status?.head_ref || ''
        }}</span>
      </label>

      <div class="relative">
        <div
          v-if="menuOpen"
          class="absolute left-0 right-0 bottom-full mb-1 rounded-md p-1 z-10"
          style="
            background-color: var(--color-bg-p1);
            border: 1px solid var(--color-border-light);
            box-shadow: 0 8px 22px rgba(0, 0, 0, 0.55);
          "
          data-testid="pr-merge-menu"
        >
          <button
            v-for="m in MERGE_METHODS"
            :key="m"
            type="button"
            class="w-full text-left px-1.5 py-1.5 rounded"
            :style="
              m === method
                ? { boxShadow: 'inset 0 0 0 1.5px var(--color-violet)' }
                : { boxShadow: 'none' }
            "
            :data-testid="`pr-merge-method-${m}`"
            @click="pick(m)"
          >
            <span class="text-dense font-semibold block" style="color: var(--semantic-text)">
              {{ m === method ? '✓ ' : '' }}{{ methodLabel(m) }}
            </span>
            <span class="text-micro block" style="color: var(--semantic-text-muted)">
              {{ methodDetail(m, target) }}
            </span>
          </button>
        </div>

        <div class="flex">
          <button
            type="button"
            class="h-8 flex-1 min-w-0 px-2 rounded-l text-dense font-semibold truncate disabled:cursor-not-allowed"
            :style="
              wording.canMerge
                ? { backgroundColor: 'var(--color-green)', color: 'var(--color-bg)' }
                : { backgroundColor: 'var(--color-bg-p1)', color: 'var(--semantic-text-dim)' }
            "
            :disabled="!wording.canMerge || busy"
            :title="wording.canMerge ? '' : wording.headline"
            data-testid="pr-merge-button"
            @click="openConfirm"
          >
            {{ wording.canMerge ? methodLabel(method) : 'Merge' }}
          </button>
          <button
            v-if="wording.canMerge"
            type="button"
            class="h-8 w-8 rounded-r text-micro shrink-0"
            style="
              background-color: var(--color-green);
              color: var(--color-bg);
              border-left: 1px solid rgba(29, 28, 25, 0.45);
            "
            aria-label="Choose merge method"
            data-testid="pr-merge-caret"
            @click="menuOpen = !menuOpen"
          >
            ▾
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
