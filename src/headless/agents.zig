//! `pabrik headless agents` — every configured agent, and the one a call would actually use.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const LlmConfig = pabrikcore.config.LlmConfig;

/// One configured agent, as the JSON prints it.
pub const Row = struct {
    name: []const u8,
    enabled: bool,
    /// The stored `active_profile` names this row, whether or not it is switched on.
    is_active: bool,
};

pub const Effective = struct {
    model: []const u8,
    base_url: []const u8,
    url_style: []const u8,
    backend: []const u8,
    thinking: []const u8,
};

pub const Report = struct {
    /// `active_profile` from the config, verbatim — including a name whose agent is switched off.
    active_profile: ?[]const u8,
    /// The per-session selection this report was asked about (empty = none).
    selection: []const u8,
    /// Sorted by name, so the bytes are stable across runs.
    agents: []const Row,
    /// The cascade's first slot: `selected`, `active` or `top-level`.
    source: []const u8,
    effective: Effective,
};

/// Walk the config the way a request does. `resolveEffectiveAgent` IS the cascade, so nothing here re-decides which agent wins.
pub fn build(allocator: std.mem.Allocator, cfg: *const LlmConfig, selection: []const u8) !Report {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);
    var it = cfg.agents.iterator();
    while (it.next()) |entry| {
        try rows.append(allocator, .{
            .name = entry.key_ptr.*,
            .enabled = entry.value_ptr.enabled,
            .is_active = if (cfg.active_agent) |ap| std.mem.eql(u8, ap, entry.key_ptr.*) else false,
        });
    }
    const owned = try rows.toOwnedSlice(allocator);
    std.mem.sort(Row, owned, {}, struct {
        fn byName(_: void, a: Row, b: Row) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.byName);

    const eff = cfg.resolveEffectiveAgent(selection);
    return .{
        .active_profile = cfg.active_agent,
        .selection = selection,
        .agents = owned,
        .source = switch (eff.source) {
            .selected => "selected",
            .active => "active",
            .top_level => "top-level",
        },
        .effective = .{
            .model = eff.model,
            .base_url = eff.base_url,
            .url_style = eff.url_style,
            .backend = eff.backend,
            .thinking = eff.thinking_str,
        },
    };
}

/// The one JSON object the command prints.
pub fn toJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, report, .{});
}

const testing = std.testing;

fn putAgent(cfg: *LlmConfig, name: []const u8, model: []const u8, url_style: []const u8, enabled: bool) !void {
    const allocator = cfg.allocator;
    try cfg.agents.put(try allocator.dupe(u8, name), .{
        .model = try allocator.dupe(u8, model),
        .base_url = try allocator.dupe(u8, "https://alpha"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "key"),
        .url_style = try allocator.dupe(u8, url_style),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
        .enabled = enabled,
    });
}

fn fixture(allocator: std.mem.Allocator, active: ?[]const u8) !LlmConfig {
    var cfg: LlmConfig = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "top-key"),
        .model = try allocator.dupe(u8, "top-model"),
        .base_url = try allocator.dupe(u8, "https://top"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_agent = if (active) |a| try allocator.dupe(u8, a) else null,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .agents = LlmConfig.AgentsMap.init(allocator),
        .random_names = &.{},
    };
    errdefer cfg.deinit();

    try putAgent(&cfg, "retired", "retired-model", "openai", false);
    try putAgent(&cfg, "live", "live-model", "anthropic", true);
    return cfg;
}

test "agents report: a switched-off active agent is named as active but supplies nothing" {
    var cfg = try fixture(testing.allocator, "retired");
    defer cfg.deinit();

    const report = try build(testing.allocator, &cfg, "");
    defer testing.allocator.free(report.agents);

    try testing.expectEqualStrings("retired", report.active_profile.?);
    try testing.expectEqualStrings("top-level", report.source);
    try testing.expectEqualStrings("top-model", report.effective.model);
}

test "agents report: the rows are sorted by name and carry the enabled flag" {
    var cfg = try fixture(testing.allocator, "retired");
    defer cfg.deinit();

    const report = try build(testing.allocator, &cfg, "");
    defer testing.allocator.free(report.agents);

    try testing.expectEqual(@as(usize, 2), report.agents.len);
    try testing.expectEqualStrings("live", report.agents[0].name);
    try testing.expect(report.agents[0].enabled);
    try testing.expect(!report.agents[0].is_active);
    try testing.expectEqualStrings("retired", report.agents[1].name);
    try testing.expect(!report.agents[1].enabled);
    try testing.expect(report.agents[1].is_active);
}

test "agents report: an enabled selection is the slot that answers" {
    var cfg = try fixture(testing.allocator, null);
    defer cfg.deinit();

    const report = try build(testing.allocator, &cfg, "live");
    defer testing.allocator.free(report.agents);

    try testing.expectEqualStrings("selected", report.source);
    try testing.expectEqualStrings("live-model", report.effective.model);
    try testing.expectEqualStrings("anthropic", report.effective.url_style);
    try testing.expect(report.active_profile == null);
}

test "agents report: a switched-off selection falls to the top-level config" {
    var cfg = try fixture(testing.allocator, null);
    defer cfg.deinit();

    const report = try build(testing.allocator, &cfg, "retired");
    defer testing.allocator.free(report.agents);

    try testing.expectEqualStrings("top-level", report.source);
    try testing.expectEqualStrings("top-model", report.effective.model);
}

test "agents report: serialises to one JSON object" {
    var cfg = try fixture(testing.allocator, "retired");
    defer cfg.deinit();

    const report = try build(testing.allocator, &cfg, "");
    defer testing.allocator.free(report.agents);

    const json = try toJson(testing.allocator, report);
    defer testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("retired", root.get("active_profile").?.string);
    try testing.expectEqualStrings("top-level", root.get("source").?.string);
    try testing.expectEqualStrings("top-model", root.get("effective").?.object.get("model").?.string);
    try testing.expectEqual(@as(usize, 2), root.get("agents").?.array.items.len);
}
