# Plan — remove the left/right gaps in the chat transcript

- **Task:** `task_1792181968047_4` — *"can we remove the gaps ? left and right like i draw in screen shot ?"* (`#Notes UseGitWorktree`)
- **Base:** `main` @ `bba481b06`
- **Wireframe:** `docs/wireframes/chat-transcript-width.html`
- **Status:** planning only — **no code changed.** Waiting on the open questions below.

## 1. What was asked

The screenshot shows a chat transcript with a wide empty band on the left and one on the right,
with orange lines drawn across both. The ask is to remove those bands so the transcript uses the
full width of the window.

## 2. What the gaps actually are (measured, not inferred)

Every transcript row carries `px-4 max-w-4xl mx-auto` (`ChatView.vue:3927`).
`max-w-4xl` resolves to `--container-4xl: 56rem` = **896 px** at the 16 px root, and `mx-auto`
centres it inside the chat column. So the gap on each side is `(columnWidth − 896) / 2`.

Measured in headless Chrome against a second instance of the current build on
`http://127.0.0.1:8080` (window 1450×980; the user's server on `:8081` was never touched):

| Window | Chat column | Row | Gutter each side | Column empty |
|---|---|---|---|---|
| 1100 | 812 | 812 | 0 / 0 | 0 % |
| 1450 | 1162 | 896 | 133 / 133 | 23 % |
| 1920 | 1632 | 896 | 368 / 368 | 45 % |
| 2560 | 2272 | 896 | 688 / 688 | 61 % |

Two independent witnesses at 1450 px: the composer's own `.max-w-4xl` box (real element) and a
probe carrying the row's exact classes both measure `x = 421, width = 896, right = 1317`, i.e.
133 px of gutter on each side of the 1162 px column.

The user's screenshot has the sidebar hidden, so the column was the whole ~1450 px window and the
gutter was ≈277 px each side — 554 px of a 1450 px window (38 %) is empty.

The cap lives at exactly **four sites**, all in `ChatView.vue`:

1. `:3778` — loading skeleton
2. `:3927` — every transcript row (user bubbles, assistant prose, tool cards, diffs)
3. `:4549` — agent-error band
4. `:4619` — composer / input card

## 3. Options

| | Change | @1450 row / gutter | Trade-off |
|---|---|---|---|
| **Today** | — | 896 · 133 + 133 | 38 % of a maximised window is empty |
| **A · full-bleed** | delete `max-w-4xl mx-auto` at all four sites | 1162 · 0 + 0 | prose ≈ 250 ch/line at 2560 |
| **B · full-bleed + 24 px inset** | as A with `padding-inline: 24px` | 1162 · 0 + 0 (24 px inset) | same long prose, softer edge |
| **C · width token** *(recommended)* | one token `--chat-content-max` + a control, default `100 %` | 1162 · 0 + 0 | one token, reversible per user |

**Recommendation: C.** It answers the ask by default, keeps today's 896 px opinion available, and
makes the choice a user preference instead of a permanent diff. The knob belongs on
`.chat-column` next to the existing `--chat-composer-inset`; the four sites become
`max-w-[var(--chat-content-max)]` with `mx-auto` unchanged.

## 4. Implementation steps (after approval)

1. Add `--chat-content-max` to the `.chat-column` style block (`ChatView.vue:3668` region).
2. Replace `max-w-4xl` with `max-w-[var(--chat-content-max)]` at the four sites; keep `mx-auto`.
3. Mirror the pill-rail gutter (see trap 1) so a full-bleed row is not 48 px right / 16 px left.
4. Persist the value (config) and add the control (chat app bar, or Settings → Appearance).
5. `tests/functional_ui/` — one assertion per option: at 1450 px the row's gutter is 0, and the
   composer cap box matches the row's width.

## 5. Traps found while measuring

1. **The pill rail is asymmetric under full-bleed.** `.has-pill-rail` puts `padding-right: 48px`
   on every row (`ChatView.vue:5462-5471`) to keep the rail's pills off the content. Today that
   48 px hides inside the empty gutter; full-bleed turns it into a visible 48/16 asymmetry in any
   chat with ≥ 2 user messages. Mirror the padding in the same change.
2. **The composer dock is not covered by that gutter.** Site 4 has no `has-pill-rail` rule, so
   full-bleed moves the input card into the rail's band — check with the rail visible.
3. **Tool cards already follow the row.** `.tool-sequence`, `.tool-item` and `.chat-tool-card` are
   `width: 100 %` + `min-width: 0`, and `.chat-tool-card pre` scrolls inside
   (`overflow-x: auto`). No change needed; `ChatView.tool-width.spec.ts` pins all of it, including
   the literal `class="min-w-0 flex-1 w-full"` container — do not touch that class string.
4. **The floating composer is vertical only.** `--chat-composer-inset` /
   `.last-transcript-row` (`ChatView.vue:5564`) pad the last row downwards, so a horizontal change
   cannot desync the scroll anchors. `VirtualScroller.measureItems()` reads `offsetHeight`, so
   width is invisible to the height model too.
5. **No test pins the cap.** Grepping `max-w-4xl` across `src/`, `tests/` and `tests/functional_ui/`
   finds the four sites and nothing else (the remaining hits are the compiled bundle embedded in
   `webapp_assets.zig`). Blast radius: the four sites.

## 6. Open questions — answers needed before implementing

1. A, B or C? — *recommend C, default full.*
2. If C, where does the control live: chat app bar or Settings → Appearance? — *recommend app bar.*
3. Should prose keep a reading measure (~90 ch) while cards/diffs go full width? — *recommend no
   for now; it re-creates a gap around paragraphs.*
4. Should the composer follow the transcript, or stay at 896 px? — *recommend follow.*

## 7. Verification plan

- Re-run the geometry probe at 1100 / 1450 / 1920 / 2560 and assert gutter 0 for the chosen option.
- Assert the composer cap box width equals the row width at every window.
- Assert the pill-rail case: with ≥ 2 user messages, content insets are symmetric.
- Wireframe itself: `agent-browser` load + click-through (Today / A / B / C / slider / back)
  asserting `getBoundingClientRect()` per state; no page errors.

## 8. Implemented — option C (this PR)

**Chosen: C.** One token, three presets, cycled from the chat app bar and remembered per browser.

| Preset | `--chat-content-max` | @1450 (column 1162) | @2560 (column 2272) |
|---|---|---|---|
| `full` *(default)* | `100%` | row 1162, gutter **0 / 0** | row 2272, gutter **0 / 0** |
| `wide` | `1400px` | row 1162, gutter 0 / 0 | row 1400, gutter 436 / 436 |
| `comfortable` | `896px` | row 896, gutter 133 / 133 | row 896, gutter 688 / 688 |

- **New:** `src/composables/useChatContentWidth.ts` — module-scope state (not a pinia store: the app
  bar is mounted bare in specs and rendered by three chat hosts, and all three must share one value).
  Persisted at `localStorage['pabrik-chat-content-width']`; an unknown or missing value reads as `full`.
- **`ChatAppBar.vue`** — the control: a `⇔ <preset>` button between the extras slot and the `◫`
  toggle. No prop, so the three chat modes stay byte-identical (`ChatAppBarParity.spec.ts` still passes).
- **`ChatView.vue`** — `--chat-content-max: 100%` on `.chat-column`, the two narrowed preset classes,
  the four capped sites now `max-w-[var(--chat-content-max)]`, and the pill-rail strip mirrored
  (`padding-left` as well as `padding-right`) so a full-bleed row keeps its text centred.
- **Tests:** `useChatContentWidth.spec.ts` (6), `ChatAppBar.contentWidth.spec.ts` (4),
  `ChatView.contentWidth.spec.ts` (5, source-grep) — 15 new, all green.

### Live verification (worktree `dist/` served on `:8080`, headless Chrome)

- @1450, `full`: column 1162, row **1162**, gutter **0 / 0**, composer box 1130 — was 896 / 133 / 133.
- @2560, `full`: column 2272, row 2272, gutter **0 / 0** — was 688 / 688, i.e. 61 % of the window empty.
- Cycling the control moves the label, the token, the class and the geometry together; the choice
  survives a reload (`full` → `comfortable` restored label + `896px` + 133 / 133 gutter).
- `.has-pill-rail` probe: a `[data-group-key]` row now measures `padding 48 / 48` (was 0 / 48).
- No page errors.

### Gates

`vitest --run` on the touched specs (38 passed) · `vue-tsc --build` clean · `oxlint` clean on all six
files · `eslint` clean on all six files · `prettier --check` clean.
The three failures in the wider `ChatView.*` set (`centerDiff › drops stale diffs on cwd change`,
`centerSync › syncs currentPath to ?diff=`, `tool-width › tool-group container fills the column`) were
reproduced with these edits reverted, so all three are pre-existing red.
