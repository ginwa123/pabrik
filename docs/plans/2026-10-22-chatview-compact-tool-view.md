# A Compact View for chat tool calls

**Status:** implemented on this branch. The wireframe is the spec:
[`docs/wireframes/chatview-compact-tool-view.html`](../wireframes/chatview-compact-tool-view.html).
**Date:** 2026-10-22

## What was asked

"Can we simplify the chatview tool calling? Keep the existing, and add a setting in User settings to
control the chat view: 1. Compact View, which we add in this task, 2. Dev View, which is the
existing one."

Three decisions were taken while the wireframe was reviewed:

- **The compact view is the dev cards, folded.** There is no new row style and no second card
  component. The group card has the shape of a dev card, and the cards behind it are the dev cards,
  unchanged.
- **A failed call keeps its place inside the run.** It is not lifted out of the group; the group
  card says how many calls failed, so a folded group still announces the failure.
- **The mode lives in `config.json`** (`chat_view`), so it travels with the profile, and **there is
  no toolbar switch**: the setting in `Settings → User → General` is the only place that decides.

The backend also records how long each tool call took, so the group card can say how long the run
took.

## The design

### The Dev View (today, unchanged)

Every tool call in a `tool` group is its own card: a violet tool-name pill, the primary argument,
the outcome badges, a `+`/`−` toggle, and an expanded body. The cards are already collapsed by
default, so the cost of the Dev View is not the expansion, it is the **number of rows**: a turn that
ran eight tools is eight bordered rows, and the agent's answer ends up below the fold.

### The Compact View (new)

A run of consecutive tool calls (which the chat already groups into one `tool` group) is drawn as:

- **one group card**, in the shape of a dev card: the violet name is `8 tool calls`, the right-hand
  badges are `1 failed`, `1 write` and the run's duration, and the `+`/`−` toggles the fold;
- **the dev cards behind it**, one per call, in the same order, unchanged;
- **a group that holds an `ask_user` starts open**, because that is the one call the human has to
  act on: a question you cannot see is a question you cannot answer.

Measured on the wireframe: folded, the tool block is **24px** against **311px** in the dev view for
the same eight calls, so **13 times shorter**: one card instead of eight. Unfolded it is 344px and
nine cards, the same eight plus the group card on top.

## Where the mode lives

