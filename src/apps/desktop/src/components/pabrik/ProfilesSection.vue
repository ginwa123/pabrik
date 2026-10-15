<script setup lang="ts">
import { ref } from 'vue'

import EmptyState from './EmptyState.vue'
import SettingsSkeleton from './SettingsSkeleton.vue'
import type { PabrikProfile, SubAgent } from '../../api'

/**
 * One row in the Profiles tab. The backend stores profiles as
 * `Record<name, PabrikProfile>` (name is the map key, not a field on
 * the profile object). The orchestrator flattens this into an array
 * of `ProfileRow` with the name attached so the UI can iterate
 * cleanly.
 *
 * `sub_agents` is the profile's OWN sub-agent list (plan
 * 2026-09-04-subagents-per-profile: per-profile only, no global list,
 * no inheritance). Each profile owns its sub-agents; sessions that use
 * this profile resolve `spawn_sub_agent` names against this list only.
 */
export interface ProfileRow extends PabrikProfile {
  name: string
  sub_agents: SubAgent[]
}

defineProps<{
  modelValue: ProfileRow[]
  activeProfile: string | null
  /** True while the parent's config fetch is in flight. */
  loading?: boolean
}>()

const emit = defineEmits<{
  setActive: [name: string]
  // Reset the active profile to "no active" — emitted when the user clicks the Reset button next to
  // the active pill. Parent saves `active_profile: null` to config.json; the backend cascade then
  // falls through to top-level config for every new chat / task.
  clearActive: []
  edit: [profile: ProfileRow]
  delete: [name: string]
  add: []
  addSubAgent: [profileName: string]
  editSubAgent: [profileName: string, subAgent: SubAgent]
  deleteSubAgent: [profileName: string, subAgentName: string]
}>()

// Track explicit collapses so every profile starts expanded. Using the
// absence of a key as the expanded state also keeps newly added profiles
// expanded without watching the prop list.
const collapsed = ref<Set<string>>(new Set())

function profileExpansionKey(name: string): string {
  return `profile:${name}`
}

