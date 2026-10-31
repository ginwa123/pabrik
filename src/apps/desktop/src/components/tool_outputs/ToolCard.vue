<script setup lang="ts">
/** ToolCard — the card for ONE tool call. The dispatch that picks the card lives
 * here, so the dev view and the compact view draw the same card. */
import { renderResponse, toolPayloadPreview } from '@/helpers'
import type { SubAgentArgs } from '@/helpers/parseSpawnSubAgentArgs'
import type { SubAgentProgress } from '@/helpers/subagentProgress'
import Glob from '../preview/Glob.vue'
import ShellTool from '../preview/ShellTool.vue'
import UpdateActivity from '../preview/UpdateActivity.vue'
import UseSkill from '../preview/UseSkill.vue'
import AddSkill from './AddSkill.vue'
import EditSkill from './EditSkill.vue'
import GenerateImage from './GenerateImage.vue'
import GetPlan from './GetPlan.vue'
import KanbanList from './KanbanList.vue'
import KanbanMove from './KanbanMove.vue'
import ListAgents from './ListAgents.vue'
import ListDirectory from './ListDirectory.vue'
import ListSearchProviders from './ListSearchProviders.vue'
import LoadMemory from './LoadMemory.vue'
import McpTool from './McpTool.vue'
import PresentFiles from './PresentFiles.vue'
import ProgressiveTool from './ProgressiveTool.vue'
import ReadCompactedMessages from './ReadCompactedMessages.vue'
import ReadFile from './ReadFile.vue'
import ReadWorkspaceSession from './ReadWorkspaceSession.vue'
import RemoveFile from './RemoveFile.vue'
import RemoveSkill from './RemoveSkill.vue'
import SaveMemory from './SaveMemory.vue'
import Search from './Search.vue'
import SearchSkills from './SearchSkills.vue'
import SetGitWorktree from './SetGitWorktree.vue'
import SetPullRequest from './SetPullRequest.vue'
import SpawnSubAgent from './SpawnSubAgent.vue'
import TextReplace from './TextReplace.vue'
import UpdatePlan from './UpdatePlan.vue'
import UsedTools from './UsedTools.vue'
import WebSearch from './WebSearch.vue'
import WriteFile from './WriteFile.vue'
import DiffView from './_shared/DiffView.vue'

export interface ToolCardMessage {
  id: string
  role: string
  content: string
  tool_name?: string
  tool_call_id?: string
  diffview_before?: string
  diffview_after?: string
  tool_calls_json?: string
  finish_reason?: string
}

export interface ToolCardData {
  message: ToolCardMessage
  content: unknown
  parameters: string
  expanded: boolean
  expandKey: string
  subAgentProgress: SubAgentProgress[] | null
  subAgentArgs: SubAgentArgs[] | null
}

defineProps<{
  message: ToolCardMessage
  content: unknown
  parameters: string
  expanded: boolean
  expandKey: string
  cwd: string
  sessionId: string
  subAgentProgress: SubAgentProgress[] | null
  subAgentArgs: SubAgentArgs[] | null
}>()

const emit = defineEmits<{
  'toggle-expand': [key: string]
  'open-session': [sessionId: string]
  peek: [payload: { sessionId: string; agentName: string; instruction: string }]
  'jump-to-line': [line: number]
}>()
</script>

