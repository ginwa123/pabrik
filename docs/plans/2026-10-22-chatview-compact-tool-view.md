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

Two decisions have been taken while the wireframe was being reviewed:

- **A failed call keeps its place inside the run.** It is not lifted out of the group. The group
  card says how many calls failed, so a folded group still announces the failure.
- **There is no toolbar switch.** The mode is chosen in `Settings → User → General` and nowhere
  else, so one place decides and no two places can disagree.

## The wireframe

One standalone HTML file, opened straight from the disk. It shows, in order:

- the **setting**: the new "Chat view" row in the Interface block of
  `Settings → User → General`, with both states of the control;
- the **chat view**: the same turn drawn twice, Compact on the left, Dev on the right, with a live
  read-out that measures the two tool blocks and prints the ratio;
- the **composer**, unchanged, because that is the point: the mode is not a toolbar control;
- the **card each tool draws**, which the compact view inherits;
- the **safety rules**, the **open questions**, and what the design gate measured.

It is interactive: the group card folds and unfolds, the segmented control switches the mode, and
the read-out is computed from `getBoundingClientRect()` in the same tick it prints. Verified in
`agent-browser` (structure, both sides of every claim, one snapshot per click), and through the
design gate (`lint.mjs` 0 FAIL / 0 WARN, `inspect.mjs` 0 FAIL / 2 defended WARN).

## The design

### The Dev View (today, unchanged)

Every tool call in a `tool` group is its own card: a violet tool-name pill, the primary argument,
the outcome badges, a `+`/`−` toggle, and an expanded body. The cards are already collapsed by
default, so the cost of the Dev View is not the expansion, it is the **number of rows**: a turn that
ran eight tools is eight bordered rows, and the agent's answer ends up below the fold.

### The Compact View (new)

**The compact view has no new visual language. The cards behind the group card are today's cards,
unchanged.** The only thing Compact does is fold a run of calls:

- the run of consecutive tool calls (which the chat already groups into one `tool` group) is drawn
  as **one group card** in the shape of a dev card: the violet name is `8 tool calls`, the dim
  primary is the list of the tools in the run, and the right-hand badges are the run's summary
  (`1 failed`, `1 write`);
- clicking the group card unfolds the **dev cards**, one per call, in the same order;
- a failed call keeps its place in the run, marked in red, and the group card says how many failed;
- a group that holds an `ask_user` starts open, because that is the one call the human has to act
  on;
- a running call is counted in the group card too, so a long call never looks like a call that never
  happened.

Measured on the wireframe: folded, the tool block is **39px** against **311px** in the dev view for
the same eight calls, so **8 times shorter**: one card for all eight calls. Unfolded it is 359px
and 9 cards, the same eight cards plus the group card on top.

### What this means for the implementation

This is the part that got smaller. Because the compact view renders the existing cards, there is
**no new summary rule per tool, no new parser and no second card component**: the card behind the
group already carries the one argument that identifies the call, because that is what the card was
for. The new work is a group card, a fold, and a setting.

| Tool | The card shows | Outcome |
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

Six steps, in this order. The order matters: the Dev View must not move until the Compact View
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
`.tool-expandable` fallback at `ChatView.vue:4368`. The Compact View has to render the same card
for a message it draws behind the group card, so the chain moves to a new component:

- new `src/apps/desktop/src/components/tool_outputs/ToolCard.vue`, props `message`, `content`,
  `parameters`, `expanded`, `cwd`, and the two slot-scoped helpers `innerToolData` and
  `getParametersForMessage` passed in as props or callbacks;
- `ChatView.vue`'s tool block becomes `<ToolCard ... />` where the chain used to be.

This is the only refactor the feature needs, and it is what keeps the two views from drifting
apart: there is one chain and one card, drawn by two views.

### 3. The group card

New file `src/apps/desktop/src/components/tool_outputs/compact/CompactToolGroup.vue`:

- **the group card** — the shape of a dev card (`.chat-tool-card`): the violet name is
  `N tool calls`, the dim primary is the tool names of the run, the right-hand badges are
  `N failed`, `N running` and `N write`, and the `+`/`−` toggles the fold;
- **the fold** — the group's messages rendered as `ToolCard`s, in order, hidden by default;
- **the open-by-default rule** — a group that holds an `ask_user` starts open.

The aggregates come from what the transcript already carries, and nothing more:

| the badge | where it comes from |
| --- | --- |
| the number of calls | the size of the `tool` group |
| the tool names | `msg.tool_name` on each message |
| the number of failures | the envelope's `success: false` (`helpers/unwrapToolOutput.ts:57` returns `success` and `error`) |
| the number of writes | the tool names `write_file`, `text_replace`, `remove_file` |
| the number of running calls | an empty envelope with a known argument, the same test the shell card uses |

