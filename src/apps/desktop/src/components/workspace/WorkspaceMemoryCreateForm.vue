<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  saving: boolean
  error: string | null
}>()

const emit = defineEmits<{
  save: [payload: { content: string; tags: string[] }]
  cancel: []
}>()

const content = ref('')
const tags = ref('')

const canSave = computed(() => content.value.trim().length > 0 && !props.saving)

function parseTags(raw: string): string[] {
  return raw
    .split(',')
    .map((tag) => tag.trim())
    .filter((tag) => tag.length > 0)
}

function submit(): void {
  const body = content.value.trim()
  if (!body) return
  emit('save', { content: body, tags: parseTags(tags.value) })
}
</script>

<template>
  <div
    class="mb-3 px-4 py-3 rounded-md space-y-2"
    style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    data-testid="workspace-memories-create-form"
  >
    <label
      class="text-dense block"
      style="color: var(--semantic-text-muted)"
      for="workspace-memory-body"
    >
      Body
    </label>
    <textarea
      id="workspace-memory-body"
      v-model="content"
      data-testid="workspace-memories-create-body"
      rows="5"
      placeholder="The deploy target is staging; production is cut from main on Fridays."
      class="w-full px-3 py-2 rounded-md text-dense resize-y"
      style="
        background-color: var(--semantic-wash);
        color: var(--semantic-text);
        border: 1px solid var(--color-border);
      "
    />
    <label
      class="text-dense block"
      style="color: var(--semantic-text-muted)"
      for="workspace-memory-tags"
    >
      Tags <span style="color: var(--semantic-text-dim)">(comma separated, optional)</span>
    </label>
    <input
      id="workspace-memory-tags"
      v-model="tags"
      data-testid="workspace-memories-create-tags"
      type="text"
      autocomplete="off"
      spellcheck="false"
      placeholder="ops, deploy"
      class="w-full px-3 h-8 rounded-md text-dense"
      style="
        background-color: var(--semantic-wash);
        color: var(--semantic-text);
        border: 1px solid var(--color-border);
      "
    />
    <p
      v-if="error"
      data-testid="workspace-memories-create-error"
      class="text-dense"
      style="color: var(--color-red)"
    >
      {{ error }}
    </p>
    <div class="flex items-center justify-end gap-2">
      <button
        type="button"
        data-testid="workspace-memories-create-cancel"
        class="px-3 h-8 rounded-md text-dense border"
        style="
          border-color: var(--color-border);
          color: var(--semantic-text-muted);
          background-color: transparent;
        "
        :disabled="saving"
        @click="emit('cancel')"
      >
        Cancel
      </button>
      <button
        type="button"
        data-testid="workspace-memories-create-save"
        class="px-3 h-8 rounded-md text-dense font-medium disabled:opacity-50"
        style="background-color: var(--color-violet); color: var(--semantic-on-accent)"
        :disabled="!canSave"
        @click="submit"
      >
        {{ saving ? 'Saving…' : 'Save memory' }}
      </button>
    </div>
  </div>
</template>
