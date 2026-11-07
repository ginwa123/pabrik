<!--
  ChatAppBar — the ONE app bar every chat surface renders.

  Before this component each workspace-item mode hand-rolled its own
  bar, so the three surfaces disagreed on height, padding, background
  and even which controls lived in it:

    - kanban mode   → ChatView's own inline <header> (h-11, chat
                      column only, `◫` toggle + bare `✕`)
    - agent mode    → AgentChatView's bespoke <header> (px-5 py-3,
                      full width ABOVE the right sidebar, a text
                      "✕ Close" button, no sidebar toggle)
    - folder / memory / chat / routine → no bar at all, the sidebar
                      toggle floated over the transcript

  Switching modes therefore moved the title, jumped the close button
  across the window, and silently dropped the sidebar toggle. This
  component is the single source of truth: ChatView renders it when
  the host sets `showHeader`, and every host (kanban branch,
  AgentChatView, StandardTaskChatView, standalone `chat-<id>`
  branch) sets it, so the bar is
  pixel-identical in all modes.

  It lives INSIDE the chat column, beside the right sidebar, so the
  bar's bottom edge lines up with the sidebar's own "Explorer"
  header and the sidebar keeps its full height.

  Public API:
    props:
      title                string        chat / task name (truncated)
      showSidebarToggle    boolean      render the `◫` changes-sidebar
                                         toggle (default: true). Hosts
                                         that don't own a chat sidebar
                                         (peek panel) pass false.
    emits:
      close                []           user asked to leave the chat
      toggle-sidebar       []           user asked to show/hide the
                                         right sidebar
    slots:
      extras               —            content pinned to the right of
                                         the title, before the buttons
                                         (AgentChatView's SessionSlider)

  It also carries two prop-free controls next to the sidebar toggle: the
  transcript-width control (useChatContentWidth) and the grouped/raw view
  toggle (useChatViewToggle). No props: the bar is shared, so all three modes
  and both the hosted and the bare mount get the identical controls.
-->
<script setup lang="ts">
import { useChatContentWidth } from '../../composables/useChatContentWidth'
import { useChatViewToggle } from '../../composables/useChatViewToggle'

withDefaults(
  defineProps<{
    title: string
    showSidebarToggle?: boolean
  }>(),
  {
    showSidebarToggle: true,
  },
)

const emit = defineEmits<{
  close: []
  'toggle-sidebar': []
}>()

const { label: widthLabel, nextLabel: widthNextLabel, cycleWidth } = useChatContentWidth()
const { label: viewLabel, nextLabel: viewNextLabel, toggle: toggleView } = useChatViewToggle()
</script>

<template>
  <header
    class="h-11 flex items-center gap-2 px-3 shrink-0"
    style="
      background-color: var(--semantic-sidebar-bg);
      border-bottom: 1px solid var(--color-border);
    "
    data-testid="chat-app-bar"
  >
    <span
      class="text-body font-semibold truncate flex-1 min-w-0"
      style="color: var(--semantic-text)"
      data-testid="chat-app-bar-title"
    >
      {{ title }}
    </span>

    <slot name="extras" />

    <button
      type="button"
      class="shrink-0 h-7 px-2 rounded flex items-center gap-1 text-micro hover:opacity-70 transition-opacity"
      style="color: var(--semantic-text-dim)"
      :title="`Showing ${viewLabel.toLowerCase()}. Click for ${viewNextLabel.toLowerCase()}.`"
      :aria-label="`View: ${viewLabel}. Click for ${viewNextLabel}.`"
      data-testid="chat-app-bar-view-toggle"
      @click="toggleView"
    >
      <span aria-hidden="true">&#9636;</span>
      <span data-testid="chat-app-bar-view-label">{{ viewLabel }}</span>
    </button>

    <button
      type="button"
      class="shrink-0 h-7 px-2 rounded flex items-center gap-1 text-micro hover:opacity-70 transition-opacity"
      style="color: var(--semantic-text-dim)"
      :title="`Transcript width: ${widthLabel}. Click for ${widthNextLabel}.`"
      :aria-label="`Transcript width: ${widthLabel}. Click for ${widthNextLabel}.`"
      data-testid="chat-app-bar-width-toggle"
      @click="cycleWidth"
    >
      <span aria-hidden="true">⇔</span>
      <span data-testid="chat-app-bar-width-label">{{ widthLabel }}</span>
    </button>

    <button
      v-if="showSidebarToggle"
      type="button"
      class="shrink-0 w-7 h-7 rounded flex items-center justify-center text-body hover:opacity-70 transition-opacity"
      style="color: var(--semantic-text-dim)"
      title="Toggle changes sidebar (Cmd/Ctrl+B)"
      aria-label="Toggle changes sidebar"
      data-testid="chat-app-bar-sidebar-toggle"
      @click="emit('toggle-sidebar')"
    >
      ◫
    </button>

    <button
      type="button"
      class="shrink-0 w-7 h-7 rounded flex items-center justify-center text-title-sm hover:opacity-70 transition-opacity"
      style="color: var(--semantic-text-dim)"
      title="Close chat"
      aria-label="Close chat"
      data-testid="chat-app-bar-close"
      @click="emit('close')"
    >
      ✕
    </button>
  </header>
</template>
