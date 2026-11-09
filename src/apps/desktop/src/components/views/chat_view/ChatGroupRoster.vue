<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import type { GroupMember } from '../../../api'

const props = defineProps<{
  members: GroupMember[]
  lead: string
  isGroup: boolean
  isBusy: boolean
  error: string | null
  agents: Array<{ name: string }>
  /** The agent this chat answers as when no member is routed: the composer's
   * cascade. The panel's own copy promises it, so it has to be named. */
  ownAgent: string
}>()

const emit = defineEmits<{
  add: [agent: string]
  remove: [agent: string]
  'make-lead': [agent: string]
}>()

const open = ref(false)
const rootRef = ref<HTMLElement | null>(null)

const addable = computed(() => {
  const taken = new Set(props.members.map((m) => m.name))
  return props.agents.filter((a) => !taken.has(a.name))
})

const toggle = (): void => {
  open.value = !open.value
}

const closeOnOutsideClick = (e: MouseEvent): void => {
  if (rootRef.value && !rootRef.value.contains(e.target as Node)) open.value = false
}

onMounted(() => document.addEventListener('click', closeOnOutsideClick))
</script>

<template>
  <div ref="rootRef" class="relative shrink-0">
    <button
      type="button"
      class="shrink-0 h-7 px-2 rounded flex items-center gap-1 text-micro hover:opacity-70 transition-opacity"
      :style="isGroup ? 'color: var(--color-violet)' : 'color: var(--semantic-text-dim)'"
      :title="
        isGroup
          ? `Agents in this chat: ${members.map((m) => m.name).join(', ')}`
          : 'Add agents to this chat'
      "
      aria-label="Agents in this chat"
      data-testid="chat-group-roster-toggle"
      @click="toggle"
    >
      <span aria-hidden="true">⚉</span>
      <span data-testid="chat-group-roster-count">{{ members.length }}</span>
    </button>

    <div
      v-if="open"
      class="absolute right-0 top-8 z-30 w-72 p-2 rounded-lg shadow-lg"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="chat-group-roster-panel"
    >
      <p class="px-2 py-1 text-dense font-semibold" style="color: var(--semantic-text)">
        Agents in this chat
      </p>

      <div
        class="px-2 py-1 rounded flex items-center gap-2"
        data-testid="chat-group-own-agent"
      >
        <span class="truncate text-dense font-mono" style="color: var(--semantic-text)">
          {{ ownAgent }}
        </span>
        <span
          class="text-micro px-1 rounded"
          style="color: var(--color-bg); background-color: var(--color-violet)"
          data-testid="chat-group-own-agent-badge"
        >
          this chat
        </span>
      </div>

      <p
        v-if="members.length === 0"
        class="px-2 py-1 text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="chat-group-roster-empty"
      >
        Add an agent and it answers here, beside the chat's own agent.
      </p>

      <div
        v-for="member in members"
        :key="member.name"
        class="px-2 py-1 rounded flex items-center gap-2"
        :data-testid="`chat-group-member-${member.name}`"
      >
        <span class="truncate text-dense font-mono" style="color: var(--semantic-text)">
          {{ member.name }}
        </span>
        <span
          v-if="member.name === lead"
          class="text-micro px-1 rounded"
          style="color: var(--color-bg); background-color: var(--color-violet)"
          data-testid="chat-group-lead-badge"
        >
          lead
        </span>
        <button
          v-if="member.name !== lead"
          type="button"
          class="ml-auto text-micro hover:opacity-70"
          style="color: var(--semantic-text-dim)"
          :disabled="isBusy"
          :data-testid="`chat-group-make-lead-${member.name}`"
          @click="emit('make-lead', member.name)"
        >
          Make lead
        </button>
        <button
          type="button"
          class="text-micro hover:opacity-70"
          :class="member.name === lead ? 'ml-auto' : ''"
          style="color: var(--color-red)"
          :disabled="isBusy"
          :data-testid="`chat-group-remove-${member.name}`"
          @click="emit('remove', member.name)"
        >
          Remove
        </button>
      </div>

      <div
        v-if="addable.length > 0"
        class="mt-1 pt-1"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          v-for="agent in addable"
          :key="agent.name"
          type="button"
          class="w-full text-left px-2 py-1 rounded text-dense hover:opacity-70"
          style="color: var(--semantic-text)"
          :disabled="isBusy"
          :data-testid="`chat-group-add-${agent.name}`"
          @click="emit('add', agent.name)"
        >
          + {{ agent.name }}
        </button>
      </div>

      <p
        v-if="error"
        class="px-2 py-1 text-dense"
        style="color: var(--color-red)"
        data-testid="chat-group-roster-error"
      >
        {{ error }}
      </p>
    </div>
  </div>
</template>