**There is no duration.** The envelope (`helpers/unwrapToolOutput.ts`) carries the tool name, the
arguments, `success`, the error and the data. It carries no timing, so the group card cannot show
how long the run took without a new field in the transcript. The wireframe therefore shows no
duration, and if the human wants one, that is a separate change in the backend.

### 4. The settings row

`src/apps/desktop/src/components/pabrik/PabrikConfigEditor.vue`, in the Interface block next to the
`toggle-browser-tabs` row (line 1093-1096): a "Chat view" row with a two-option segmented
control, `data-testid="row-chat-view"`, `data-testid="chat-view-compact"`,
`data-testid="chat-view-dev"`. It writes the store, not `config.json`, so the block's own
"app-local (localStorage), not config.json" comment stays true.

### 5. The ChatView wiring

`ChatView.vue`: the tool block at line 4071 becomes `v-if="chatView.mode === 'compact'"` →
`<CompactToolGroup :messages="group.messages" :expanded-ids="expandedToolIds" ... />`, and `v-else`
keeps today's `<ToolCard>` chain. Nothing else in the chat changes: the composer toolbar, the
agent's prose and the transcript are untouched.

### 6. Tests

- new `src/apps/desktop/src/__tests__/chatViewCompact.spec.ts`:
  - the store defaults to `dev` and round-trips through `localStorage`;
  - the segmented control writes the store and reads back;
  - the group card counts the calls, the failures, the writes and the running calls;
  - the group card folds and unfolds, and the cards behind it are the same `ToolCard`s the dev
    view renders;
  - a group holding an `ask_user` starts open;
- the existing specs stay green, in particular
  `src/apps/desktop/src/__tests__/ChatView.composerToolbar.spec.ts` (it asserts the toolbar's
  testids and the "Compact conversation history" title, and the composer is not touched);
- the Python functional tests under `tests/functional_ui/` need no change, because the default
  mode is `dev`.

## Data flow

```
Settings → General → Interface → Chat view
        │
        └──────────────► useChatViewStore().mode
                                 │
                                 ▼
                    ChatView's tool block (ChatView.vue:4071)
                                 │
                 mode === 'dev'  │  mode === 'compact'
                                 ▼                    ▼
              today's card chain (now         CompactToolGroup
              components/tool_outputs/         → the group card: the count, the tool
              ToolCard.vue)                      names, the failures, the writes
                                 │              → the fold: the same ToolCards, in order
                                 ▼
              the dev cards, one per call
```

Nothing in this flow touches the history, the compaction, or the request that goes to the provider.
It is a rendering choice, made in the frontend, from data the transcript already carries.

## Risks

| Risk | Why it matters | What the plan does about it |
| --- | --- | --- |
| A failure hides behind a folded group | A collapsed run can hide the one thing the human needed to see | The group card counts the failed calls in red, so a folded group announces the failure, and the failed card behind it is today's card, which forces its error body open |
| The two views drift | 31 cards in one view and a second renderer means two places to change | Extract the card dispatch into one `ToolCard.vue` and render it from both |
| The default changes everyone's chat | The Dev View is what people know | The default is `dev`; the change is opt-in |
| The word "Compact" already means something | The composer toolbar's "Compact" button compacts the conversation history | There is no toolbar control, so the clash is only with the setting's own option label; the setting is called "Chat view" and the composer button keeps its own title |
| A functional test breaks | `tests/functional_ui/` asserts on `.chat-tool-card` and `shell-tool-pill` | The default stays `dev`, so a fresh profile still renders the Dev View |
| The `data-testid`s move | The vitest specs, the Python suite and the app itself are four consumers | Nothing is removed; the group card gets its own testids |

## Open questions for the human

Two of these are already answered: **a failed call keeps its place inside the run** (the group card
says how many failed), and **there is no toolbar switch** (the mode is chosen in
`Settings → User → General` and nowhere else).

1. **Where the preference is stored.** App-local storage, the way "Browser-style tabs" is (the
   proposal), or `config.json`, so it travels with the profile and a workspace can override it?
2. **The names.** "Compact view" and "Dev view" in a row called "Chat view", or something else,
   such as "Simple" and "Full"?
3. **Does Compact fold the agent's prose too?** The proposal says no: only tool calls change.
4. **A run of one call.** The proposal draws a lone call as the card it already is, with no group
   card on top.
5. **A duration for the run.** The envelope carries no timing, so the group card cannot say how
   long the run took. Should the backend record one, or is the count of calls enough?
