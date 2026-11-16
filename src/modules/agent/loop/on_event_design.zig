//! JSON payload structs for design-mode SSE events.

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
pub const DesignElementsGeometryBatchUpdatedData = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    /// All element ids affected by this batch, in input order.
    element_ids: []const []const u8,
    /// Unix epoch seconds — matches the timestamp format used by the other design SSE events.
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

/// JSON payload for the `design_page_deleted` SSE event.
pub const DesignPageDeletedData = struct {
    /// "deleted"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
};
