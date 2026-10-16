<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
/** The app's landing page: what Pabrik is, and how to start. */
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'

const router = useRouter()
const workspacesStore = useWorkspacesStore()

const workspaceName = ref('')
const isCreating = ref(false)

async function handleCreateWorkspace() {
  const name = workspaceName.value.trim()
  if (!name || isCreating.value) return
  isCreating.value = true
  try {
    const workspaceId = await workspacesStore.addWorkspace(name)
    workspaceName.value = ''
    // Path form (no trailing slash) — the `/app/:workspaceId` route
    // is registered by the router; components only navigate.
    await router.push('/app/' + workspaceId)
  } finally {
    isCreating.value = false
  }
}
</script>

<template>
  <div
    data-testid="home-landing"
    class="flex flex-col items-center justify-center h-full px-6 text-center"
  >
    <span class="text-display leading-none" style="color: var(--color-violet)" aria-hidden="true"
      >✦</span
    >

    <h1
      data-testid="home-wordmark"
      class="mt-4 text-display-lg font-semibold tracking-tight"
      style="color: var(--semantic-text)"
    >
      pabrik
    </h1>

    <p
      data-testid="home-tagline"
      class="mt-2 text-dense uppercase"
      style="color: var(--semantic-text-muted); letter-spacing: 0.2em"
    >
      AI agent workspace
    </p>

    <p
      data-testid="home-blurb"
      class="mt-6 max-w-[520px] text-body leading-relaxed"
      style="color: var(--semantic-text-muted)"
    >
      Pabrik is an AI agent workspace. It runs your own model against real files: chat with it, break
      the work into kanban tasks, or design in a canvas — with the tools you attach.
    </p>

    <form
      data-testid="home-create-workspace"
      class="mt-8 flex items-center gap-2"
      @submit.prevent="handleCreateWorkspace"
    >
      <input
        v-model="workspaceName"
        data-testid="home-workspace-name"
        type="text"
        class="w-[240px] rounded-md px-3 py-2 text-body"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        placeholder="Workspace name"
        aria-label="Workspace name"
      />
      <button
        type="submit"
        data-testid="home-create-workspace-submit"
        class="rounded-md px-3 py-2 text-body font-semibold transition-opacity hover:opacity-90 disabled:opacity-50"
        style="background-color: var(--color-violet); color: #fff"
        :disabled="!workspaceName.trim() || isCreating"
      >
        Create workspace
      </button>
    </form>

    <p class="mt-10 text-dense" style="color: var(--semantic-text-dim)" data-testid="home-hint">
      Create a workspace, then start a project, kanban, or design canvas inside it.
    </p>
  </div>
</template>
