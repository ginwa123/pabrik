# A Compact View for chat tool calls

**Status:** proposal, waiting for a human decision. Nothing is implemented.
**Date:** 2026-10-22
**Wireframe:** [`docs/wireframes/chatview-compact-tool-view.html`](../wireframes/chatview-compact-tool-view.html)

## What was asked

"Can we simplify the chatview tool calling? Keep the existing, and add a setting or toggle in
User settings to control the chat view: 1. Compact View, which we add in this task, 2. Dev View,
which is the existing one. Show me a Compact View wireframe before you implement."

So: the Dev View stays, a Compact View is added beside it, a setting in User settings chooses
between them, and the wireframe comes first.

## The wireframe

One standalone HTML file, opened straight from the disk. It shows, in order:

- the **setting**: the new "Chat view" row in the Interface block of
  `Settings → User → General`, with both states of the control;
- the **chat view**: the same turn drawn twice, Compact on the left, Dev on the right, with a live
  read-out that measures the two tool blocks and prints the ratio;
- the **toolbar switch**: the composer toolbar with the new control, and the reason it is called
  "View" and not "Compact";
- the **summary table**: what one compact line shows for each tool;
- the **safety rules**, the **open questions**, and what the design gate measured.

It is interactive: the group row folds and unfolds, the segmented control and the toolbar button
switch the mode, and the read-out is computed from `getBoundingClientRect()` in the same tick it
prints. Verified in `agent-browser` (structure, both sides of every claim, one snapshot per click),
and through the design gate (`lint.mjs` 0 FAIL / 0 WARN, `inspect.mjs` 0 FAIL / 2 defended WARN).

## The design

### The Dev View (today, unchanged)

Every tool call in a `tool` group is its own card: a violet tool-name pill, the primary argument,
the outcome badges, a `+`/`−` toggle, and an expanded body. The cards are already collapsed by
default, so the cost of the Dev View is not the expansion, it is the **number of rows**: a turn that
ran eight tools is eight bordered rows, and the agent's answer ends up below the fold.

### The Compact View (new)

A run of consecutive tool calls (which the chat already groups into one `tool` group) is drawn as:

- **one line per call**: a status dot, the tool name, the one argument you would recognise the call
  by, and the outcome on the right;
- **one group row for the run**: `7 other tool calls · 42.1s · 1 write`, which unfolds into the
  one-liners;
- **the calls that must never hide stay out in the open**: a failed call is lifted out of the group
  and shown on its own line above it, a running call keeps its running state, and `ask_user` and
  `present_files` are always visible because they are the answer or are waiting on you;
- **one click opens the full card**: clicking a compact line opens today's Dev View card for that
  one call, in place. Compact is a rendering, not a downgrade.

Measured on the wireframe: the tool block is **54px** in Compact view against **311px** in Dev view
for the same eight calls, so **5.8× shorter**, with 2 visible rows against 8.

### The summary rule per tool

One line per call, and the line carries the argument that identifies the call:

| Tool | The line shows | Outcome |
| --- | --- | --- |
| `read_file` | the path | ok, and the size |
| `write_file` | the path | written, and the size |
| `text_replace` | the file, and the size of the change | replaced |
| `search` | the pattern, and where it was looked for | the number of hits |
| `glob` | the pattern | the number of files |
| `list_directory` | the directory | the number of entries |
| `command`, `bash`, `pwsh` | the command, after the dollar sign | exit code, failed, running |
| `use_skill`, `search_skills` | the skill name | loaded, or the number of hits |
| `save_memory`, `load_memory` | the id, or the query | saved, or the number of hits |
| `kanban_move_task` | the task and the column it moved to | moved |
| `spawn_sub_agent` | the agent and the task | the number of agents done |
| `present_files` | the file names | shown |
| `ask_user` | the question | waiting, then answered |
| `mcp_*` | the server and the method | ok, or failed |
| anything else | the tool name and its first argument | ok, or failed |

## Where the preference lives

**Decision asked for:** the proposal is app-local, in the app's own storage, beside the setting
that already exists for the same kind of thing.

The evidence for that is in the code:

- `src/apps/desktop/src/components/pabrik/PabrikConfigEditor.vue:1079` — the block that holds
  "Browser-style tabs" is headed *"Interface preferences — app-local (localStorage), not
  config.json"*. A preference about how the chat is drawn belongs in that block, not in
  `config.json` (which is about how the agent runs).
