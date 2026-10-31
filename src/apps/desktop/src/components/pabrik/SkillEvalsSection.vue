<script setup lang="ts">
/** SkillEvalsSection — the `skill_evals.enabled` toggle in Pabrik settings. This switch is the ONLY
 * control for the `run_skill_eval` tool. */
import { computed } from 'vue'

export interface SkillEvalsSettings {
  /** Master switch. Mirrors `PabrikConfig.skill_evals.enabled`. */
  enabled: boolean
}

const model = defineModel<SkillEvalsSettings>({ required: true })

/**  * Whether the backend reported the block at all. A config with no `skill_evals` key still comes
 * back with the object (defaults), so this is only false if the GET failed entirely — worth
 * surfacing, because it means the value on screen is a guess rather than the server's state. */
const props = defineProps<{ loaded?: boolean }>()
const isLoaded = computed(() => props.loaded !== false)

/** Assign a FRESH object rather than mutating `model.enabled` in place — `defineModel` only emits
 * `update:modelValue` on reassignment, so an in-place write would leave the orchestrator's watcher
 * (and therefore the dirty pill) unaware that anything changed. */
function onToggle(event: Event) {
  model.value = { ...model.value, enabled: (event.target as HTMLInputElement).checked }
}
</script>

<template>
  <section
    class="flex flex-col gap-4"
    data-testid="skill-evals-section"
    aria-labelledby="skill-evals-heading"
  >
    <header class="flex flex-col gap-1">
      <h3 id="skill-evals-heading" class="text-body font-medium text-neutral-200">Skill Evals</h3>
      <p class="text-dense text-neutral-400">
        Lets the agent review the skills a session actually used and report whether each one still
        helps. Verdicts land in the
        <strong>Evals</strong> tab of the right sidebar, where you can apply them.
      </p>
    </header>

    <label
      class="flex items-start gap-3 cursor-pointer select-none"
      data-testid="skill-evals-toggle-label"
    >
      <input
        type="checkbox"
        data-testid="skill-evals-toggle"
        :checked="model.enabled"
        aria-describedby="skill-evals-note"
        class="mt-0.5 shrink-0 cursor-pointer"
        style="accent-color: var(--color-violet)"
        @change="onToggle"
      />
      <span class="flex flex-col gap-1">
        <span class="text-dense text-neutral-200">Enable skill evals</span>
        <span id="skill-evals-note" class="text-dense text-neutral-400" data-testid="skill-evals-note">
          <template v-if="model.enabled">
            Adds <code>run_skill_eval</code> to the main agent's tools. It runs once per session, at
            the agent's discretion, and spends tokens.
          </template>
          <template v-else>
            Off. The <code>run_skill_eval</code> tool is not offered to the agent at all.
          </template>
          <span v-if="!isLoaded" data-testid="skill-evals-unloaded" class="text-amber-400">
            Could not read the current setting — this may not match the server.
          </span>
        </span>
      </span>
    </label>

    <p class="text-dense text-neutral-500">
      Takes effect on the next agent iteration — no restart needed.
    </p>
  </section>
</template>
