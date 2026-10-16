# One row grammar for the left sidebar

Wireframe: `docs/wireframes/sidebar-row-grammar.html`. Task `task_1792178616511_2`, board
`item_1791124015994038629`. Written 2026-10-16, base `71ebc364c`.

## Goal

Every clickable line in the left panel reads the same way: one label edge per depth, one trailing slot,
one treatment per state. The four section headers answer the same three questions (how many, what state,
what action) the same way. Nothing in this plan changes what the panel does, only how it is spelled.

## Non-goal

No behaviour change. No new endpoint, no new store, no change to the virtualiser, to paging, to drag
reorder, to the context menus, or to which rows exist. The panel keeps its current buttons and targets.

## Status

Implemented on this branch and measured on the built app: `15d412fcd` (one row grammar, nothing indents)
and `6abe330e8` (one section header, no button inside a button), plus the time treatment and the New Chat
columns.

Fixed: findings 1 to 9, and 11 to 17. The browser reads the project row, the task row and New Chat at box
`[0..287]` with their labels at `28`, zero nested buttons, and one vertical rule left, which is the panel's
own edge.

Remaining: finding 10's structural half. The pinned and the recent rows are still two copies of one block
of markup, and their elapsed-chip test ids are aligned now, so the drift is gone but the duplication is
not; extracting them into one `SidebarRow` component is the next change. Worth a look with it:
`KanbanTaskRow.vue:318` shares `variant="text"`, which is `--text-micro` now.

## The contract as it stands

`style.css` declares the geometry the panel is supposed to resolve against: `--sb-gutter: 12px`,
`--sb-row: 32px`, `--sb-indent: 12px`, `--sb-hit: 24px`, and the type steps `--text-micro: 10px`,
`--text-meta: 11px`, `--text-dense: 12px`. `Sidebar.spacing.spec.ts` guards it by reading class strings
and asserting that a token appears in them.

That guard is a source scan, so it cannot see any of the following. Every item is a measurement from a
second instance of the same build on port 8080 (a source read where marked), with the file and line to
change.

### Headers

1. **The sort, projects-plus and documents-plus controls are `<button>` inside `<button>`.** Measured:
   three nested buttons. Invalid HTML, and one focus stop becomes two overlapping ones for a keyboard or
   screen-reader user. `ChatsList.vue:1274` and `:1291`, `ProjectsList.vue:295` and `:338`,
   `DocumentsList.vue:108` and `:134`.
   *Fix:* the header becomes a container, and the chevron becomes its own button. The title, the count and
   the action are siblings.

2. **Pinned is the only header with no trailing control and the only count at `opacity-60`.**
   `ChatsList.vue:1116` against `ProjectsList.vue:315` and `DocumentsList.vue:130`. Measured: 0.6 against
   0.7.
   *Fix:* one count treatment, `text-micro`, dim, opacity 0.7, tabular figures. The action slot stays
   optional, because Pinned has nothing to add to.

3. **Recent is the only header with no count.** `ChatsList.vue:1274`.
   *Fix:* render the recents total in the same position as the other three.

4. **Projects puts a sentence in the count position, and pins the running indicator next to the total.**
   `ProjectsList.vue:325`. Measured: the count and the running group both sit right after the title,
   so `15` and `3 running` read as one phrase.
   *Fix:* move the running group into the trailing group beside the plus, where Recent's sort control
   already lives.

5. **Pinned draws its rule under its rows; the other three draw it under the header.**
   `ChatsList.vue:1096` against `:1274`, `ProjectsList.vue:296`, `DocumentsList.vue:109`. The divider
   therefore moves when Pinned expands. `Sidebar.spacing.spec.ts:113` pins Recent, Projects and Documents,
   so Pinned is the one header no guard covers.
   *Fix:* one rule, on the header, for all four.

### Rows

