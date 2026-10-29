<script setup lang="ts">
import CompactionCard from '../../preview/CompactionCard.vue'
import ShellTool from '../../preview/ShellTool.vue'
import SkillInvocationCard from '../../preview/SkillInvocationCard.vue'
import ChatAttachments from '../../chat/ChatAttachments.vue'
import MermaidDiagram from '../../chat/MermaidDiagram.vue'
import PlantUmlDiagram from '../../chat/PlantUmlDiagram.vue'
import D2Diagram from '../../chat/D2Diagram.vue'
import ToolCard, { type ToolCardData } from '../../tool_outputs/ToolCard.vue'
import CompactToolGroup from '../../tool_outputs/compact/CompactToolGroup.vue'
import type { CompactChainItem } from '../../tool_outputs/compact/chain'
import { hasRichBlocks, extractRichBlocks, renderMarkdown } from '@/helpers'
import { hasSkillEnvelope } from '../../../helpers/skillEnvelope'
import { buildHtmlSrcdoc } from '../../../helpers/chatHtmlFrame'
import { useThemeTick } from '../../../composables/useThemeTick'
import type { ChatViewMode } from '../../../stores/chatView'
import type { Message, MessageGroup } from './useChatMessagePresentation'

const themeTick = useThemeTick()

/** The shell is a string of literal colours, so it is rebuilt when the theme changes. */
function htmlFrameSrcDoc(block: string): string {
  void themeTick.value
  return buildHtmlSrcdoc(block)
}

defineProps<{
  group: MessageGroup
  groupIndex: number
  mode: ChatViewMode
  sessionId: string
  chatId: string
  cwd: string
  groupKey: (group: MessageGroup) => string
  isLastGroup: (index: number) => boolean
  isBgOnlyGroup: (group: { role: string; messages: { content?: string }[] }) => boolean
  hasBubbleContent: (group: MessageGroup, groupIndex: number) => boolean
  isCompactionMessage: (msg: { role: string; content: string } | undefined) => boolean
  bgShellData: (m: { content?: string }) => unknown
  isBgUserMsg: (m: { content?: string }) => boolean
  openImagePreview: (url: string) => void
  compactChains: Map<number, CompactChainItem[]>
  standaloneCardsFor: (group: MessageGroup, groupIndex: number) => ToolCardData[]
  toolCardsFor: (group: MessageGroup, groupIndex: number) => ToolCardData[]
  toggleToolExpanded: (msgId: string) => void
  openPeek: (payload: { sessionId: string; agentName: string; instruction: string }) => void
  handleFallbackJumpToLine: (line: number) => void
  onOpenWorkspaceSession: (sessionId: string) => void
  visibleReasoning: (group: MessageGroup) => Message[]
  answeredMessages: (group: MessageGroup) => Message[]
  hasVisibleContent: (m: Message) => boolean
  renderMessageHtml: (msg: Message) => string
}>()
</script>