- `src/apps/desktop/src/stores/tabs.ts:91` — `useTabsStore` is the precedent: a pinia store that
  reads its flag from `localStorage` through `userScopedKey()` and defaults to OFF, so the feature
  is opt-in and nothing changes for anyone who has not chosen it.

The alternative is `config.json` (a `chat_view` key next to `notify_on_error`,
`web_launch_enabled` and `retry_delay_ms`). That would travel with the profile and let a workspace
override it, which is more than a rendering preference needs, and it would need a Zig config change
and a restart to take effect. It stays on the table if the human wants the preference to follow the
profile between machines.

**The default must be `dev`.** Two reasons: nobody's chat changes without them asking, and the
Python functional tests in `tests/functional_ui/` assert on the Dev View markup
(`chatview_ui_test.py:241` waits for `shell-tool-pill`, `chatview_tool_calls_json_wire_test.py:143`
waits for `.chat-tool-card`). A fresh browser profile has no stored preference, so those tests
keep seeing the Dev View.

## The implementation

Seven steps, in this order. The order matters: the Dev View must not move until the Compact View
can render every tool it can render today.

### 1. The preference store

New file `src/apps/desktop/src/stores/chatView.ts`, modelled on `stores/tabs.ts`:

```ts
export type ChatViewMode = 'compact' | 'dev'
const KEY = 'pabrik-chatview-mode'

export const useChatViewStore = defineStore('chatView', () => {
  const mode = ref<ChatViewMode>(readMode()) // 'dev' when the key is absent
  function setMode(next: ChatViewMode): void { /* writes userScopedKey(KEY) */ }
  return { mode, setMode }
})
```

`readMode()` returns `'dev'` unless the stored value is exactly `'compact'`, the same shape as
`readEnabled()` in `stores/tabs.ts:80`.

### 2. Extract the tool-card dispatch

Today the 31-branch `v-if` / `v-else-if` chain that picks the card for a tool message lives inline
in the ChatView template, from `ChatView.vue:4080` (`read_file`) down to the generic
`.tool-expandable` fallback at `ChatView.vue:4368`. It is needed in two places (the Dev View, and
the "one click opens the full card" state of the Compact View), so it moves to a new component:

- new `src/apps/desktop/src/components/tool_outputs/ToolCard.vue`, props `message`, `content`,
  `parameters`, `expanded`, `cwd`, and the two slot-scoped helpers `innerToolData` and
  `getParametersForMessage` passed in as props or callbacks;
- `ChatView.vue`'s tool block becomes `<ToolCard ... />` where the chain used to be.

This is the only refactor the feature needs, and it is what keeps the two views from drifting
apart: there is one chain, two renderers.

### 3. The summary helper

New file `src/apps/desktop/src/helpers/toolSummary.ts`:

```ts
export interface ToolSummary {
  tool: string
  primary: string   // the one argument that identifies the call
  status: 'ok' | 'failed' | 'running'
  badge: string     // 'exit 0', 'failed', '142 KB', '12 hits', …
}
export function summarizeTool(tool: string, parameters: string, content: unknown): ToolSummary
```

- **the argument**: `parameters` is the tool-call args, either a JSON string or the XML the backend
  produces (`components/tool_outputs/_shared/toolOutputParser.ts:26` has `extractTag`, and
  `unwrapToolOutput.ts:39` shows both shapes are possible). Parse JSON first, fall back to
  `extractTag`. A per-tool table says which argument is the identifying one (`path`, `command`,
  `pattern`, `query`, …); the fallback is the first non-empty argument.
- **the status**: `normalizeToolContent(content)` (`toolOutputParser.ts:136`) gives the envelope's
  `error`; a non-empty error is `failed`. An empty envelope with a known argument is `running`.
  For the shell family, `parseShell` gives the exit code.
- **the badge**: the size, the hit count, the exit code, depending on the tool.

The helpers already exist and are already used by the cards, so the summary table does not
re-implement parsing.

### 4. The compact components

- new `src/apps/desktop/src/components/tool_outputs/compact/CompactToolRow.vue` — one line, with
  the same token classes the cards use (`--color-violet` for the name, `--semantic-text-dim` for the
  argument, the green/red badges).
- new `src/apps/desktop/src/components/tool_outputs/compact/CompactToolGroup.vue` — the group row,
  the fold, and the hoist of the failed / running / `ask_user` / `present_files` calls.

### 5. The settings row

