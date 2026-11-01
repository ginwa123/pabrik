<script setup lang="ts">
import LlmConfigModal, { type LlmConfigModalValue } from './LlmConfigModal.vue'

export interface AgentModalValue extends LlmConfigModalValue {
  system_prompt: string
  enabled?: boolean
}

const props = defineProps<{
  modelValue: AgentModalValue
  errors?: { name?: string; model?: string; base_url?: string; api_key?: string }
  mode: 'add' | 'edit'
  /** The workspace whose secrets the Test probe resolves against. Absent in
   * user scope, where a placeholder cannot be resolved. */
  workspaceId?: string
}>()

const emit = defineEmits<{
  'update:modelValue': [value: AgentModalValue]
  cancel: []
  save: []
}>()

function updateBase(v: LlmConfigModalValue) {
  emit('update:modelValue', {
    ...props.modelValue,
    ...v,
    system_prompt: props.modelValue.system_prompt,
  })
}
function updateSystemPrompt(val: string) {
  emit('update:modelValue', { ...props.modelValue, system_prompt: val })
}
</script>

<template>
  <LlmConfigModal
    :model-value="modelValue"
    :errors="errors"
    :workspace-id="props.workspaceId"
    :title="mode === 'add' ? 'Add agent' : 'Edit agent'"
    :name-editable="true"
    extra-slot-name="extra"
    max-width-class="max-w-2xl"
    @update:model-value="updateBase"
    @cancel="emit('cancel')"
    @save="emit('save')"
  >
    <template #extra>
      <div>
        <label class="block text-dense font-medium mb-1.5" style="color: var(--semantic-text-muted);">
          System prompt
        </label>
        <textarea
          :value="modelValue.system_prompt"
          @input="updateSystemPrompt(($event.target as HTMLTextAreaElement).value)"
          data-testid="agent-system-prompt-input"
          rows="8"
          placeholder="System prompt for this agent…"
          class="w-full px-3 py-2 rounded-md border text-body font-sans resize-none"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
        />
      </div>
    </template>
  </LlmConfigModal>
</template>
