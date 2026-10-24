<script setup lang="ts">
import { ref } from 'vue'

import EmptyState from './EmptyState.vue'
import SettingsSkeleton from './SettingsSkeleton.vue'
import type { PabrikAgent } from '../../api'

/** One row in the Agents tab. The backend stores agents as `Record<name, PabrikAgent>` (name
 * is the map key, not a field on the agent object). The orchestrator flattens this into an array
 * of `AgentRow` with the name attached so the UI can iterate cleanly. */
export interface AgentRow extends PabrikAgent {
  name: string
}

defineProps<{
  modelValue: AgentRow[]
  activeAgent: string | null
  /** True while the parent's config fetch is in flight. */
  loading?: boolean
}>()

const emit = defineEmits<{
  setActive: [name: string]
  // Reset the active agent to "no active" — emitted when the user clicks the Reset button next to
  // the active pill. Parent saves `active_profile: null` to config.json; the backend cascade then
  // falls through to top-level config for every new chat / task.
  clearActive: []
  edit: [agent: AgentRow]
  delete: [name: string]
  add: []
  duplicate: [name: string]
  toggleEnabled: [name: string, enabled: boolean]
}>()

// Track explicit collapses so every agent starts expanded. Using the
// absence of a key as the expanded state also keeps newly added agents
// expanded without watching the prop list.
const collapsed = ref<Set<string>>(new Set())

function agentExpansionKey(name: string): string {
  return `agent:${name}`
}

function isExpanded(key: string): boolean {
  return !collapsed.value.has(key)
}

function toggleExpand(key: string): void {
  const next = new Set(collapsed.value)
  if (next.has(key)) {
    next.delete(key)
  } else {
    next.add(key)
  }
  collapsed.value = next
}

/** 1_000_000 -> "1.0M", 500000 -> "500k". */
function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  return `${Math.round(n / 1_000)}k`
}

/** Absent `enabled` means enabled — every pre-existing profile keeps working. */
function isEnabled(agent: AgentRow): boolean {
  return agent.enabled !== false
}

/** Line 2 of the row: the context window and the compaction threshold. */
function rowSummary(agent: AgentRow): string {
  const cap = agent.max_capacity_tokens
  const thr = agent.compaction_threshold_percent
  const capStr =
    cap === null || cap === undefined ? 'window: catalog' : `window: ${fmtTokens(cap)}`
  const thrStr =
    thr === null || thr === undefined ? 'threshold: 80% (global)' : `threshold: ${thr}%`
  return `${capStr} · ${thrStr}`
}

</script>