`src/apps/desktop/src/components/pabrik/PabrikConfigEditor.vue`, in the Interface block next to the
`toggle-browser-tabs` row (line 1093-1096): a "Chat view" row with a two-option segmented
control, `data-testid="row-chat-view"`, `data-testid="chat-view-compact"`,
`data-testid="chat-view-dev"`. It writes the store, not `config.json`, so the block's own
"app-local (localStorage), not config.json" comment stays true.

### 6. The ChatView wiring

`ChatView.vue`:

- the tool block at line 4071 becomes `v-if="chatView.mode === 'compact'"` →
  `<CompactToolGroup :messages="group.messages" :expanded-ids="expandedToolIds" ... />`, and
  `v-else` keeps today's `<ToolCard>` chain;
- the toolbar (`<template #toolbar>`, line 4663) gets the "View: Compact ▾" control in the **right**
  zone, after the worktree status. It must not sit next to the existing "Compact" button in the
  left zone, because that one compacts the conversation history and the two meanings would sit
  side by side.

### 7. Tests

- new `src/apps/desktop/src/__tests__/chatViewCompact.spec.ts`:
  - the store defaults to `dev` and round-trips through `localStorage`;
  - the segmented control writes the store and reads back;
  - `summarizeTool` per tool family (the table above);
  - the group row folds, unfolds, and hoists a failed call out of the group;
  - a compact row expands into the same `ToolCard` the Dev View renders;
- the existing specs stay green, in particular
  `src/apps/desktop/src/__tests__/ChatView.composerToolbar.spec.ts` (it asserts the toolbar's
  testids and the "Compact conversation history" title) and the tool-card specs under
  `src/apps/desktop/src/components/tool_outputs/__tests__/`;
- the Python functional tests under `tests/functional_ui/` need no change, because the default
  mode is `dev`.

## Data flow

```
Settings → General → Interface → Chat view      ChatView toolbar → View: Compact
        │                                                   │
        └──────────────► useChatViewStore().mode ◄─────────┘
                                 │
                                 ▼
                    ChatView's tool block (ChatView.vue:4071)
                                 │
                 mode === 'dev'  │  mode === 'compact'
                                 ▼                    ▼
              today's card chain (now         CompactToolGroup
              components/tool_outputs/         → summarizeTool(tool, parameters, content)
              ToolCard.vue)                    → one line per call
                                                 → the group row for the run
                                                 → a failed call hoisted out
                                 │
                                 ▼
              a compact row that is expanded → the SAME ToolCard, so the
              full card is one click away
```

Nothing in this flow touches the history, the compaction, or the request that goes to the provider.
It is a rendering choice, made in the frontend, from data the transcript already carries.

## Risks

| Risk | Why it matters | What the plan does about it |
| --- | --- | --- |
| A failure hides behind a folded group | A collapsed run can hide the one thing the human needed to see | Failed and running calls are hoisted out of the group and are always visible |
| The two views drift | 31 cards in one view and a second renderer means two places to change | Extract the card dispatch into one `ToolCard.vue` and render it from both |
| The summary table is wrong for a tool | 31 tools, and a new tool can arrive any time | A table with a stated fallback, plus a rule that any tool without a rule falls back to its name and first argument |
| The default changes everyone's chat | The Dev View is what people know | The default is `dev`; the change is opt-in |
| The word "Compact" already means something | The composer toolbar's "Compact" button compacts the conversation history | The view modes are "Compact view" and "Dev view"; the toolbar control says "View: Compact" and sits in the right zone |
| A functional test breaks | `tests/functional_ui/` asserts on `.chat-tool-card` and `shell-tool-pill` | The default stays `dev`, so a fresh profile still renders the Dev View |
| The `data-testid`s move | The vitest specs, the Python suite and the app itself are four consumers | Nothing is removed; the compact rows get their own testids |

## Open questions for the human

1. **Where the preference is stored.** App-local storage, the way "Browser-style tabs" is (the
   proposal), or `config.json`, so it travels with the profile and a workspace can override it?
2. **The names.** "Compact view" and "Dev view" with a toolbar control labelled "View: Compact", or
   something else, such as "Simple" and "Full"?
3. **Does the toolbar override exist at all?** It is useful, but it means two places can disagree
   about the mode.
4. **Does Compact fold the agent's prose too?** The proposal says no: only tool calls change.
5. **A run of one call.** The proposal draws a lone call as a single line, with no group row.
6. **Is the failed call hoisted out of the group, or is the group forced open when it contains a
   failure?** The wireframe hoists it. Hoisting changes the reading order; forcing the group open
   keeps the order but gives up the density in exactly the turn you most want to read.