6. **The branch badge sits inside the truncating title span, so the label column jitters by 20px.**
   `ChatsList.vue:1152` and `:1338`. Measured in the wireframe's before crop: labels at 12 on rows without
   a badge, at 32 on rows with one.
   *Fix:* the badge moves into the row's mark column, the reserved 16px slot at the gutter. See the two
   decisions in the wireframe: the alternative, leaving the badge in the trailing group, is listed there
   with what it costs.

7. **The same trailing slot is a filled pill on a running row and bare 60% text on an idle one.**
   `ChatsList.vue:1231` against `WorkerElapsedChip.vue:118`. Two visual classes for one question.
   *Fix:* the slot is `text-micro`, tabular, right-aligned, and states differ by colour and precision:
   dim at 0.7 for idle, `--color-yellow` at full opacity with seconds for running, `--color-orange` for
   stale. In the sidebar, `WorkerElapsedChip` is used with `variant="text"`, and that variant's
   `font-size` changes from `--text-meta` to `--text-micro` so the two states share one size inside the
   slot. Its only other consumer is `KanbanTaskRow.vue:318`, which is a metadata line already set in
   `text-micro` neighbours; check that row after the change.

8. **The status mark is a second trailing slot, inline in the label flow**, so its x moves with the label
   length while the time stays right-aligned. `ChatsList.vue:1179` and `:1225`.
   *Fix:* the status mark joins the trailing group, in fixed order: status mark, then time.

9. **A sub-agent suffix is rendered monospace** inside a row label, which the app's type system reserves
   for code, and it competes with the name for the truncating width. `ChatsList.vue:1222` and `:1414`.
   *Fix:* the suffix is `text-micro` in `--color-violet`, and it moves into the trailing group with the
   rest of what the row knows. The branch badge goes the other way, into the mark column.

10. **The pinned and the recent rows are two copies of one block of markup, and they have drifted.** The
    elapsed chip's id is `chat-elapsed-chip` in the pinned copy and `chat-nav-elapsed-chip` in the recent
    copy: `ChatsList.vue:1257` against `:1458`. Any test or grep aimed at one silently misses the other.
    *Fix:* one row component, used by both sections. This is the single change that removes the drift
    class rather than one instance of it.

11. **Two selected-row treatments.** The project row hardcodes `#2e2d29` on `#fff`
    (`WorkspaceItem.vue:498`); chat and document rows use `--semantic-active-bg` on
    `--semantic-active-text`, measured as `#282727` on `#c5c9c5` (`ChatsList.vue:1143`,
    `DocumentsList.vue:202`).
    *Fix:* the token pair and the 2px inset violet bar for every row kind.

12. **A task row hardcodes `text-yellow-400`** for its pin glyph (`WorkspaceItemTaskRow.vue:311`).
    `yellow-400` is not in this theme; `--color-yellow` is `#c4b28a`.
    *Fix:* the token.

13. **The projects list and the documents list sit on a 12px left margin, so their rows are inset 13px
    while a RECENT row is flush.** Measured in the wireframe's two crops: project and document rows have a
    box of `[13..288]`, RECENT rows `[0..288]`. That strip runs down the whole of both sections and stops
    dead at RECENT, and it shows again in a selected project's background, which begins where the margin
    ends. It is the most visible inconsistency in the panel and it is one line in each file.
    `ProjectsList.vue:449`, `DocumentsList.vue:194`.
    *Fix:* no margin on either list. Every row's box becomes `[0..288]`, so a selected project's background
    spans the panel exactly as a selected chat's does. The label still sits at 28, because the mark column
    puts it there, not a margin pushing the row right.

14. **The project label sits at 41.5, not at 28.5 with the section titles.** The same `ml-[var(--sb-indent)]`
    plus `border-l` on top of the row's own `px-[var(--sb-gutter)]`, which the comment at
    `WorkspaceItem.vue:510` promising "the project name at 28, matching the section titles" does not count.
    *Fix:* with the margin gone the chevron sits at 12 and the name at 28, on the section title's edge.