<template>
  <div class="space-y-4">
    <!-- Header with active pill + reset button + add button -->
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="text-dense font-mono" style="color: var(--semantic-text-dim);">Active</span>
        <span
          v-if="activeAgent"
          data-testid="active-pill"
          class="text-dense px-2 h-6 inline-flex items-center rounded-md font-mono"
          style="background-color: var(--color-violet); color: #181616;"
        >{{ activeAgent }}</span>
        <span
          v-else
          class="text-dense italic"
          style="color: var(--semantic-text-dim);"
        >(none — pick one below)</span>
        <!-- Reset: only when an agent is currently active. Clears
             active_profile in config.json so the backend cascade falls
             through to top-level config. -->
        <button
          v-if="activeAgent"
          type="button"
          data-testid="reset-active-btn"
          :title="`Clear active agent — every chat will use the top-level config`"
          @click="emit('clearActive')"
          class="px-2 h-6 rounded-md text-micro font-mono border transition-colors duration-150 hover:opacity-80"
          style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
        >Reset</button>
      </div>
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add agent</button>
    </div>

    <!-- Loading placeholder — shown while the parent's config fetch is
         in flight. Without it the EmptyState below fires the instant
         `modelValue.length === 0`, which on a cold load is a false
         "No agents yet". -->
    <SettingsSkeleton v-if="loading" test-id="agents-loading-skeleton" />

    <!-- Empty state -->
    <EmptyState
      v-else-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="⌗"
      title="No agents yet"
      description="Agents are saved LLM configurations you can switch between with one click — or spawn as a sub-agent. Useful for separate API keys, models, or thinking settings."
      cta-label="+ Add agent"
      :cta-action="() => emit('add')"
    />

    <!-- List -->
    <ul v-else class="space-y-2" data-testid="agent-list">
      <li
        v-for="agent in modelValue"
        :key="agent.name"
        class="rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <!-- Row: chevron + name + active + model + buttons -->
        <div class="flex items-center justify-between gap-3 px-4 py-3">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <button
                type="button"
                :aria-label="isExpanded(agentExpansionKey(agent.name)) ? `Collapse agent ${agent.name}` : `Expand agent ${agent.name}`"
                :aria-expanded="isExpanded(agentExpansionKey(agent.name))"
                :data-testid="`expand-btn-${agent.name}`"
                @click="toggleExpand(agentExpansionKey(agent.name))"
                class="w-4 h-4 flex items-center justify-center text-dense font-mono hover:opacity-80"
                style="color: var(--semantic-text-muted);"
              >{{ isExpanded(agentExpansionKey(agent.name)) ? '▼' : '▶' }}</button>
              <span
                v-if="activeAgent === agent.name"
                class="w-1.5 h-1.5 rounded-full"
                style="background-color: var(--color-violet);"
                aria-label="Active"
              />
              <span class="text-body font-medium" style="color: var(--semantic-text);">{{ agent.name }}</span>
              <span
                v-if="activeAgent === agent.name"
                class="text-micro px-1.5 h-5 inline-flex items-center rounded font-mono"
                style="background-color: var(--color-violet); color: #181616;"
              >active</span>
              <span
                v-if="!isEnabled(agent)"
                data-testid="agent-disabled-badge"
                class="text-micro px-1.5 h-5 inline-flex items-center rounded font-mono"
                style="color: var(--semantic-text-dim); border: 1px solid var(--color-border);"
                >disabled</span
              >
              <span style="flex: 1"></span>
            </div>
            <!-- Model + the two facts that decide what this agent does. The
                 base URL is a tooltip: it belongs to the model choice. -->
            <div
              class="text-dense font-mono mt-0.5 truncate"
              style="color: var(--semantic-text-dim);"
              :title="agent.base_url || undefined"
              data-testid="agent-summary"
            >
              {{ agent.model }} · {{ rowSummary(agent) }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              role="switch"
              :aria-checked="isEnabled(agent)"
              :aria-label="`Enable agent ${agent.name}`"
              :data-testid="`agent-enabled-switch-${agent.name}`"
              :title="isEnabled(agent) ? 'Disable this agent' : 'Enable this agent'"
              @click="emit('toggleEnabled', agent.name, !isEnabled(agent))"
              class="relative w-9 h-5 rounded-full shrink-0 transition-colors duration-150"
              :style="{
                backgroundColor: isEnabled(agent) ? 'var(--color-violet)' : 'var(--semantic-content-bg)',
                border: '1px solid ' + (isEnabled(agent) ? 'var(--color-violet)' : 'var(--color-border)'),
              }"
            >
              <span
                aria-hidden="true"
                class="absolute top-1/2 w-3.5 h-3.5 rounded-full transition-all duration-150"
                :style="{
                  transform: 'translateY(-50%)',
                  left: isEnabled(agent) ? '19px' : '3px',
                  backgroundColor: isEnabled(agent) ? 'var(--color-bg)' : 'var(--semantic-text-muted)',
                }"
              />
            </button>
            <button
              v-if="activeAgent !== agent.name && isEnabled(agent)"
              type="button"
              data-testid="set-active-btn"
              @click="emit('setActive', agent.name)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Set active</button>
            <button
              type="button"
              :data-testid="`duplicate-btn-${agent.name}`"
              @click="emit('duplicate', agent.name)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Duplicate</button>
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', agent)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', agent.name)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete agent"
            >⌫</button>
          </div>
        </div>

        <!-- Expanded: the agent's system prompt -->
        <div
          v-if="isExpanded(agentExpansionKey(agent.name))"
          :data-testid="`agent-details-${agent.name}`"
          class="border-t px-4 py-3"
          style="border-color: var(--color-border);"
        >
          <div
            v-if="!isEnabled(agent)"
            data-testid="agent-disabled-hint"
            class="text-dense py-1"
            style="color: var(--semantic-text-muted);"
          >
            Disabled — hidden from <span style="font-family: var(--font-mono)">list_agents</span> and
            from the agent pickers; <span style="font-family: var(--font-mono)">spawn_sub_agent</span>
            cannot run it. Its settings are kept.
          </div>
          <div
            v-if="!agent.system_prompt"
            class="text-dense italic py-1"
            style="color: var(--semantic-text-dim);"
          >
            No system prompt yet — this agent runs with the default one.
          </div>
          <div
            v-else
            class="text-dense"
            style="color: var(--semantic-text-muted); white-space: pre-wrap;"
          >{{ agent.system_prompt }}</div>
        </div>
      </li>
    </ul>
  </div>
</template>
