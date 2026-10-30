<script setup lang="ts">
import SkillDetail from '../shell/SkillDetail.vue'
import UiIcon from '../ui/UiIcon.vue'

defineProps<{ skillName: string | undefined }>()
const emit = defineEmits<{ close: [] }>()
</script>

<template>
      <!-- Skill Detail Viewer (shown when view is skill) -->
      <div
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10"
      >
        <!-- Header -->
        <div
          class="h-14 flex items-center justify-between px-4 shrink-0"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <div class="flex items-center gap-3">
            <button
              @click="emit('close')"
              class="p-2 rounded-lg hover:opacity-70 transition-opacity"
              title="Back"
            >
              <svg
                class="w-5 h-5"
                style="color: var(--semantic-text)"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 19l-7-7 7-7"
                />
              </svg>
            </button>
            <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">
              <UiIcon name="brain" class="w-4 h-4" /> {{ skillName }}
            </h2>
          </div>
        </div>
        <!-- Skill Detail Content -->
        <div class="flex-1 overflow-hidden">
          <SkillDetail
            :skill-name="skillName ?? null"
            @skill-deleted="emit('close')"
            @error="(msg) => console.error('Skill error:', msg)"
          />
        </div>
      </div>

</template>