<template>
  <div class="tool-item">
    <ReadFile
      v-if="message.tool_name === 'read_file'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <WriteFile
      v-else-if="message.tool_name === 'write_file'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <UpdateActivity
      v-else-if="message.tool_name === 'update_activity'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <Search
      v-else-if="message.tool_name === 'search'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <ReadWorkspaceSession
      v-else-if="message.tool_name === 'read_workspace_session'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
      @open-session="emit('open-session', $event)"
    />
    <Glob
      v-else-if="message.tool_name === 'glob'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <TextReplace
      v-else-if="message.tool_name === 'text_replace'"
      :content="content"
      :expanded="expanded"
      :diffview-before="message.diffview_before"
      :diffview-after="message.diffview_after"
      :cwd="cwd"
      :parameters="parameters"
    />
    <ShellTool
      v-else-if="
        message.tool_name === 'bash' ||
        message.tool_name === 'pwsh' ||
        message.tool_name === 'run_command' ||
        message.tool_name === 'command'
      "
      :tool-name="
        message.tool_name === 'pwsh' ? 'pwsh' : message.tool_name === 'command' ? 'command' : 'bash'
      "
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <UseSkill
      v-else-if="message.tool_name === 'use_skill'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <SearchSkills
      v-else-if="message.tool_name === 'search_skills'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <AddSkill
      v-else-if="message.tool_name === 'add_skill'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <EditSkill
      v-else-if="message.tool_name === 'edit_skill'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <RemoveSkill
      v-else-if="message.tool_name === 'remove_skill'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <RemoveFile
      v-else-if="message.tool_name === 'remove_file'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <SpawnSubAgent
      v-else-if="message.tool_name === 'spawn_sub_agent'"
      :content="content"
      :expanded="expanded"
      :sub-agent-args="subAgentArgs"
      :progress="subAgentProgress"
      :parameters="parameters"
      @peek="emit('peek', $event)"
    />
    <SetGitWorktree
      v-else-if="message.tool_name === 'set_git_worktree'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <SetPullRequest
      v-else-if="message.tool_name === 'set_pull_request'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <ReadCompactedMessages
      v-else-if="message.tool_name === 'read_compacted_messages'"
      :content="content"
      :expanded="expanded"
      :parameters="parameters"
    />
    <KanbanMove
      v-else-if="message.tool_name === 'kanban_move_task'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <KanbanList
      v-else-if="message.tool_name === 'kanban_list'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <ListDirectory
      v-else-if="message.tool_name === 'list_directory'"
      :content="content"
      :expanded="expanded"
      :cwd="cwd"
      :parameters="parameters"
    />
    <SaveMemory
      v-else-if="message.tool_name === 'save_memory'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <LoadMemory
      v-else-if="message.tool_name === 'load_memory'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <!--
      `update_plan` + `get_plan` (Task 8 — optional UI).
      These render the agent's per-session task plan as
      a checklist card. Both components parse the
      inner envelope themselves and extract the plan
      body from the canonical `<plan><![CDATA[...]]></plan>`
      block — no `parameters` prop threading needed.
      Self-contained (no `expanded` from the dispatcher
      — local toggle is enough for an optional UI).
    -->
    <UpdatePlan v-else-if="message.tool_name === 'update_plan'" :message="message" />
    <GetPlan v-else-if="message.tool_name === 'get_plan'" :message="message" />
    <ListAgents v-else-if="message.tool_name === 'list_agents'" :message="message" />
    <!--
      `used_tools` is the "what do I already have"
      counterpart to `search_tool` ("what else exists").
      Its payload is a flat name/description list, so it
      renders as a dedicated card instead of dumping
      `{"count":10,"tools":[…]}` into the generic
      fallback.
    -->
    <UsedTools v-else-if="message.tool_name === 'used_tools'" :message="message" />
    <!--
      `present_files` renders one inline-preview
      section per file (images full-width, html in
      a sandboxed iframe, text via the shared
      renderer, pdf/video/audio native) plus a
      download action. Cookie-based auth, so plain
      `<a href>` / `<img src>` / `<iframe src>`
      carry credentials. Expanded by default: the
      files ARE the answer, so the set tracks
      user-collapsed rows (inverted vs the other
      cards that track user-expanded rows).
    -->
    <PresentFiles
      v-else-if="message.tool_name === 'present_files'"
      :content="content"
      :session-id="sessionId"
      :cwd="cwd"
      :parameters="parameters"
      :expanded="!expanded"
    />
    <!--
      `generate_image` is expandable. The card shows
      the prompt + model + size + saved file paths;
      the agent's NEXT tool call is `present_files`
      with `files=[{path=<image.path>}]` which renders
      the image inline. This component is informational
      metadata only.
    -->
    <GenerateImage
      v-else-if="message.tool_name === 'generate_image'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <!--
      `web_search` + `list_web_search_providers`.
      The provider's answer is UNTYPED passthrough
      (D13), so the search card renders one
      convention — a top-level `results` array — and
      pretty-prints anything else. The listing card
      shows each provider's curl TEMPLATE, which
      carries `{key}` and never the key itself.
    -->
    <WebSearch
      v-else-if="message.tool_name === 'web_search'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <ListSearchProviders
      v-else-if="message.tool_name === 'list_web_search_providers'"
      :content="content"
      :parameters="parameters"
      :expanded="expanded"
    />
    <!--
      Universal MCP card: ANY `mcp_*` tool (graphify, db,
      context7, future servers) renders here — never in
      the DiffView fallback below. The name check uses
      startsWith so new servers work with zero template
      changes.
    -->
    <McpTool
      v-else-if="message.tool_name?.startsWith('mcp_')"
      :content="content"
      :tool-name="message.tool_name ?? 'mcp_tool'"
      :parameters="parameters"
      :expanded="expanded"
    />
    <!--
      Progressive discovery card: `search_tool` /
      `view_tool` / `use_tool` render here — never in
      the generic fallback below. Same expandable
      ToolCardHeader pattern as McpTool/ListDirectory.
    -->
    <ProgressiveTool
      v-else-if="
        message.tool_name === 'search_tool' ||
        message.tool_name === 'view_tool' ||
        message.tool_name === 'use_tool'
      "
      :content="content"
      :tool-name="message.tool_name ?? 'search_tool'"
      :parameters="parameters"
      :expanded="expanded"
    />
    <div v-else class="tool-expandable">
      <button
        class="tool-summary"
        @click="emit('toggle-expand', expandKey)"
        :style="[
          'cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: background-color 0.15s; text-align: left; width: 100%; border: none; background: transparent; font: inherit; color: inherit;',
          expanded ? 'border-bottom: 1px dashed var(--color-border);' : '',
        ]"
      >
        <span
          v-html="
            renderResponse(
              message.content,
              message.role,
              message.tool_name,
              message.diffview_before,
              message.diffview_after,
              message.finish_reason,
              message.tool_calls_json,
            )
          "
        ></span>
      </button>
      <div v-if="expanded" class="tool-full-content">
        <!--
          Render the diff only when at least one side
          has content. Both-empty (e.g. legacy MCP rows
          whose COALESCE'd "" diffview fields reach the
          wire) renders nothing — the previous
          `!== undefined` check treated "" as present
          and showed a "(no content)" / "(no content)"
          frame (see mcp_graphify_graph_stats bug).
          Empty-before or empty-after alone still
          renders so "new file" / "all deleted" stays
          visible.
        -->
        <DiffView
          v-if="message.diffview_before || message.diffview_after"
          :before="message.diffview_before ?? ''"
          :after="message.diffview_after ?? ''"
          :file-path="message.tool_name"
          @jump-to-line="emit('jump-to-line', $event)"
        />
        <!--
          No diff, no card: this is a tool with no
          registered output component, so the payload
          itself is the content. Pretty-printed and
          capped by the helper (a legacy `add_element`
          row reaches 52 KB). Before this, expanding an
          unregistered tool showed a PREVIEW of the
          payload or, with no diffview columns, an
          entirely empty body.
        -->
        <pre
          v-else-if="toolPayloadPreview(message.content)"
          class="tool-payload text-dense font-mono whitespace-pre-wrap break-all px-2 py-1.5 m-0"
          :style="{ color: 'var(--semantic-text-dim)' }"
          data-testid="tool-payload-preview"
          >{{ toolPayloadPreview(message.content) }}</pre>
      </div>
    </div>
  </div>
</template>