`config.json`, key `chat_view`, values `dev` and `compact`. The default is `dev`, so no chat changes
until the setting is used, and the Python functional tests in `tests/functional_ui/` (which assert
on the dev view's markup) keep passing on a fresh profile.

The wiring:

- `src/modules/config/Config.zig` — `ChatViewMode` (an enum), `parseChatViewMode` (tolerant: an
  unknown name degrades to `dev`), the on-disk `chat_view` key, and the parse.
- `src/http_handlers/pabrik_config_get.zig` — the key on the wire.
- `src/http_handlers/pabrik_config_put.zig` — the key on the way in; an unknown name is a **400**,
  not a silent fallback, so a typo in the client is visible.
- `src/http_handlers/http_response.zig` — the response field.

The frontend reads it from the config the chat **already fetches** (`ChatView.loadAgents`, which gets
the workspace overlay merged over the user config, so the mode is the one that runs here). The chat
does not fetch the user config on its own — that would break the contract that a chat in a
workspace never reads the user-scope config.

## The duration

The tool result envelope (`{"tool":…, "parameters":…, "success":…, "data":…, "error":…}`) now
carries `duration_ms`.

- `src/agentic_loop/tools_wrap_output.zig` — `withDurationMs` adds the field to an envelope. The
  envelope shape is fixed by `wrapToolOutput`, so the field goes in front of the trailing `"v":1}`;
  anything that is not an envelope is returned unchanged.
- `src/agentic_loop/handle_tool.zig` — the registry dispatch measures the call and stamps the
  envelope. The MCP branch is left alone: an MCP result is the server's raw response, not an
  envelope, so it carries no duration.
- `src/apps/desktop/src/helpers/unwrapToolOutput.ts` — the duration is part of the parsed envelope.

The group card sums the durations of the calls in the run and shows the total.

## The implementation

| File | What changed |
| --- | --- |
| `components/tool_outputs/ToolCard.vue` | **New.** The card for ONE tool call: the 31-branch dispatch that used to live inline in `ChatView.vue`, now with the parent's state as props and its events as emits. |
| `components/tool_outputs/compact/CompactToolGroup.vue` | **New.** The group card, the fold, the counts and the duration. |
| `components/views/ChatView.vue` | The tool group renders `<CompactToolGroup>` in compact mode and `<ToolCard>` per call otherwise. `toolCardsFor(group, groupIndex)` builds the cards; the 31 card imports are gone. |
| `stores/chatView.ts` | **New.** The app's copy of the mode, and `chatViewModeFrom(config)`. |
| `components/pabrik/PabrikGeneralSection.vue` | The "Chat view" row: a two-option control next to the notifications and the retry delay. |
| `components/pabrik/PabrikConfigEditor.vue` | The General tab hydrates `chat_view` from the config, writes it back, and hands the saved mode to the store. |
| `api/index.ts` | `chat_view` on the config type. |
| `helpers/unwrapToolOutput.ts` | `duration_ms` on the parsed envelope. |
| `modules/config/Config.zig`, `http_handlers/*` | The config key, end to end. |
| `agentic_loop/tools_wrap_output.zig`, `agentic_loop/handle_tool.zig` | The duration in the envelope. |

### The one refactor

The dispatch that picks the card for a tool message (31 branches) lived inline in the ChatView
template. The compact view has to draw the same card for a call it hides behind the group card, so
the chain moved into `ToolCard.vue` and both views mount it. That is what keeps the two views from
drifting: there is one chain and one card, drawn two ways.

### Tests

- `src/apps/desktop/src/__tests__/chatViewCompact.spec.ts` — **new**, behaviour-focused: the mode
  the config carries, the mode the user saved, the group card's counts, its duration, the fold, the
  group that opens itself for a question, the setting's two states, and the envelope's duration.
- `src/apps/desktop/src/components/tool_outputs/__tests__/ToolCard.parameters.spec.ts` — **moved**
  from `ChatView.tool-parameters.spec.ts`: the same contract (every branch threads the parameters),
  now asserted against the file the dispatcher lives in.
- `src/apps/desktop/src/__tests__/ChatView.expandStateStability.spec.ts` — the two source contracts
  that moved with the dispatch (every read of `expandedToolIds` routes through `toolExpandKey`; the
  tool group keys by the message id, not the array index) now assert the new shape.
- Zig: `withDurationMs` adds the duration and leaves a non-envelope alone; `chat_view` defaults to
  `dev`, reads `compact` from JSON, and degrades an unknown name to `dev`.

The frontend suite's red set is unchanged: 54 failures before this change, 54 after (the same
names), measured by running the whole suite on a stash of the branch and on the branch.

## Risks

| Risk | Why it matters | What the change does about it |
| --- | --- | --- |
| A failure hides behind a folded group | A collapsed run can hide the one thing the human needed to see | The group card counts the failed calls in red, so a folded group announces the failure |
| The two views drift | 31 cards in one view and a second renderer means two places to change | One `ToolCard.vue` draws the card; the two views only differ in what they put around it |
| The default changes everyone's chat | The Dev View is what people know | The default is `dev`; the change is opt-in |
| The word "Compact" already means something | The composer toolbar's "Compact" button compacts the conversation history | There is no toolbar control, so the clash is only with the setting's own option label; the setting is called "Chat view" |
| A functional test breaks | `tests/functional_ui/` asserts on `.chat-tool-card` and `shell-tool-pill` | The default stays `dev`, so a fresh profile still renders the Dev View |
| The `data-testid`s move | The vitest specs, the Python suite and the app itself are four consumers | Nothing is removed; the group card gets its own testids |

## Open questions

1. **The names.** "Compact view" and "Dev view" in a row called "Chat view", or something else, such
   as "Simple" and "Full"?
2. **Does Compact fold the agent's prose too?** The proposal says no: only tool calls change.
3. **A run of one call.** The proposal draws a lone call as the card it already is, with no group
   card on top.
4. **A workspace override.** The mode travels in the profile, and a workspace overlay can override
   it, but nothing writes that override yet. Should the workspace settings grow a row for it?
