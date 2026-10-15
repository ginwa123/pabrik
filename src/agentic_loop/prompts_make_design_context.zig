const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const llm_history = @import("llm_history.zig");
const design_model = @import("design_model.zig");


const MAX_DESIGN_PAGES: u32 = 10;



/// Render the "Design Canvas" markdown block — workflow expectations for the
/// LLM when the session's parent item is a design canvas (`item_type ===
/// 'design'`).
pub fn buildDesignCanvasPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "design")) {
        return allocator.dupe(u8, "");
    }

    const pages = design_model.listPages(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: listPages failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer design_model.freePages(allocator, pages);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Design Canvas\n\n");
    try out.appendSlice(allocator,
        \\This task is on a design canvas (parent item_type: `design`).
        \\**You interact with the canvas via 5 LLM tools** (full schemas
        \\in the tool listing below — pass `workspace_id` + `item_id` from
        \\the `## Workspace Context` section above, and `page_id` is the
        \\page's id from the listing below):
        \\
        \\- `set_design_page(item_id, page_name, width?, height?)` — create
        \\  or look up a page by name. Idempotent: calling with an existing
        \\  name returns the same `page_id`. Defaults: width=1920,
        \\  height=1080.
        \\
        \\**No fixed page bounds.** The canvas-background feature has been
        \\removed (plan docs/superpowers/plans/2026-07-29-remove-canvas-background.md).
        \\Pages are purely logical containers; elements can be placed at
        \\ANY coordinates (positive, negative, or values larger than the
        \\page width / height). The `width` / `height` values on a page
        \\are informational only — a "preferred export size" hint, not
        \\an enforced boundary. Do NOT try to keep elements inside any
        \\specific rectangle; let the user place them wherever the design
        \\needs.
        \\- `add_element(page_id, name, type, html, x?, y?, width?, height?, fill?, rotation?, corner_radius?, opacity?, text_content?, text_style?, image_url?, parent_id?)`
        \\  — add one element to a page. The `html` is the rendered DOM
        \\  fragment (e.g. `<div class="card">...</div>`) that the
        \\  frontend mounts in the canvas at the given (x, y) with the
        \\  given width/height. Geometry defaults to 0/0/100/100; `fill`
        \\  is a CSS color string (`#ffffff`, `rgb(...)`, etc.).
        \\  Pass `parent_id="elem_..."` to nest the new element under
        \\  an existing `group` or `frame` on the same page. Omit
        \\  `parent_id` (or pass `null`) for top-level — same as the
        \\  pre-2026-07-29 behaviour.
        \\- `update_element(element_id, ...)` — patch any subset of the
        \\  element's fields (name, type, html, x/y/width/height/rotation,
        \\  fill, stroke, stroke_width, corner_radius, opacity,
        \\  text_content, text_style, image_url). All fields nullable;
        \\  pass only what changes. **`update_element` does NOT change
        \\  the parent/group hierarchy** — see `set_element_parent` for
        \\  that.
        \\- `set_element_parent(element_id, new_parent_id?)` — re-parent
        \\  an EXISTING element. Pass `new_parent_id="elem_..."` to
        \\  nest it under an existing `group`/`frame`; pass
        \\  `new_parent_id=null` (or omit) to detach back to top-level.
        \\  Use this to fix an element that was created at the wrong
        \\  nesting level — there is no need to delete + re-add.
        \\- `group_elements(page_id, child_ids, name?, type?)` — wrap
        \\  2+ existing top-level elements in a NEW `group` or `frame`
        \\  (unioned bounding box). The new parent is a sibling of the
        \\  children; the children get a new `parent_id` pointing to
        \\  the new group. Use this when you want to group EXISTING
        \\  siblings that you didn't create with a parent.
        \\
        \\**Element types** (pass the string in `add_element`/`update_element`):
        \\
        \\- `rectangle` — filled rect with optional corner_radius + fill.
        \\  Use for backgrounds, cards, buttons, badges.
        \\- `ellipse` — filled ellipse, same geometry as rectangle.
        \\- `text` — text element. The `text_content` field is the
        \\  visible string; `text_style` is a CSS snippet (e.g.
        \\  `"font-size:24px;color:#111;"`).
        \\- `image` — raster image element. The `image_url` field is the
        \\  URL (https:// or data: or relative); `html` is the `<img>`
        \\  fragment the canvas mounts.
        \\- `frame` — a CONTAINER that holds children. Create the frame
        \\  FIRST (via `add_element` with `type='frame'`), then nest
        \\  children inside it with a SECOND `add_element` call passing
        \\  `parent_id=<frame.id>`. Children appear indented under the
        \\  frame in the Layers panel.
        \\- `group` — same as `frame` for nesting (`parent_id` works
        \\  identically), but groups do not visually clip their
        \\  children. Use `frame` for spatial containment (e.g. an app
        \\  window containing panels); use `group` for logical grouping
        \\  (e.g. an icon-button set you want to operate as one unit).
        \\
        \\**Designing INTERACTIVE HTML — the html field is a live
        \\mini-browser, not a flat mockup.**
        \\
        \\Every element's `html` body is rendered inside a sandboxed
        \\`<iframe>` in the user's canvas. The user can switch the
        \\canvas into **Preview mode** (toolbar button or Cmd/Ctrl+P;
        \\Esc exits) and INTERACT with the rendered HTML — type into
        \\inputs, click buttons, toggle switches, scroll, select text,
        \\fill forms end-to-end. The `html` field accepts ANY valid
        \\HTML, not just visual shapes.
        \\
        \\You SHOULD write real interactive elements when the design
        \\is a UI flow the user will exercise:
        \\
        \\- `<input type="text">`, `<input type="email">`, `<input
        \\  type="checkbox">`, `<input type="radio">`, `<textarea>`,
        \\  `<select>` — for forms.
        \\- `<button>` with `onclick="..."` handlers — scripts run in
        \\  the iframe sandbox (`allow-scripts`, no `allow-same-origin`).
        \\  They can manipulate the iframe's own DOM (toggle visibility,
        \\  update text, validate forms) but cannot reach the parent
        \\  document. Cross-iframe state (click X in iframe A → open Y
        \\  in iframe B) is NOT supported — keep state local to one
        \\  element.
        \\- `<a href="...">` links — they navigate inside the iframe,
        \\  not the host app. Useful for tabs / in-iframe "pages".
        \\- `<details>`/`<summary>`, `<dialog>`, native form validation
        \\  (`required`, `pattern`, `min`/`max`) — all work in Preview.
        \\
        \\**Don't** render inputs as `<div>` styled to look like them.
        \\Write the actual `<input>` / `<button>` / `<select>` so the
        \\user can interact in Preview and verify the design works.
        \\Quick comparison:
        \\
        \\  BAD (visual mockup, no interactivity):
        \\    <div style="border:1px solid #ccc;padding:8px;">Email</div>
        \\    <div style="background:#3b82f6;color:#fff;padding:8px 16px;
        \\              border-radius:6px;">Submit</div>
        \\  GOOD (interactive in Preview):
        \\    <form>
        \\      <label>Email <input type="email" required></label>
        \\      <button type="submit">Submit</button>
        \\    </form>
        \\
        \\**Nesting / parent_id rules:**
        \\  1. The parent must exist BEFORE the child. Two `add_element`
        \\     calls: first the parent (frame/group), THEN the child with
        \\     `parent_id=<parent.id>`.
        \\  2. The target parent must have `type='frame'` or `type='group'`
        \\     and be on the SAME page. Leaf types (rectangle, ellipse,
        \\     text, image) cannot contain children — reject with
        \\     `<error>parent_id points to a leaf-type element...</error>`.
        \\  3. To re-parent an EXISTING element (e.g. you created
        \\     `tags-label` at top-level but want it inside `dialog-card`),
        \\     call `set_element_parent(element_id, new_parent_id)`. Do
        \\     NOT pass `parent_id` to `update_element` — that field is
        \\     not in `update_element`'s schema and the call will be
        \\     rejected or silently ignored.
        \\  4. To un-parent (make top-level), call
        \\     `set_element_parent(element_id, null)` or with
        \\     `new_parent_id=""`.
        \\  5. Self-parenting and creating a cycle (target is the element
        \\     itself or any descendant) are rejected with
        \\     `CycleDetected` (the element's `parent_id` is unchanged).
        \\  6. To wrap multiple EXISTING top-level siblings in a new
        \\     group, use `group_elements(page_id, [...child_ids])` —
        \\     creates a new parent + reparents the children atomically.
        \\  7. **Decide your nesting strategy BEFORE you start adding
        \\     elements.** Adding siblings at top-level and then trying
        \\     to bulk-nest them works (via `group_elements` for new
        \\     groups, or `set_element_parent` for an existing one),
        \\     but it's strictly more work than nesting during creation.
        \\     The design viewer shows the Layers panel on the right
        \\     edge — always visually confirm each element is under the
        \\     correct parent after the call.
        \\
        \\**No cross-iframe persistence.** State inside one element's
        \\iframe does NOT survive Preview-mode toggle (the iframe
        \\reloads from the saved `html` on every Preview entry).
        \\Anything the user types or toggles is ephemeral. If a flow
        \\requires real persistence, surface it as an explicit ask
        \\(e.g. "save to backend") — don't promise it works in Preview.
        \\
        \\**Styling scrollbars inside the iframe** — the design preview
        \\renders each element inside a sandboxed `<iframe
        \\sandbox="allow-scripts">` (no `allow-same-origin`). That makes
        \\the iframe a **separate document**: parent-page CSS does NOT
        \\propagate in, so the host's `::-webkit-scrollbar` rules in
        \\`style.css` are ignored inside the preview. If your element
        \\uses `overflow-x: auto`, `overflow-y: auto`, `overflow: auto`,
        \\or `overflow: scroll` on any container, the user will see a
        \\**default light-gray webkit scrollbar** that looks out of
        \\place against the dark pabrik theme.
        \\
        \\To keep designs on-brand, embed a `<style>` block at the top
        \\of the element's `html` body that styles scrollbars using the
        \\pabrik color tokens. Template (paste at the very top of the
        \\`html` string you pass to `add_element` / `update_element`):
        \\
        \\```html
        \\<style>
        \\  ::-webkit-scrollbar { width: 6px; height: 6px; }
        \\  ::-webkit-scrollbar-track { background: transparent; }
        \\  ::-webkit-scrollbar-thumb {
        \\    background: #393836;
        \\    border-radius: 3px;
        \\  }
        \\  ::-webkit-scrollbar-thumb:hover { background: #625e5a; }
        \\  /* Firefox */
        \\  * { scrollbar-width: thin;
        \\        scrollbar-color: #393836 transparent; }
        \\</style>
        \\```
        \\
        \\Use the same template for both `overflow-x` and `overflow-y`
        \\(the `::-webkit-scrollbar` rule covers both axes). Drop it in
        \\unconditionally for any element with a scrolling container —
        \\the cost is ~6 CSS rules and it prevents the "ugly default
        \\scrollbar" regression users hit when they don't see scrollbar
        \\styling in the host app.
        \\
    );

    // 3. Page listing (cap: MAX_DESIGN_PAGES, with footer).
    try out.appendSlice(allocator, "\n**Pages on this canvas** (in flow order):\n");
    if (pages.len == 0) {
        try out.appendSlice(allocator,
            \\_No pages yet._ Call `set_design_page(item_id, "<descriptive name>")`
            \\to create the first one before adding any elements.
            \\
        );
    } else {
        const shown = @min(pages.len, MAX_DESIGN_PAGES);
        for (pages[0..shown]) |p| {
            const pos_str = try std.fmt.allocPrint(allocator, "`, position {d})\n", .{p.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, p.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, p.id);
            try out.appendSlice(allocator, ", width ");
            const w_str = try std.fmt.allocPrint(allocator, "{d}", .{p.width});
            defer allocator.free(w_str);
            try out.appendSlice(allocator, w_str);
            try out.appendSlice(allocator, ", height ");
            const h_str = try std.fmt.allocPrint(allocator, "{d}", .{p.height});
            defer allocator.free(h_str);
            try out.appendSlice(allocator, h_str);
            try out.appendSlice(allocator, pos_str);

            // List visible elements on this page (cap: 8) so the LLM
            // has spatial context without re-querying. Errors degrade
            // gracefully — skip the element list when the DB read fails.
            const elements = design_model.listElements(allocator, db, p.id) catch |err| {
                std.log.warn("BuildDesignCanvasPrompt: listElements failed for page {s}: {}", .{ p.id, err });
                continue;
            };
            defer design_model.freeElements(allocator, elements);

            if (elements.len > 0) {
                try out.appendSlice(allocator, "  Elements:\n");
                const el_shown = @min(elements.len, @as(usize, 8));
                for (elements[0..el_shown]) |e| {
                    try out.appendSlice(allocator, "  - `");
                    try out.appendSlice(allocator, e.name);
                    try out.appendSlice(allocator, "` (");
                    try out.appendSlice(allocator, e.elem_type);
                    try out.appendSlice(allocator, ", id ");
                    try out.appendSlice(allocator, e.id);
                    // Include parent_id so the LLM can see the existing
                    // hierarchy at a glance ("top-level" vs nested under
                    // which container). Empty parent_id = "(top-level)".
                    if (e.parent_id.len > 0) {
                        try out.appendSlice(allocator, ", parent=");
                        try out.appendSlice(allocator, e.parent_id);
                    } else {
                        try out.appendSlice(allocator, ", parent=(top-level)");
                    }
                    const xywh = try std.fmt.allocPrint(allocator, ", x={d} y={d} w={d} h={d}", .{ e.x, e.y, e.width, e.height });
                    defer allocator.free(xywh);
                    try out.appendSlice(allocator, xywh);
                    try out.appendSlice(allocator, ")\n");
                }
                if (elements.len > 8) {
                    const footer = try std.fmt.allocPrint(
                        allocator,
                        "    … and {d} more elements on this page.\n",
                        .{elements.len - 8},
                    );
                    defer allocator.free(footer);
                    try out.appendSlice(allocator, footer);
                }
            }
        }
        if (pages.len > MAX_DESIGN_PAGES) {
            const footer = try std.fmt.allocPrint(
                allocator,
                "… and {d} more pages (cap: {d} shown).\n",
                .{ pages.len - MAX_DESIGN_PAGES, MAX_DESIGN_PAGES },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    // 4. Workflow expectations.
    try out.appendSlice(allocator,
        \\
        \\**Workflow expectations** (these apply every time you touch the canvas):
        \\
        \\- **start** — on first action, call `set_design_page(item_id, "<page>")`
        \\  to create the page (or look up the existing one). Skip if the
        \\  page listing above already shows the page you need.
        \\- **add** — call `add_element(page_id, name, type, html, ...)` for each
        \\  new shape. Pick `type` from the 6 above; pass `html` as the
        \\  rendered fragment (the canvas mounts it inside a positioned
        \\  wrapper). Coordinates (x, y) are top-left in canvas pixels.
        \\- **modify** — call `update_element(element_id, ...)` with the
        \\  changed fields only. The tool re-fetches and returns the full
        \\  element, so you can verify the patch landed.
        \\- **complete** — before your final reply, summarize which
        \\  pages/elements you created and any geometry you set. The user
        \\  sees the canvas update live; a recap keeps the chat history
        \\  aligned with the visual state.
        \\
    );

    return out.toOwnedSlice(allocator);
}