function subAgentExpansionKey(profileName: string, subAgentName: string): string {
  return `sub-agent:${profileName}:${subAgentName}`
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

/** Line 2 of the row.
 * The old row printed the full base URL, a sub-agent count, and
 * `Compaction: 97% @ 1000k tokens` — four lines that mostly restated the raw
 * fields. This states the two facts that decide what the profile DOES:
 * where the context window comes from, and where compaction fires. A `null`
 * override is not "default" (which read as "nothing is going on"); it is
 * "the catalog's window" and "the global threshold". */
function rowSummary(profile: ProfileRow): string {
  const cap = profile.max_capacity_tokens
  const thr = profile.compaction_threshold_percent
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
          v-if="activeProfile"
          data-testid="active-pill"
          class="text-dense px-2 h-6 inline-flex items-center rounded-md font-mono"
          style="background-color: var(--color-violet); color: #181616;"
        >{{ activeProfile }}</span>
        <span
          v-else
          class="text-dense italic"
          style="color: var(--semantic-text-dim);"
        >(none — pick one below)</span>
        <!-- Reset: only when a profile is currently active. Clears
             active_profile in config.json so the backend cascade falls
             through to top-level config. -->
        <button
          v-if="activeProfile"
          type="button"
          data-testid="reset-active-btn"
          :title="`Clear active profile — every chat will use the top-level config`"
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
      >+ Add profile</button>
    </div>

    <!-- Loading placeholder — shown while the parent's config fetch is
         in flight. Without it the EmptyState below fires the instant
         `modelValue.length === 0`, which on a cold load is a false
         "No profiles yet". -->
    <SettingsSkeleton v-if="loading" test-id="profiles-loading-skeleton" />

    <!-- Empty state -->
    <EmptyState
      v-else-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="⌗"
      title="No profiles yet"
      description="Profiles are saved LLM configurations you can switch between with one click. Useful for separate API keys, models, or thinking settings."
      cta-label="+ Add profile"
      :cta-action="() => emit('add')"
    />

    <!-- List -->
    <ul v-else class="space-y-2" data-testid="profile-list">
      <li
        v-for="profile in modelValue"
        :key="profile.name"
        class="rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <!-- Row: chevron + name + active + model + buttons -->
        <div class="flex items-center justify-between gap-3 px-4 py-3">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <button
                type="button"
                :aria-label="isExpanded(profileExpansionKey(profile.name)) ? `Collapse profile ${profile.name}` : `Expand profile ${profile.name}`"
                :aria-expanded="isExpanded(profileExpansionKey(profile.name))"
                :data-testid="`expand-btn-${profile.name}`"
                @click="toggleExpand(profileExpansionKey(profile.name))"
                class="w-4 h-4 flex items-center justify-center text-dense font-mono hover:opacity-80"
                style="color: var(--semantic-text-muted);"
              >{{ isExpanded(profileExpansionKey(profile.name)) ? '▼' : '▶' }}</button>
              <span
                v-if="activeProfile === profile.name"
                class="w-1.5 h-1.5 rounded-full"
                style="background-color: var(--color-violet);"
                aria-label="Active"
              />
              <span class="text-body font-medium" style="color: var(--semantic-text);">{{ profile.name }}</span>
              <span
                v-if="activeProfile === profile.name"
                class="text-micro px-1.5 h-5 inline-flex items-center rounded font-mono"
                style="background-color: var(--color-violet); color: #181616;"
              >active</span>
              <span style="flex: 1"></span>
              <span
                v-if="profile.sub_agents && profile.sub_agents.length > 0"
                class="text-micro font-mono shrink-0"
                style="color: var(--color-violet);"
              >▾ {{ profile.sub_agents.length }} sub-agent{{ profile.sub_agents.length === 1 ? '' : 's' }}</span>
              <span v-else class="text-micro font-mono shrink-0" style="color: var(--semantic-text-dim);">no sub-agents</span>
            </div>
            <!-- Model + the two facts that decide what this profile does. The
                 base URL is a tooltip: it belongs to the model choice. -->
            <div
              class="text-dense font-mono mt-0.5 truncate"
              style="color: var(--semantic-text-dim);"
              :title="profile.base_url || undefined"
              data-testid="profile-summary"
            >
              {{ profile.model }} · {{ rowSummary(profile) }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              v-if="activeProfile !== profile.name"
              type="button"
              data-testid="set-active-btn"
              @click="emit('setActive', profile.name)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Set active</button>
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', profile)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', profile.name)"
              class="px-2.5 h-7 rounded-md text-dense transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete profile"
            >⌫</button>
          </div>
        </div>

        <!-- Expanded: per-profile sub-agents list -->
        <div
          v-if="isExpanded(profileExpansionKey(profile.name))"
          :data-testid="`sub-agents-list-${profile.name}`"
          class="border-t px-4 py-3 space-y-2"
          style="border-color: var(--color-border);"
        >
          <div
            v-if="!profile.sub_agents || profile.sub_agents.length === 0"
            class="text-dense italic py-1"
            style="color: var(--semantic-text-dim);"
          >
            No sub-agents yet. Add one below — each profile owns its sub-agents.
          </div>
          <ul v-else class="space-y-2">
            <li
              v-for="sa in profile.sub_agents"
              :key="sa.name"
              class="px-3 py-2 rounded"
              style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border-light);"
              :data-testid="`profile-sub-agent-${profile.name}-${sa.name}`"
            >
              <div class="flex items-center justify-between gap-2">
                <button
                  type="button"
                  :aria-label="isExpanded(subAgentExpansionKey(profile.name, sa.name)) ? `Collapse sub-agent profile ${sa.name}` : `Expand sub-agent profile ${sa.name}`"
                  :aria-expanded="isExpanded(subAgentExpansionKey(profile.name, sa.name))"
                  :data-testid="`expand-sub-agent-btn-${profile.name}-${sa.name}`"
                  @click="toggleExpand(subAgentExpansionKey(profile.name, sa.name))"
                  class="w-3 h-3 shrink-0 flex items-center justify-center text-micro font-mono hover:opacity-80"
                  style="color: var(--semantic-text-muted);"
                >{{ isExpanded(subAgentExpansionKey(profile.name, sa.name)) ? '▼' : '▶' }}</button>
                <div class="flex-1 min-w-0">
                  <div class="text-dense font-medium" style="color: var(--semantic-text);">{{ sa.name }}</div>
                  <div
                    v-if="isExpanded(subAgentExpansionKey(profile.name, sa.name))"
                    class="min-w-0"
                    :data-testid="`sub-agent-details-${profile.name}-${sa.name}`"
                  >
                    <div class="text-dense font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
                      {{ sa.model }} · {{ sa.base_url || '—' }}
                    </div>
                    <div
                      v-if="sa.system_prompt"
                      class="text-dense mt-1"
                      style="color: var(--semantic-text-muted); white-space: pre-wrap;"
                    >{{ sa.system_prompt }}</div>
                  </div>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <button
                    type="button"
                    :data-testid="`edit-sub-agent-btn-${profile.name}-${sa.name}`"
                    @click="emit('editSubAgent', profile.name, sa)"
                    class="px-2 h-6 rounded text-dense border transition-colors duration-150"
                    style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
                  >Edit</button>
                  <button
                    type="button"
                    :data-testid="`delete-sub-agent-btn-${profile.name}-${sa.name}`"
                    @click="emit('deleteSubAgent', profile.name, sa.name)"
                    class="px-2 h-6 rounded text-dense transition-colors duration-150"
                    style="color: var(--color-red);"
                    :aria-label="`Delete sub-agent ${sa.name}`"
                  >⌫</button>
                </div>
              </div>
            </li>
          </ul>
          <button
            type="button"
            :data-testid="`add-sub-agent-btn-${profile.name}`"
            @click="emit('addSubAgent', profile.name)"
            class="px-2.5 h-7 rounded text-dense font-medium border transition-colors duration-150"
            style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
          >+ Add sub-agent</button>
        </div>
      </li>
    </ul>
  </div>
</template>
