<!--
  DesignChatDialog — centred modal dialog that hosts the design
  page chat. Opens on top of the design canvas (the canvas stays
  full-width behind a dimmed+blurred backdrop). Click backdrop /
  press Esc / click ✕ to close.

  Same Teleport-modal pattern, sizing and close affordances the
  kanban chat used before it became a tab (plan
  2026-08-06-kanban-chat-as-dialog). The differences from that design are:
    - testid prefix: `design-chat-dialog-*`
    - pageName prop: shown in the header alongside the task name
    - The header reads "Design Chat: <pageName>" when pageName is set,
      otherwise falls back to the task name (matches the FK rewrite

  ChatView is mounted with :show-header="false" so the dialog's own
  header carries the page name + ✕ and we don't double up.

  The :key="'task-' + task.id" on <ChatView> preserves the
  useChatScrollRestore scroll position across task switches and
  forces a fresh mount when the user clicks a different design
  page's 💬 button while the dialog is open (Notion/Linear
  content-swap pattern).

  Public API:
    props:
      show          boolean
      task          Task | null
      workspaceId   string
      itemId        string        (the design item id; for context)
      pageName      string        (→ shown in header)
      projectName   string        (→ ChatView :project-name)
      cwd           string        (→ ChatView :cwd)
    emits:
      update:show   [value: boolean]  (v-model:show)
      close         []                (backward compat with the v-model:show binding style)

  Sizing (2026-08-06 polish): 3rd bump
    - 98vw × 95vh
    - max 1600px × 1200px
    - min 800px × 540px
    - panel background: opaque var(--semantic-content-bg) + glassmorphism
      via backdrop-filter on the panel itself (slightly tints the
      canvas behind the panel edges)
    - backdrop: rgba(0, 0, 0, 0.65) with backdrop-blur
-->
<script setup lang="ts">
import { nextTick, onMounted, onUpdated, ref } from 'vue'
import ChatView from '../views/ChatView.vue'
import type { Task } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    show: boolean
    task: Task | null
    workspaceId?: string
    itemId?: string
    pageName?: string
    projectName?: string
    cwd?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
    pageName: '',
    projectName: '',
    cwd: '',
  },
)

const emit = defineEmits<{
  'update:show': [value: boolean]
  close: []
}>()

const closeDialog = () => {
  emit('update:show', false)
  emit('close')
}

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape') {
    e.stopPropagation()
    closeDialog()
  }
}

// Focus the dialog wrapper on open so Esc works without a prior click.
// (Do NOT auto-focus the chat input — would steal typing position
// from a previously-open chat.)
const dialogRootRef = ref<HTMLDivElement | null>(null)
const focusOnOpen = async () => {
  await nextTick()
  dialogRootRef.value?.focus()
}
// Open guard: focus on mount-with-show plus closed->open updates.
const wasShownChat = ref(props.show)
onMounted(() => {
  if (props.show) void focusOnOpen()
})
onUpdated(() => {
  if (props.show && !wasShownChat.value) void focusOnOpen()
  wasShownChat.value = props.show
})

// Header title: prefer the pageName (matches the FK pair name pattern)
// when set, otherwise fall back to the task name. Mirrors the
// "Design Chat: <pageName>" naming used elsewhere (DesignView).
const headerTitle = (): string => {
  if (props.pageName) return `Design Chat: ${props.pageName}`
  return props.task?.name || 'Chat'
}
</script>