15. **The same two lists draw a 1px rule down their left edge**, from the first project to the last, and a
    project's task list draws the same rule again. It is the hairline divider the app's own house style
    bans, and together with the indent it is what makes the left of the tree read as a second column.
    `ProjectsList.vue:449`, `DocumentsList.vue:194`, `WorkspaceItem.vue:613` and `:725`.
    *Fix:* delete every one of them. Nesting is carried by the label column and the row order, not by a
    rule. Nothing in the panel draws a vertical line.

16. **The expanded projects block carries 8px of padding under its last row and 6px of top margin on its
    first**, and a project's own task and design-page lists repeat the whole pattern a level down (a 12px
    margin, a 12px padding and a rule, which lands a task's label at 57). `ProjectsList.vue:435` and `:466`,
    `WorkspaceItem.vue:613` and `:725`.
    *Fix:* the block has no space of its own and no margin, and a task inside a project takes no step
    either: its mark sits at 12 and its label at 28, the same two columns as everything else. The section's
    whole rhythm is the header's 28px and the row's 32px.

17. **The left rail is four edges.** Measured: the section chevron's ink at 10.5, a chat label at 12, the
    New Chat glyph centred in a 24px hit box with its ink at 19.4 and its label at 44, a project name at
    41.5. `Sidebar.vue:1155`.
    *Fix:* two columns for the whole panel. The mark column is 16px at the gutter (12 to 28) and holds at
    most one mark: a disclosure chevron, a branch badge, a status glyph, or nothing. Every label starts at
    28, New Chat included, and New Chat keeps its 40px height.

### Comments to delete rather than correct

Per the repo's no-comments policy these are not rewritten, they go:

- `WorkspaceItem.vue:510` claims an alignment the render contradicts (measured 41.5 against 28.5).
- `ChatsList.vue` carries a duplicated three-line explanation of the elapsed chip above each of the two
  row copies; one survives with the one row component.
- `Sidebar.spacing.spec.ts`'s file docstring describes "four left edges and three row heights", which is
  the bug it failed to catch.

## The target grammar

**Row.** `[mark column, 16px] [label, flex 1, truncate, text-dense] [trailing group, shrink-0, gap 1.5]`.
Height `--sb-row`, gutter `--sb-gutter`, `rounded-lg`. The mark column is present on every row and holds at
most one mark: a disclosure chevron, a branch badge, a status glyph, or nothing. The trailing group is
right-aligned and its order is fixed: status mark, then time. Nothing about a row is rendered inside the
label except the label.

**Header.** `[chevron button, 24x24 at the gutter] [TITLE, text-micro semibold uppercase tracked]
[count, text-micro dim 0.7 tabular] [ml-auto: optional one action, 24x24, glyph text-meta, dim 0.7]`.
The header itself is not a button and contains no button.

**Columns.** Two, for the whole panel, at every depth: the mark column at `--sb-gutter` (12) and the
label column at 28. Every row uses both whether or not it has a mark, so no row starts further right than
another and the panel never opens an empty strip. Nothing indents, not a project, not a task under a
project, not a document, so the panel stops using `--sb-indent` altogether: the only nesting cue is a row's
order under the header it belongs to. No vertical rule is drawn anywhere either.

**Selected.** `--semantic-active-bg` on `--semantic-active-text` plus `inset 2px 0 0 0 var(--color-violet)`,
for every row kind.

## Implementation order

1. Delete the 12px left margin and the 1px left border from the projects list and the documents list
   (`ProjectsList.vue:449`, `DocumentsList.vue:194`), the 8px of trailing padding (`:435`) and the first
   row's 6px top margin (`:466`). One edit per file, needing nothing else, and it removes the strip that
   prompted the whole review: every row's box goes from `[13..288]` to `[0..288]`. Land it on its own so it
   can be seen before anything else moves.
