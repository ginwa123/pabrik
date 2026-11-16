<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type { GroupMember } from '../../../api'

const props = defineProps<{
  members: GroupMember[]
  lead: string
  isGroup: boolean
  isBusy: boolean
  error: string | null
  agents: Array<{ name: string }>
  ownAgent: string
}>()

const emit = defineEmits<{
  add: [agent: string]
  remove: [agent: string]
  'make-lead': [agent: string]
}>()

interface RosterRow {
  name: string
  isOwn: boolean
  isLead: boolean
  isMember: boolean
}

const open = ref(false)
const rootRef = ref<HTMLElement | null>(null)

const rows = computed<RosterRow[]>(() => {
  const own = props.ownAgent.trim()
  if (props.members.length === 0) {
    return own.length > 0 ? [{ name: own, isOwn: true, isLead: false, isMember: false }] : []
  }
  return props.members.map((m) => ({
    name: m.name,
    isOwn: own.length > 0 && m.name === own,
    isLead: m.name === props.lead,
    isMember: true,
  }))
})

const addable = computed(() => {
  const listed = new Set(rows.value.filter((r) => !r.isMember).map((r) => r.name))
  const taken = new Set(props.members.map((m) => m.name))
  return props.agents.filter((a) => !taken.has(a.name) && !listed.has(a.name))
})

const toggle = (): void => {
  open.value = !open.value
}

const closeOnOutsideClick = (e: MouseEvent): void => {
  if (rootRef.value && !rootRef.value.contains(e.target as Node)) open.value = false
}

onMounted(() => document.addEventListener('click', closeOnOutsideClick))
onBeforeUnmount(() => document.removeEventListener('click', closeOnOutsideClick))
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
        v-for="row in rows"
        :key="row.name"
        class="px-2 py-1 rounded flex items-center gap-2"
        :data-testid="row.isMember ? `chat-group-member-${row.name}` : 'chat-group-own-agent'"
      >
        <span class="truncate text-dense font-mono" style="color: var(--semantic-text)">
          {{ row.name }}
        </span>
        <span
          v-if="row.isOwn"
          class="text-micro px-1 rounded"
          style="color: var(--color-bg); background-color: var(--color-violet)"
          data-testid="chat-group-own-agent-badge"
        >
          this chat
        </span>
        <span
          v-if="row.isLead"
          class="text-micro px-1 rounded"
          style="color: var(--color-bg); background-color: var(--color-violet)"
          data-testid="chat-group-lead-badge"
        >
          lead
        </span>
        <div v-if="row.isMember" class="ml-auto flex items-center gap-2 shrink-0">
          <button
            v-if="!row.isLead"
            type="button"
            class="text-micro hover:opacity-70"
            style="color: var(--semantic-text-dim)"
            :disabled="isBusy"
            :data-testid="`chat-group-make-lead-${row.name}`"
            @click="emit('make-lead', row.name)"
          >
            Make lead
          </button>
          <button
            type="button"
            class="text-micro hover:opacity-70"
            style="color: var(--color-red)"
            :disabled="isBusy"
            :data-testid="`chat-group-remove-${row.name}`"
            @click="emit('remove', row.name)"
          >
            Remove
          </button>
        </div>
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