<template>
  <Teleport to="body">
    <!--
      Wrapper fills the viewport. Uses explicit positioning
      (inset-0) for the backdrop layer, then centers the dialog
      panel via absolute top/left + transform translate(-50%, -50%).
      More bulletproof than `flex items-center justify-center`
      in teleported environments.
    -->
    <div
      v-if="show"
      ref="dialogRootRef"
      tabindex="-1"
      class="fixed inset-0 z-50"
      @keydown="handleKeydown"
      data-testid="design-chat-dialog-root"
    >
      <!--
        Backdrop — fills the wrapper (which fills the viewport via
        inset-0). Darker + heavier blur than the standard 0.5/0.5
        so the user's focus is clearly on the dialog. Click here →
        close.
      -->
      <div
        class="absolute inset-0"
        style="
          background: rgba(0, 0, 0, 0.65);
          backdrop-filter: blur(8px);
          -webkit-backdrop-filter: blur(8px);
        "
        data-testid="design-chat-dialog-backdrop"
        @click="closeDialog"
      ></div>

      <!--
        Dialog panel. Explicit centering: top:50%, left:50%, then
        translate(-50%, -50%) to truly center. Sizing is the
        98vw × 95vh (max 1600×1200) 3rd bump, so the design and the
        kanban settings dialogs feel consistent. OPAQUE background so
        the canvas behind reads as a surface behind the panel.
        @click.stop prevents inner clicks from bubbling to the backdrop.
      -->
      <div
        class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 flex flex-col overflow-hidden"
        style="
          background: var(--semantic-content-bg);
          width: 98vw;
          height: 95vh;
          max-width: 1600px;
          max-height: 1200px;
          min-width: 800px;
          min-height: 540px;
          border: 1px solid var(--color-violet);
          border-radius: 14px;
          box-shadow:
            0 0 0 1px rgba(137, 146, 167, 0.15),
            0 12px 40px rgba(0, 0, 0, 0.6),
            0 24px 80px rgba(0, 0, 0, 0.4);
        "
        data-testid="design-chat-dialog"
        @click.stop
      >
        <!--
          Header — the same gradient + layout the other centred
          dialogs use, so they feel consistent. Carries the
          page name + ✕ (ChatView's internal header is suppressed
          via :show-header="false").
        -->
        <header
          class="flex items-center gap-3 px-6 py-3 shrink-0 h-14"
          style="
            background: linear-gradient(
              90deg,
              rgba(137, 146, 167, 0.18),
              rgba(142, 164, 162, 0.1) 70%,
              transparent
            );
            border-bottom: 1px solid var(--color-border);
          "
        >
          <div
            class="w-9 h-9 rounded-lg flex items-center justify-center shrink-0"
            style="
              background: linear-gradient(135deg, var(--color-violet), var(--color-aqua));
              color: var(--color-bg);
            "
            aria-hidden="true"
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
            </svg>
          </div>
          <h3
            class="text-lead font-semibold truncate flex-1"
            style="color: var(--semantic-text)"
            data-testid="design-chat-dialog-title"
          >
            {{ headerTitle() }}
          </h3>
          <button
            type="button"
            class="shrink-0 w-10 h-10 rounded-md flex items-center justify-center text-title-sm transition-all"
            style="
              color: var(--semantic-text-muted);
              background: transparent;
              border: 1px solid transparent;
            "
            data-testid="design-chat-dialog-close"
            aria-label="Close chat"
            title="Close (Esc)"
            @click="closeDialog"
            @mouseover="
              (e) => {
                ;(e.currentTarget as HTMLElement).style.background = 'rgba(196, 116, 110, 0.18)'
                ;(e.currentTarget as HTMLElement).style.color = 'var(--color-red)'
                ;(e.currentTarget as HTMLElement).style.borderColor = 'rgba(196, 116, 110, 0.4)'
              }
            "
            @mouseleave="
              (e) => {
                ;(e.currentTarget as HTMLElement).style.background = 'transparent'
                ;(e.currentTarget as HTMLElement).style.color = 'var(--semantic-text-muted)'
                ;(e.currentTarget as HTMLElement).style.borderColor = 'transparent'
              }
            "
          >
            ✕
          </button>
        </header>

        <!--
          Chat body. ChatView's internal header is suppressed via
          :show-header="false" so the dialog's header above is the
          only chrome. The :key contract preserves the
          useChatScrollRestore scroll position when the user opens
          a different design page's 💬 button (Vue reuses the same
          ChatView instance across the same task id; remounts with
          a new task id → fresh scroll container).
        -->
        <ChatView
          v-if="task"
          :key="'task-' + task.id"
          :chat-id="task.id"
          :chat-name="task.name"
          :type="'task'"
          :cwd="cwd"
          :task-id="task.id"
          :task-name="task.name"
          :project-name="projectName"
          :show-header="false"
          @close="closeDialog"
        />
      </div>
    </div>
  </Teleport>
</template>
