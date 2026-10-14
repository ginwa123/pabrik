<script setup lang="ts">
import { ref } from 'vue'
import { Effect } from 'effect'
import { updateSkill } from '../../api'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  workspaceId: string
  skillName: string
  checked: boolean
}>()

const emit = defineEmits<{
  changed: [isCanAutoImprove: boolean]
  error: [message: string]
}>()

const isSaving = ref(false)

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const toggle = async (event: Event) => {
  if (isSaving.value) return
  const box = event.target as HTMLInputElement
  const next = box.checked

  isSaving.value = true
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () =>
        updateSkill(props.workspaceId, props.skillName, { is_can_auto_improve: next }),
      catch: (e) => new SyncRemoteError({ op: 'skills.auto_improve', reason: fail(e) }),
    }),
    'skills.auto_improve',
  )
  isSaving.value = false

  if (!result.ok) {
    box.checked = props.checked
    emit('error', result.reason)
    return
  }
  emit('changed', next)
}
</script>

<template>
  <label
    class="flex items-center gap-2 text-dense cursor-pointer select-none"
    style="color: var(--semantic-text-muted)"
    @click.stop
  >
    <input
      type="checkbox"
      class="w-3.5 h-3.5 shrink-0"
      :checked="checked"
      :disabled="isSaving"
      data-testid="skill-auto-improve-toggle"
      @change="toggle"
    />
    <span>Allow AI auto-improve</span>
  </label>
</template>
