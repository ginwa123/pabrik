<script setup lang="ts">
import TaskDetailAgentGroup from './TaskDetailAgentGroup.vue'
import TaskDetailMetadata from './TaskDetailMetadata.vue'
import TaskDetailSkills from './TaskDetailSkills.vue'
import TaskDetailSwitches from './TaskDetailSwitches.vue'
</script>

<template>
        <aside class="ktd-rail">
          <TaskDetailMetadata />
          <TaskDetailAgentGroup />
          <TaskDetailSkills />
          <TaskDetailSwitches />
        </aside>
</template>

<style scoped>
.ktd-rail {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 14px;
  border-radius: 10px;
  background-color: var(--semantic-sidebar-bg);
  border: 1px solid var(--color-border);
  max-width: 460px;
}
</style>
