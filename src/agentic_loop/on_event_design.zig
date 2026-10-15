//! JSON payload structs for design-mode SSE events. One struct per wire
//! event: - `DesignElementCreatedData` — emitted on `addElement` (HTTP
//! handler or LLM `add_element` tool).

/// JSON payload for the `design_element_created` SSE event.
pub const DesignElementCreatedData = struct {
    /// "created"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

/// JSON payload for the `design_element_updated` SSE event.
pub const DesignElementUpdatedData = struct {
    /// "updated"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

/// JSON payload for the `design_elements_geometry_batch_updated` SSE event.
/// Emitted by `design_model.updateElementsBatch` after a single atomic
/// transaction moves 1+ elements.
pub const DesignElementsGeometryBatchUpdatedData = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    /// All element ids affected by this batch, in input order. The
    /// frontend listener checks each id against its local-mutation Set
    /// and skips the GET only if EVERY id is in the Set.
    element_ids: []const []const u8,
    /// Unix epoch seconds — matches the timestamp format used by the other
    /// design SSE events. The frontend uses this to break ties when
    /// concurrent edits from another client interleave with the local drag.
    updated_at: i64,
};

/// JSON payload for the `design_element_deleted` SSE event.
pub const DesignElementDeletedData = struct {
    /// "deleted"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

// ─── Page-level events (2026-07-25-design-page-delete-button) ───────────
// Page-level events share the SSE wire envelope shape with the element events
// above (action discriminator + the three parent ids), but omit `element_id`

/// JSON payload for the `design_page_deleted` SSE event.
pub const DesignPageDeletedData = struct {
    /// "deleted"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
};
