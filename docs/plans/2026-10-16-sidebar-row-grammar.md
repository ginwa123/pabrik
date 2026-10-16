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

13. **The project label sits at 41.5, not at 28.5 with the section titles.** `ProjectsList.vue:449` adds
    `ml-[var(--sb-indent)]` and a `border-l` on top of the row's own `px-[var(--sb-gutter)]`, which the
    comment at `WorkspaceItem.vue:510` promising "the project name at 28, matching the section titles"
    does not count.
    *Fix:* the projects list loses its indent and its rail entirely. A project row uses the same mark
    column and the same label edge as every other row in the panel, and the nesting is carried by order and
    by the header it sits under. See the wireframe's first decision for why flattening beats indenting,
    and for the cost.

14. **The left rail is four edges.** Measured: the section chevron's ink at 10.5, a chat label at 12, the
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

**Columns.** Two, for the whole panel: the mark column at `--sb-gutter` (12) and the label column at
28. Every row uses both whether or not it has a mark. A third level, a task under an expanded project,
takes one step of `--sb-indent` (raised from 12 to 16) applied to the row itself, so its mark column sits
at 28 and its label at 44, with the rail drawn at 28 under the project's own mark column. No other row
indents, so the panel never opens an empty strip beside the gutter.

**Selected.** `--semantic-active-bg` on `--semantic-active-text` plus `inset 2px 0 0 0 var(--color-violet)`,
for every row kind.

## Implementation order

1. `style.css`: `--sb-indent` 12 to 16. Nothing else moves until the tree columns are honest.
2. Extract the chat row into one component (`components/rows/SidebarRow.vue`, taking label, marks, meta
   and a `data-testid`), and point both `ChatsList` sections at it. No visual change yet.
3. Rewrite the four headers to the container-plus-chevron-button shape. Delete the wrapper `<button>`.
4. Move the branch badge out of the label into the mark column, and the status mark and the sub-agent
   suffix into the trailing group.
5. Swap the sidebar's elapsed chip to `variant="text"` and set that variant to `--text-micro`. Check
   `KanbanTaskRow.vue:318`.
6. Unify the counts and the running group; align the four headers.
7. `WorkspaceItem.vue`: token pair for the selected row; drop the list's margin and rail so a project row
   shares the panel's two columns. `WorkspaceItemTaskRow.vue`: the yellow token, and the one indent step
   plus the rail at 28 for the third level.
8. `DocumentsList.vue`: same row grammar and the same indent treatment.
9. `Sidebar.vue`: New Chat's glyph and label onto the shared columns.

Steps 2 and 3 are separable from the visual work and can land first, on their own, with no pixel change:
that is the safest way to review this.

## Tests

`Sidebar.spacing.spec.ts` stays for the token values, but it cannot see any of the fourteen findings, so
the fix needs a rendered guard. One file, `__tests__/Sidebar.rowGrammar.spec.ts`, mounting the sidebar
against a fixture with one pinned chat, one running chat, one chat with a branch and an open PR, one
project with a task, one document, and one selected chat. Behaviours, one per test:

- `gives every chat row the panel's row height`
- `starts every label in the panel at the same left offset`
- `keeps a chat label on that offset whether or not the chat has a branch`
- `puts a project name one indent step right of a section title`
- `renders a count on every section header`
- `keeps every header control on the panel's right action edge`
- `nests no button inside a button`
- `gives a chat row and a project row the same selected background`
- `renders the elapsed time and the relative time at the same font size and weight`

Each asserts a measured box, not a class string, so a rename or a class reshuffle stays green while a
drift goes red. Add a deliberately-failing control run once (drop the branch badge back into the label)
to prove the label-offset test is not vacuous.

## Risks

- Flattening the projects list moves a project row left by 13px and every chat and document label right by
  16px. Anything asserting an absolute x, in a spec or a functional UI test, needs the new number. Grep for
  `41.5`, for `sb-indent` and for the 12px label offset before starting.
- Moving the branch badge changes a right-click target's position. The context menu and its test ids stay;
  only the anchor moves, and it is now always the row's mark column, so its x is constant across rows.
- `WorkerElapsedChip`'s `--text` variant change touches `KanbanTaskRow.vue:318`. Verify that row's slot
  after the change, and if it needs 11px, give it an explicit variant instead of reverting the sidebar.

## Evidence

Reproduce the measurements: `./zig-out/bin/pabrik --port 8080 --static-dir src/apps/desktop/dist/` from
the repo root, then `agent-browser open http://127.0.0.1:8080/app` and read the geometry with
`agent-browser eval`. The numbers, the wireframe's own DOM assertion, and the scanner and inspector
readings are all recorded in the wireframe under "What was measured" and "Gate readings".