2. Extract the chat row into one component (`components/rows/SidebarRow.vue`, taking label, marks, meta and
   a `data-testid`), and point both `ChatsList` sections at it. No visual change.
3. Rewrite the four headers to the container-plus-chevron-button shape. Delete the wrapper `<button>`.
4. Move the branch badge out of the label into the mark column, and the status mark and the sub-agent
   suffix into the trailing group.
5. Swap the sidebar's elapsed chip to `variant="text"` and set that variant to `--text-micro`. Check
   `KanbanTaskRow.vue:318`.
6. Unify the counts and the running group; align the four headers.
7. `WorkspaceItem.vue`: the token pair for the selected row, and drop the margin and the rule from the
   project list, its task list (`:613`) and its design-page list (`:725`) so all three levels share the
   panel's two columns. `WorkspaceItemTaskRow.vue`: the yellow token, and no indent step.
8. `DocumentsList.vue`: the same row grammar, and no rule on the list.
9. `Sidebar.vue`: New Chat's glyph and its label onto the shared columns.

Steps 2 and 3 change no pixel and can land first, on their own: that is the safest way to review this.
Nothing here needs `--sb-indent`, so the panel stops using that token; leave the token in `style.css`, since
other surfaces may read it and a token that is still declared is cheaper than a second migration.

## Tests

`Sidebar.spacing.spec.ts` stays for the token values, but it is a source scan, so it cannot see any of the
seventeen findings. The fix needs a rendered guard: one file, `__tests__/Sidebar.rowGrammar.spec.ts`,
mounting the sidebar against a fixture with one pinned chat, one running chat, one chat with a branch and
an open PR, one project with a task, one document, and one selected chat. Behaviours, one per test:

- `gives every list row the panel's row height`
- `starts every label in the panel at the same left offset`
- `keeps a chat label on that offset whether or not the chat has a branch`
- `gives a project, a task inside it and a document the same label offset as a chat`
- `starts every row's box at the panel's left edge, with no margin on any list`
- `draws no vertical rule in the panel`
- `renders a count on every section header`
- `keeps every header control on the panel's right action edge`
- `nests no button inside a button`
- `gives a chat row and a project row the same selected background`
- `renders the elapsed time and the relative time at the same font size and weight`

Each asserts a measured box, not a class string, so a rename or a class reshuffle stays green while a drift
goes red. Add one deliberate mutation (put the branch badge back inside the label) to prove the label-offset
test is not vacuous.

## Risks

- Flattening the panel moves a project row's mark left by 13px, a task row's label left by 29px, and every
  chat and document label right by 16px. Anything asserting an absolute x, in a spec or a functional UI
  test, needs the new number. Grep for `41.5`, for `57`, for `sb-indent`, for `border-l` and for the 12px
  label offset before starting.
- With nothing indenting, a project and the tasks under it share a label edge. That is the point of the
  change, and it does mean the only cue that a task belongs to the project above it is its order. If that
  reads badly on screen, one `--sb-indent` step for the third level is the smallest thing to add back, and
  it is the first of the wireframe's flip-able decisions.
- Moving the branch badge changes a right-click target's position. The context menu and its test ids stay;
  only the anchor moves, and it is now always the row's mark column, so its x is constant across rows.
- `WorkerElapsedChip`'s `--text` variant change touches `KanbanTaskRow.vue:318`. Verify that row's slot
  after the change, and if it needs 11px, give it an explicit variant instead of reverting the sidebar.

## Evidence

Reproduce the measurements: `./zig-out/bin/pabrik --port 8080 --static-dir src/apps/desktop/dist/` from
the repo root, then `agent-browser open http://127.0.0.1:8080/app` and read the geometry with
`agent-browser eval`. The numbers, the wireframe's own DOM assertion, and the scanner and inspector
readings are all recorded in the wireframe under "What was measured" and "Gate readings".