<template>
  <div
    class="px-4 max-w-[var(--chat-content-max)] mx-auto"
    :class="[groupIndex === 0 ? 'pt-6' : '', isLastGroup(groupIndex) ? 'last-transcript-row' : '']"
    :data-group-key="groupKey(group)"
  >
    <div
      class="flex"
      :class="group.role === 'user' && !isBgOnlyGroup(group) ? 'flex-row-reverse' : 'flex-row'"
    >
      <!-- Bubble / paragraph container.
           2026-08-23 paragraph-mode: the AI (assistant) side no
           longer renders as a chat bubble. The container keeps
           the bubble chrome (padding, rounded corners, card bg,
           border) ONLY for user groups; assistant + tool groups
           render as transparent, borderless paragraphs that flow
           with the page background — like a document, not a
           messenger.
           NOTE: empty groups are already filtered out of
           messageGroups (see the computed) — this v-if is only
           defense-in-depth. Do NOT move it to the slot root:
           an unrendered group keeps its 200px height ESTIMATE
           in the VirtualScroller forever, which desyncs the
           estimated scroll model from the real DOM and blanks
           the whole chat on scrollToBottom. -->
      <div
        class="min-w-0"
        :class="
          group.role === 'user' && !isBgOnlyGroup(group)
            ? 'max-w-[90%] w-fit ml-auto'
            : 'flex-1 w-full max-w-full'
        "
      >
        <div
          v-if="hasBubbleContent(group, groupIndex)"
          class="text-body leading-relaxed"
          role="button"
          tabindex="0"
          :class="
            group.role === 'user' && !isBgOnlyGroup(group)
              ? 'px-4 py-2.5 rounded-2xl whitespace-pre-wrap break-words'
              : 'markdown-content'
          "
          :style="
            group.role === 'user' && !isBgOnlyGroup(group)
              ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
              : 'color: var(--semantic-text);'
          "
        >
          <!-- ── User ── -->
          <template v-if="group.role === 'user'">
            <!-- Compaction envelope: render as a structured card
                 instead of a wall of escaped XML. -->
            <CompactionCard
              v-if="isCompactionMessage(group.messages[0])"
              :content="group.messages[0]!.content"
            />
            <!-- Background completions: role=user on the wire,
                 tool card in pixels — transparent left-aligned
                 tool-sequence, never the blue bubble. -->
            <template v-else-if="isBgOnlyGroup(group)">
              <div class="tool-sequence">
                <div
                  v-for="(bgMsg, bgIdx) in group.messages"
                  :key="bgMsg.id || `bg-${bgIdx}`"
                  class="tool-item"
                  :class="bgIdx < group.messages.length - 1 ? 'tool-item-border' : ''"
                >
                  <ShellTool tool-name="command" :content="bgShellData(bgMsg)" :parameters="'{}'" />
                </div>
              </div>
            </template>
            <!-- 2026-08-23 hidden-messages fix — v-for over ALL
                 messages in the group. The old template rendered
                 only group.messages[0], so consecutive user
                 messages (queue-drain bursts, rapid sends) beyond
                 the first were invisible: their text AND attached
                 images never appeared. Each message renders its
                 own images + text; empty-text messages with
                 images render images only. -->
            <template v-else>
              <template
                v-for="(userMsg, userMsgIdx) in group.messages"
                :key="userMsg.id || `u-${userMsgIdx}`"
              >
                <ChatAttachments
                  v-if="
                    (userMsg.image_urls && userMsg.image_urls.length > 0) ||
                    (userMsg.video_urls && userMsg.video_urls.length > 0) ||
                    (userMsg.file_attachments && userMsg.file_attachments.length > 0)
                  "
                  :image-urls="userMsg.image_urls"
                  :video-urls="userMsg.video_urls"
                  :file-attachments="userMsg.file_attachments"
                  @open-image="openImagePreview"
                />
                <template v-if="isBgUserMsg(userMsg)"
                  ><ShellTool
                    tool-name="command"
                    :content="bgShellData(userMsg)"
                    :parameters="'{}'" /></template
                ><template v-else
                  ><SkillInvocationCard
                    v-if="hasSkillEnvelope(userMsg.content)"
                    :content="userMsg.content || ''"
                  /><span v-else-if="userMsg.content">{{ userMsg.content }}</span></template
                >
              </template>
            </template>
          </template>

          <!-- ── Tool ── -->
          <template v-else-if="group.role === 'tool'">
            <!-- The compact view draws a turn's calls ONCE, at the
                 first tool group of the turn; the turn's later tool
                 groups draw nothing (their calls are in that card). -->
            <template v-if="mode === 'compact'">
              <CompactToolGroup
                v-if="compactChains.has(groupIndex)"
                :items="compactChains.get(groupIndex) ?? []"
                :cwd="cwd"
                :session-id="sessionId || chatId"
                @toggle-expand="toggleToolExpanded"
                @peek="openPeek"
                @jump-to-line="handleFallbackJumpToLine"
                @open-session="onOpenWorkspaceSession"
              />
              <div v-if="standaloneCardsFor(group, groupIndex).length > 0" class="tool-sequence">
                <ToolCard
                  v-for="card in standaloneCardsFor(group, groupIndex)"
                  :key="card.expandKey"
                  v-bind="card"
                  :cwd="cwd"
                  :session-id="sessionId || chatId"
                  @toggle-expand="toggleToolExpanded"
                  @peek="openPeek"
                  @jump-to-line="handleFallbackJumpToLine"
                  @open-session="onOpenWorkspaceSession"
                />
              </div>
            </template>
            <div v-else class="tool-sequence">
              <ToolCard
                v-for="(card, idx) in toolCardsFor(group, groupIndex)"
                :key="card.expandKey"
                v-bind="card"
                :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''"
                :cwd="cwd"
                :session-id="sessionId || chatId"
                @toggle-expand="toggleToolExpanded"
                @peek="openPeek"
                @jump-to-line="handleFallbackJumpToLine"
                @open-session="onOpenWorkspaceSession"
              />
            </div>
          </template>

          <!-- ── Assistant ── -->
          <template v-else-if="group.role === 'assistant'">
            <!-- 2026-08-23 hidden-messages fix — collapsible
                 reasoning section for thinking models. Previously
                 reasoning_content was console.log-only, so a
                 thinking-only turn (empty final text) looked like
                 the agent said nothing. Default-collapsed so long
                 chains-of-thought don't push content off-screen;
                 click to expand. Rendered ABOVE the answer: the
                 reasoning is the context the reply follows from,
                 so it reads first, not as a footnote. -->
            <div
              v-for="(msg, rIdx) in visibleReasoning(group)"
              :key="`reasoning-${rIdx}`"
              class="mt-3 mb-3"
            >
              <details class="assistant-reasoning">
                <summary
                  class="cursor-pointer select-none text-dense font-medium opacity-70 hover:opacity-100"
                  :style="{ color: 'var(--semantic-text-dim)' }"
                >
                  Thought
                </summary>
                <div
                  class="mt-1 whitespace-pre-wrap text-dense leading-relaxed opacity-80 border-l-2 pl-3"
                  :style="{
                    color: 'var(--semantic-text-dim)',
                    'border-color': 'var(--color-border)',
                  }"
                >
                  {{ msg.reasoning_content }}
                </div>
              </details>
            </div>
            <!-- Hide the messages block when every message in the group
                 is empty after stripping thinking tags — this happens
                 on tool_calls-only assistant turns. The tool header
                 (if any) is shown above; we don't want an empty
                 padded area below it. -->
            <div v-if="answeredMessages(group).some(hasVisibleContent)" class="assistant-messages">
              <div
                v-for="(msg, idx) in answeredMessages(group)"
                :key="msg.id || `answer-${idx}`"
                class="assistant-item"
              >
                <!-- <html> and <mermaid> blocks render as themselves;
                     `sandbox="allow-scripts"` with no same-origin is
                     the null-origin security boundary. -->
                <template v-if="msg.role === 'assistant' && hasRichBlocks(msg.content)">
                  <template v-for="(seg, sIdx) in extractRichBlocks(msg.content || '')" :key="sIdx">
                    <!-- eslint-disable-next-line vue/no-v-html -->
                    <span
                      v-if="seg.kind === 'markdown' && seg.payload"
                      v-html="renderMarkdown(seg.payload)"
                    ></span>
                    <iframe
                      v-else-if="seg.kind === 'html' && seg.payload"
                      class="chat-html-frame"
                      sandbox="allow-scripts"
                      scrolling="no"
                      style="overflow: hidden"
                      :srcdoc="htmlFrameSrcDoc(seg.payload)"
                    ></iframe>
                    <MermaidDiagram
                      v-else-if="seg.kind === 'mermaid' && seg.payload"
                      :source="seg.payload"
                    />
                    <PlantUmlDiagram
                      v-else-if="seg.kind === 'plantuml' && seg.payload"
                      :source="seg.payload"
                    />
                    <D2Diagram v-else-if="seg.kind === 'd2' && seg.payload" :source="seg.payload" />
                  </template>
                </template>
                <span v-else v-html="renderMessageHtml(msg)"></span>
              </div>
            </div>
          </template>
        </div>
        <!-- Timestamp is hidden along with the bubble. The bubble
             uses v-if="hasBubbleContent(...)" above; if the
             bubble is hidden, the timestamp would otherwise
             appear orphaned (this was the "timestamps with no
             bubble" visual artifact between tool calls). -->
        <!-- <div -->
        <!--   v-if="hasBubbleContent(group, groupIndex)" -->
        <!--   class="text-dense mt-1 px-1" -->
        <!--   :class="group.role === 'user' ? 'text-right' : 'text-left'" -->
        <!--   style="color: var(--semantic-text-dim)" -->
        <!-- > -->
        <!--   {{ formatTime(group.timestamp) }} -->
        <!-- </div> -->
      </div>
    </div>
  </div>
</template>

<style scoped>
.last-transcript-row {
  padding-bottom: calc(var(--chat-composer-inset) + 1rem);
}

.assistant-messages {
  margin-bottom: 0.375rem;
}

.assistant-item + .assistant-item {
  margin-top: 0.625rem;
}

.chat-html-frame {
  display: block;
  width: 100%;
  min-height: 120px;
  border: 1px solid var(--color-border, #ddd);
  border-radius: 8px;
  background: var(--semantic-card-bg, #1d1c19);
  color-scheme: var(--color-scheme);
  overflow: hidden;
  scrollbar-width: none;
}

.chat-html-frame::-webkit-scrollbar {
  display: none;
}

.markdown-content {
  overflow-wrap: anywhere;
  word-break: break-word;
}

.pill-jump-flash {
  animation: pill-jump-flash 1.2s ease-out;
  border-radius: 12px;
}

@keyframes pill-jump-flash {
  0%,
  100% {
    outline: 2px solid transparent;
    outline-offset: 2px;
  }
  25%,
  60% {
    outline: 2px solid var(--color-violet, #8b5cf6);
    outline-offset: 2px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .pill-jump-flash {
    animation: none;
    outline: 2px solid var(--color-violet, #8b5cf6);
    outline-offset: 2px;
  }
}
</style>
