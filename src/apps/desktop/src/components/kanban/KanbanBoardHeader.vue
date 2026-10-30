<script setup lang="ts">
import InlineEditableText from '../preview/InlineEditableText.vue'
import KanbanSearchInput from './KanbanSearchInput.vue'
import UiIcon from '../ui/UiIcon.vue'
import { useKanbanBoardContext } from './kanbanBoardContext'

const {
  emit,
  handleOpenAgentSettings,
  handleOpenCreateDialog,
  handleOpenSettings,
  item,
  layout,
  onSearchInput,
  openPrList,
  pathPickerBusy,
  prOpenCount,
  prOpenTruncated,
  prPluralLabel,
  rowDensity,
  runAllSummary,
  searchQuery,
  setLayout,
  setRowDensity,
  showPathPicker,
  sortedColumns,
  tasks,
} = useKanbanBoardContext()
</script>

<template>
      <header
        class="flex items-center gap-3 px-3 py-2 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h3
          class="text-body font-semibold truncate flex-1"
          style="color: var(--semantic-text)"
          :data-testid="`kanban-view-${item.id}-title`"
        >
          <InlineEditableText
            :value="item.name"
            :placeholder="'unnamed kanban'"
            :ariaLabel="'kanban name'"
            :testId="`kanban-view-${item.id}-rename`"
            display-class="text-body font-semibold"
            @save="(newName) => emit('renameItem', newName)"
          />
        </h3>

        <!--
        "Set project root" banner — surfaces only when the kanban
        has `path = null` (i.e. it was created before the path field
        existed on the create endpoint). Without a path, every chat
        session in this kanban's tasks is cwd-less and git/file
        tools fail with "no such directory". The button opens the
        same FilePickerDialog used by AddKanbanDialog / AddItemDialog.

        Hidden once a path is set. The CSS uses `path ? null`-
        equivalent check via the explicit v-if (the API returns
        `path: null` for unset kanbans; we treat null AND undefined
        AND empty-string as "needs backfill" defensively).
      -->
        <button
          v-if="!item.path"
          type="button"
          @click="showPathPicker = true"
          :disabled="pathPickerBusy"
          class="shrink-0 px-2 py-1 rounded text-dense font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: rgba(234, 179, 8, 0.18);
            color: rgb(202, 138, 4);
            border: 1px solid rgba(234, 179, 8, 0.4);
          "
          :data-testid="`kanban-view-${item.id}-set-project-root`"
          title="Set a project root so chat sessions have a working directory"
        >
          <span aria-hidden="true">⚠️</span>
          <span class="ml-1">{{ pathPickerBusy ? 'Setting…' : 'Set project root' }}</span>
        </button>
        <KanbanSearchInput :model-value="searchQuery" @update:model-value="onSearchInput" />

        <!-- Layout toggle — Columns (the board) vs Rows (a grouped
             linear list). URL-backed via `?layout=rows`; `columns` is
             the default and is stripped from the URL. -->
        <div
          class="inline-flex rounded overflow-hidden shrink-0"
          style="border: 1px solid var(--color-border)"
          role="tablist"
          aria-label="Kanban layout"
        >
          <button
            type="button"
            role="tab"
            :aria-selected="layout === 'columns'"
            class="px-2 py-1 text-dense border-none cursor-pointer transition-colors"
            :style="
              layout === 'columns'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: transparent; color: var(--semantic-text-muted);'
            "
            :data-testid="`kanban-view-${item.id}-layout-columns`"
            title="Show the board as columns"
            @click="setLayout('columns')"
          >
            <span aria-hidden="true">▦</span><span class="ml-1">Columns</span>
          </button>
          <button
            type="button"
            role="tab"
            :aria-selected="layout === 'rows'"
            class="px-2 py-1 text-dense border-none cursor-pointer transition-colors"
            :style="
              layout === 'rows'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: transparent; color: var(--semantic-text-muted);'
            "
            :data-testid="`kanban-view-${item.id}-layout-rows`"
            title="Show the board as a grouped list"
            @click="setLayout('rows')"
          >
            <span aria-hidden="true">☰</span><span class="ml-1">Rows</span>
          </button>
        </div>

        <!-- Density toggle — Comfortable (two-line record: name +
             metadata) vs Compact (single line). The two-line row is
             right for most columns but a lot of scrolling for a 100+
             row group like `merged`, so this is the escape hatch.
             localStorage-backed, not URL-backed: it is a density
             preference, like group collapse, not a distinct view.
             Only meaningful in row mode, so it is hidden in columns. -->
        <button
          v-if="layout === 'rows'"
          type="button"
          class="px-2 py-1 text-dense rounded shrink-0 cursor-pointer transition-colors"
          style="border: 1px solid var(--color-border); color: var(--semantic-text-muted)"
          :data-testid="`kanban-view-${item.id}-density-toggle`"
          :title="
            rowDensity === 'comfortable'
              ? 'Comfortable rows — name plus metadata. Switch to compact for single-line rows.'
              : 'Compact rows — single line, no metadata. Switch to comfortable for name plus metadata.'
          "
          :aria-label="
            rowDensity === 'comfortable' ? 'Row density: comfortable' : 'Row density: compact'
          "
          :aria-pressed="rowDensity === 'compact'"
          @click="setRowDensity(rowDensity === 'comfortable' ? 'compact' : 'comfortable')"
        >
          <span aria-hidden="true">{{ rowDensity === 'comfortable' ? '☰' : '≡' }}</span>
          <span class="ml-1">{{ rowDensity === 'comfortable' ? 'Comfortable' : 'Compact' }}</span>
        </button>

        <!-- NEW (plan: 2026-08-06-kanban-add-task-button-placement). One
           global + Add task button (replaces per-column footer add
           buttons — see KanbanColumn.vue cleanup). Opens the create
           dialog with the first column pre-selected; the dialog's
           column dropdown lets the user pick a different column.
           Disabled when the kanban has zero columns; the `title`
           attribute explains the disabled state. -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          data-testid="kanban-add-task-button"
          :disabled="sortedColumns.length === 0"
          :title="
            sortedColumns.length ? 'Add a task to this kanban' : 'Add columns first in Settings'
          "
          @click="handleOpenCreateDialog"
        >
          <UiIcon name="plus" />
          <span class="ml-1">Add task</span>
        </button>

        <!-- Board-level change-request list (kanban-pull-request-button).
             Opens the full-cover KanbanPrList (?prs=open). The badge
             shows the open count once the forge answers — it is
             omitted (not 0) until then. Disabled without a project
             root, with the reason visible AND in `title`. -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-pr-button`"
          :disabled="!item.path"
          :title="
            item.path ? `Open the ${prPluralLabel.toLowerCase()} list` : 'Set a project root first'
          "
          @click="openPrList"
        >
          <UiIcon name="pr" />
          <span class="ml-1">{{ prPluralLabel }}</span>
          <span
            v-if="prOpenCount !== null"
            class="ml-1 px-1.5 rounded-full text-micro"
            style="background-color: var(--color-violet); color: var(--color-bg)"
            :data-testid="`kanban-view-${item.id}-pr-count`"
            :title="prOpenTruncated ? `At least ${prOpenCount} open` : `${prOpenCount} open`"
            >{{ prOpenCount }}{{ prOpenTruncated ? '+' : '' }}</span
          >
          <span
            v-else-if="!item.path"
            class="ml-1 text-micro"
            style="color: var(--semantic-text-dim)"
          >
            needs project root
          </span>
        </button>

        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-open-settings`"
          @click="handleOpenSettings"
          title="Open board settings (add columns, edit descriptions)"
        >
          <UiIcon name="settings" />
          <span class="ml-1">Settings</span>
        </button>

        <!-- Agent config (Migration 081, agent-kanbans mirror).
           Navigates to the board's settings page (?tab=tools) — the
           Tools allowlist is mounted there as a tab body
           (KanbanToolsPanel inside KanbanSettingsView). User can
           also visit ?tab=knowledge for the Knowledge + System
           Prompt persona-content panel (KanbanKnowledgePanel). -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-open-agent-settings`"
          @click="handleOpenAgentSettings"
          title="Open agent config in board settings"
        >
          <UiIcon name="robot" />
          <span class="ml-1">Agent</span>
        </button>
      </header>

      <!--
      Search "no matches" banner (kanban task search, Chunk 6). Renders
      only when the backend returned an empty task list AND the user
      has a non-empty search query. Empty-string query is excluded so
      the banner doesn't appear on a freshly-opened empty board.
      Dismissed automatically when the search is cleared or any task
      matches.
    -->
      <div
        v-if="tasks.length === 0 && searchQuery.trim() !== ''"
        class="px-3 py-2 text-dense shrink-0"
        style="color: var(--semantic-text-dim)"
        :data-testid="`kanban-view-${item.id}-no-search-matches`"
      >
        No tasks match "{{ searchQuery }}"
      </div>

      <!--
      NEW (plan: 2026-09-09-run-all-agents-by-column, Task 4, Option C).
      Bulk "Run all agents" summary banner. Rendered after
      `handleRunAllAgents` resolves with the server's
      `{started, skipped, failed}` counts. Run-state visuals stay
      with the existing processingState/SessionSlider SSE flow.
    -->
      <div
        v-if="runAllSummary"
        class="px-3 py-2 text-dense shrink-0"
        style="color: var(--semantic-text)"
        :data-testid="`kanban-view-${item.id}-run-all-summary`"
        role="status"
        aria-live="polite"
      >
        {{ runAllSummary }}
      </div>
</template>
