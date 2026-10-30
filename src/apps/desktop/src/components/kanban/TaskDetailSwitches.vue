<script setup lang="ts">
import GitBaseBranchSelect from './GitBaseBranchSelect.vue'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  cwd,
  cwdSession,
  handleStartAgent,
  handleUnattendedToggle,
  handleUseGitWorktreeToggle,
  isCreateMode,
  isWorkerRunning,
  props,
  unattended,
  useGitWorktree,
  worktreeBaseBranch,
  worktreePath,
} = useTaskDetailContext()
</script>

<template>
          <!-- Row 2: Unattended mode toggle (always shown).
                   Separated from the pickers by a hairline divider so
                   the toggle reads as its own control, not "part of the
                   picker row". -->
          <div class="ktd-switch-row" data-testid="kanban-task-detail-unattended">
            <div class="ktd-switch-text">
              <div class="text-dense font-medium" style="color: var(--semantic-text-muted)">
                Unattended mode
              </div>
              <div class="text-meta" style="color: var(--semantic-text-muted)">
                Keep retrying past the 10-error limit for overnight runs.
              </div>
            </div>
            <label class="ktd-switch" :class="unattended === '1' ? 'is-on' : ''">
              <input
                type="checkbox"
                :checked="unattended === '1'"
                @change="handleUnattendedToggle"
                class="sr-only peer"
                data-testid="kanban-task-detail-unattended-toggle"
              />
              <span class="ktd-switch-word">{{ unattended === '1' ? 'On' : 'Off' }}</span>
              <span class="ktd-switch-track"><span class="ktd-switch-knob" /></span>
            </label>
          </div>

          <!-- Use-git-worktree toggle (create mode only). Same switch
                   styling as the unattended row above. -->
          <div
            v-if="isCreateMode"
            class="ktd-switch-row"
            data-testid="kanban-task-detail-use-git-worktree"
          >
            <div class="ktd-switch-text">
              <div class="text-dense font-medium" style="color: var(--semantic-text-muted)">
                Use git worktree
              </div>
              <div class="text-meta" style="color: var(--semantic-text-muted)">
                Run the agent in a fresh git worktree so its changes stay isolated from your working
                tree.
              </div>
            </div>
            <label class="ktd-switch" :class="useGitWorktree ? 'is-on' : ''">
              <input
                type="checkbox"
                :checked="useGitWorktree"
                @change="handleUseGitWorktreeToggle"
                class="sr-only peer"
                data-testid="kanban-task-detail-use-git-worktree-toggle"
              />
              <span class="ktd-switch-word">{{ useGitWorktree ? 'On' : 'Off' }}</span>
              <span class="ktd-switch-track"><span class="ktd-switch-knob" /></span>
            </label>
          </div>
          <!-- Worktree path input (create mode only, visible when the
                   toggle is ON). Baked as the `Path:` line after
                   `#Notes UseGitWorktree` in the queue_message. -->
          <div
            v-if="isCreateMode && useGitWorktree"
            class="pt-2 flex flex-col gap-1"
            data-testid="kanban-task-detail-use-git-worktree-path-wrap"
          >
            <label
              class="text-dense font-medium"
              style="color: var(--semantic-text-dim)"
              for="kanban-worktree-path-input"
            >
              Worktree path
            </label>
            <input
              id="kanban-worktree-path-input"
              type="text"
              v-model="worktreePath"
              placeholder="/home/you/.config/pabrik/.worktrees/my-task-1757792000000"
              class="w-full px-2 py-1.5 rounded-lg text-dense"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              data-testid="kanban-task-detail-use-git-worktree-path"
            />
            <div class="text-meta" style="color: var(--semantic-text-muted)">
              Default: $HOME/.config/pabrik/.worktrees/&lt;task-name&gt;-&lt;timestamp&gt;. Must be
              absolute; the parent folder must exist.
            </div>
          </div>
          <!-- Base-branch picker (create mode only, visible when the
                   toggle is ON). Baked as the `Base:` line right after
                   `Path:` in the queue_message, so the agent passes it to
                   `set_git_worktree`'s `base` argument and the worktree is
                   created FROM that ref. -->
          <div
            v-if="isCreateMode && useGitWorktree"
            class="pt-2 flex flex-col gap-1 items-start"
            data-testid="kanban-task-detail-use-git-worktree-base-wrap"
          >
            <GitBaseBranchSelect
              v-model="worktreeBaseBranch"
              :repo-path="cwdSession || cwd"
              data-testid="kanban-task-detail-use-git-worktree-base"
            />
            <div class="text-meta" style="color: var(--semantic-text-muted)">
              Optional but recommended. The new worktree's branch is created from this ref (e.g.
              origin/main). "HEAD (default)" branches from whatever the repo currently has checked
              out.
            </div>
          </div>
          <div v-if="!isCreateMode" class="ktd-thread">
            <span class="ktd-rail-label">Run the agent</span>
            <button
              type="button"
              @click="handleStartAgent"
              :disabled="isWorkerRunning"
              :title="
                isWorkerRunning
                  ? 'A worker is already running on this task — wait for it to finish before starting a new agent.'
                  : 'Trigger the agent on the existing chat context. No new message is queued — the agent resumes whatever context is already in the session.'
              "
              data-testid="kanban-task-detail-start-agent"
              class="ktd-picker w-full text-dense flex items-center justify-center gap-1.5"
            >
              <span aria-hidden="true">▶</span>
              <span>Start agent</span>
              <WorkerElapsedChip
                v-if="isWorkerRunning && props.task"
                :session-id="props.task.id"
                test-id="kanban-task-detail-elapsed"
              />
            </button>
            <p class="text-meta ktd-note" style="color: var(--semantic-text-muted)">
              Resumes this task's own chat context. No new message is queued.
            </p>
          </div>
</template>

<style scoped>
.ktd-rail-label {
  display: block;
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--semantic-text-muted);
  margin-bottom: 5px;
}


.ktd-picker {
  min-height: 30px;
  padding: 5px 8px;
  border-radius: 6px;
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
}


.ktd-switch-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding-top: 12px;
  border-top: 1px solid var(--color-border);
}


.ktd-switch-text {
  min-width: 0;
}


.ktd-switch {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex: 0 0 auto;
  cursor: pointer;
}


.ktd-switch-word {
  font-size: var(--text-meta);
  font-weight: 500;
  color: var(--semantic-text-muted);
}


.ktd-switch.is-on .ktd-switch-word {
  color: var(--semantic-text);
}


.ktd-switch-track {
  position: relative;
  display: inline-block;
  width: 40px;
  height: 22px;
  border-radius: 999px;
  background-color: var(--color-border-light);
  transition: background-color 200ms;
}


.ktd-switch.is-on .ktd-switch-track {
  background-color: var(--color-yellow);
}


.ktd-switch-knob {
  position: absolute;
  top: 2px;
  left: 2px;
  width: 18px;
  height: 18px;
  border-radius: 999px;
  background-color: var(--semantic-text-muted);
  transition:
    left 200ms,
    background-color 200ms;
}


.ktd-switch.is-on .ktd-switch-knob {
  left: 20px;
  background-color: var(--color-bg);
}


.ktd-thread {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding-top: 12px;
  border-top: 1px solid var(--color-border);
}


.ktd-note {
  margin: 0;
}
</style>
