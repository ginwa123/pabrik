//! `model_catalog` — the ONE owner of "what do we know about this model?".
//! Source of truth: <https://models.dev/api.json> (227 providers / 8,562
//! models when this was written).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where the catalog comes from. Shown in the UI next to any resolved number.
pub const SOURCE_URL = "https://models.dev/api.json";

/// Bumped when the cache shape changes. A cache written by another schema is
/// rejected (loaded as an error) rather than mis-parsed.
pub const SCHEMA_VERSION: u32 = 1;

/// The `reasoning_effort` values pabrik can actually put on the wire
/// (`parse_thinking.parseReasoningEffort`). models.dev advertises
/// model-specific sets — DeepSeek V4.1 Flash offers `low | high | max` — so
pub const SENDABLE_EFFORT_VALUES = [_][]const u8{ "low", "medium", "high", "auto" };

/// What kind of extended-reasoning control a model exposes.
pub const ReasoningKind = enum {
    /// Not a reasoning model.
    none,
    /// Extended thinking on/off (models.dev `{"type":"toggle"}`).
    toggle,
    /// An effort level (models.dev `{"type":"effort"}`).
    effort,
    /// A token budget (models.dev `{"type":"budget_tokens"}`, Anthropic).
    budget_tokens,
    /// Both an effort level and a budget.
    both,

    pub fn hasEffort(self: ReasoningKind) bool {
        return self == .effort or self == .both;
    }
    pub fn hasBudget(self: ReasoningKind) bool {
        return self == .budget_tokens or self == .both;
    }
};

/// Per-million-token price. Display only — pabrik never bills anything.
pub const Cost = struct { input: f64 = 0, output: f64 = 0 };

pub const ProviderInfo = struct {
    id: []const u8,
    name: []const u8,
    /// models.dev `provider.api`. EMPTY for 25 of 227 providers — `anthropic`
    /// is one of them — so an empty base URL is a real state, not a bug.
    base_url: []const u8 = "",
    /// Derived from `provider.npm`: `anthropic` iff the npm package is
    /// Anthropic's (or the Vertex-Anthropic alias), else `openai`.
    url_style: []const u8 = "openai",
    /// models.dev `provider.env`, e.g. `{"DEEPSEEK_API_KEY"}`. Documentation
    /// for the key field; pabrik never reads the environment for it.
    env: []const []const u8 = &.{},
};

pub const ModelFacts = struct {
    provider_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    context_window: ?u32 = null,
    output_tokens: ?u32 = null,
    reasoning: ReasoningKind = .none,
    /// The model's own effort values, as advertised.
    effort_values: []const []const u8 = &.{},
    /// The subset of `effort_values` pabrik can send.
    effort_values_sendable: []const []const u8 = &.{},
    /// models.dev `budget_tokens.min` (1024 for Anthropic).
    budget_min: ?u32 = null,
    /// Whether the model accepts `temperature`.
    temperature: bool = false,
    cost: ?Cost = null,
};

// ============================================================================
// models.dev's own payload shape — only the fields pabrik consumes.

/// ONE `reasoning_options` entry. Every field below is deliberately LOOSE: a
/// strict reading rejected the whole 5.7 MB payload over one hostile row, and an
/// absent catalog is worse than a slightly incomplete fact about it.
pub const RawReasoningOption = struct {
    @"type": ?[]const u8 = null,
    /// SIGNED on purpose: models.dev writes `-1` for "no minimum" (nvidia
    /// nemotron-3-nano-omni). Read as `u32` this ONE row failed the whole parse;
    /// `budgetMinRaw` turns a non-positive minimum into "no minimum".
    min: ?i64 = null,
    /// `null` ENTRIES occur, not just a null ARRAY: `sarvam-30b` ships
    /// `[null,"low","medium","high"]`, which `[]const []const u8` cannot hold.
    /// The trim skips the nulls instead of failing the parse.
    values: ?[]const ?[]const u8 = null,
    // models.dev also sends a `max` (the ceiling, e.g. 32768); pabrik has no use
    // for it, and `ignore_unknown_fields` drops it.
};

pub const RawLimit = struct { context: ?u32 = null, output: ?u32 = null };

pub const RawCost = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
};

pub const RawModel = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    reasoning: ?bool = null,
    reasoning_options: ?[]const RawReasoningOption = null,
    temperature: ?bool = null,
    limit: ?RawLimit = null,
    cost: ?RawCost = null,
};

pub const RawProvider = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    api: ?[]const u8 = null,
    npm: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    models: ?std.json.ArrayHashMap(RawModel) = null,
};

pub const RawPayload = std.json.ArrayHashMap(RawProvider);

// ============================================================================
// The cache file's own shape (ours, not models.dev's).
// ============================================================================

pub const CacheCost = struct { input: ?f64 = null, output: ?f64 = null };

pub const CacheModel = struct {
    name: ?[]const u8 = null,
    context: ?u32 = null,
    output: ?u32 = null,
    reasoning: ?[]const u8 = null,
    effort_values: ?[]const []const u8 = null,
    budget_min: ?u32 = null,
    temperature: ?bool = null,
    cost: ?CacheCost = null,
};

pub const CacheProvider = struct {
    name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    url_style: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    models: ?std.json.ArrayHashMap(CacheModel) = null,
};

pub const CacheFile = struct {
    schema: ?u32 = null,
    fetched_at_ms: ?i64 = null,
    source: ?[]const u8 = null,
    providers: ?std.json.ArrayHashMap(CacheProvider) = null,
};

// ============================================================================
// Catalog
// ============================================================================

pub const CatalogError = error{
    /// The cache exists but is not our JSON at all.
    InvalidCacheJson,
    /// The cache parses but was written by another schema version.
    UnsupportedCacheSchema,
    OutOfMemory,
};

/// A loaded catalog. Owns every string it hands out — `deinit` frees them all
/// through one arena.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    fetched_at_ms: i64 = 0,
    source: []const u8 = SOURCE_URL,
    /// provider id (lowercased) -> info
    providers: std.StringHashMapUnmanaged(ProviderInfo) = .empty,
    /// "provider/model" (lowercased) -> facts
    models: std.StringHashMapUnmanaged(ModelFacts) = .empty,
    /// bare "model" (lowercased) -> the qualified key it resolved to.
    bare: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(backing: Allocator) Catalog {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Where every string this catalog hands out lives. Public because the
    /// DB store builds a Catalog row by row and must not duplicate the
    /// indexing rules in `putProvider` / `putModel`.
    pub fn allocator(self: *Catalog) Allocator {
        return self.arena.allocator();
    }

    pub fn providerCount(self: *const Catalog) usize {
        return self.providers.count();
    }

    pub fn modelCount(self: *const Catalog) usize {
        return self.models.count();
    }

    pub fn provider(self: *const Catalog, id: []const u8) ?ProviderInfo {
        var buf: [320]u8 = undefined;
        const key = lowerInto(&buf, id) orelse return null;
        return self.providers.get(key);
    }

    /// Add one provider. Strings are duped into the catalog's arena, so the
    /// caller keeps ownership of what it passed in.
    pub fn putProvider(self: *Catalog, info: ProviderInfo) !void {
        const a = self.allocator();
        const id = try lowerAlloc(a, info.id);
        const stored = ProviderInfo{
            .id = id,
            .name = try a.dupe(u8, info.name),
            .base_url = try a.dupe(u8, info.base_url),
            .url_style = try a.dupe(u8, info.url_style),
            .env = try dupeStrings(a, info.env),
        };
        try self.providers.put(a, id, stored);
    }

    /// Add one model and index it under `provider/model` AND under its bare
    /// name.
    pub fn putModel(self: *Catalog, facts: ModelFacts) !void {
        const a = self.allocator();
        const model_id = try lowerAlloc(a, facts.model_id);
        const provider_id = try lowerAlloc(a, facts.provider_id);
        const qualified = try qualifiedAlloc(a, provider_id, model_id);

        var stored = ModelFacts{
            .provider_id = provider_id,
            .provider_name = try a.dupe(u8, facts.provider_name),
            .model_id = model_id,
            .model_name = try a.dupe(u8, facts.model_name),
            .base_url = try a.dupe(u8, facts.base_url),
            .url_style = try a.dupe(u8, facts.url_style),
            .context_window = facts.context_window,
            .output_tokens = facts.output_tokens,
            .reasoning = facts.reasoning,
            .effort_values = try dupeStrings(a, facts.effort_values),
            .budget_min = facts.budget_min,
            .temperature = facts.temperature,
            .cost = facts.cost,
        };
        stored.effort_values_sendable = try intersectSendable(a, stored.effort_values);

        try self.models.put(a, qualified, stored);
        const gop = try self.bare.getOrPut(a, model_id);
        if (!gop.found_existing) gop.value_ptr.* = qualified;
    }

    pub fn setMeta(self: *Catalog, fetched_at_ms: i64, source: []const u8) !void {
        const a = self.allocator();
        self.fetched_at_ms = fetched_at_ms;
        self.source = try a.dupe(u8, source);
    }

    /// Resolve one model. `provider_or_null` is the provider id from the
    /// catalog; pass `null`/`""` when the user typed a bare model name.
    /// Returns `null` for anything unknown — never a fabricated window.
    pub fn lookup(self: *const Catalog, provider_or_null: ?[]const u8, model: []const u8) ?*const ModelFacts {
        if (model.len == 0) return null;

        if (provider_or_null) |p| {
            if (p.len > 0) {
                var pbuf: [128]u8 = undefined;
                var mbuf: [320]u8 = undefined;
                if (lowerInto(&pbuf, p)) |pl| {
                    if (lowerInto(&mbuf, model)) |ml| {
                        if (self.lookupQualified(pl, ml)) |facts| return facts;
                    }
                }
                // A named provider that does not carry this model must NOT fall
                // through to a different provider's copy — that would silently
                // answer for the wrong endpoint.
                if (self.providers.contains(lowerInto(&pbuf, p) orelse return null)) return null;
            }
        }

        var mbuf: [320]u8 = undefined;
        const ml = lowerInto(&mbuf, model) orelse return null;
        const qualified = self.bare.get(ml) orelse return null;
        return self.models.getPtr(qualified);
    }

    fn lookupQualified(self: *const Catalog, lower_provider: []const u8, lower_model: []const u8) ?*const ModelFacts {
        var buf: [512]u8 = undefined;
        const key = qualifiedInto(&buf, lower_provider, lower_model) orelse return null;
        return self.models.getPtr(key);
    }

    /// The cache's own shape -> a Catalog. Pure: no filesystem, no network.
    pub fn fromCacheJson(backing: Allocator, body: []const u8) CatalogError!Catalog {
        const alloc = backing;
        var parsed = std.json.parseFromSlice(CacheFile, alloc, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return CatalogError.InvalidCacheJson;
        defer parsed.deinit();

        var cat = Catalog.init(alloc);
        errdefer cat.deinit();
        const a = cat.allocator();

        const file = parsed.value;
        const schema = file.schema orelse return CatalogError.UnsupportedCacheSchema;
        if (schema != SCHEMA_VERSION) return CatalogError.UnsupportedCacheSchema;
        cat.fetched_at_ms = file.fetched_at_ms orelse 0;
        cat.source = if (file.source) |s| try a.dupe(u8, s) else SOURCE_URL;

        const providers = file.providers orelse return cat;
        const keys = providers.map.keys();
        const values = providers.map.values();

        for (keys, values) |raw_id, cp| {
            const base_url = if (cp.base_url) |b| b else "";
            const url_style = if (cp.url_style) |st| st else "openai";
            try cat.putProvider(.{
                .id = raw_id,
                .name = cp.name orelse raw_id,
                .base_url = base_url,
                .url_style = url_style,
                .env = cp.env orelse &.{},
            });

            const cmodels = cp.models orelse continue;
            const mkeys = cmodels.map.keys();
            const mvalues = cmodels.map.values();
            for (mkeys, mvalues) |raw_model_id, cm| {
                try cat.putModel(.{
                    .provider_id = raw_id,
                    .provider_name = cp.name orelse raw_id,
                    .model_id = raw_model_id,
                    .model_name = cm.name orelse raw_model_id,
                    .base_url = base_url,
                    .url_style = url_style,
                    .context_window = cm.context,
                    .output_tokens = cm.output,
                    .reasoning = parseReasoningKind(cm.reasoning),
                    .effort_values = cm.effort_values orelse &.{},
                    .budget_min = cm.budget_min,
                    .temperature = cm.temperature orelse false,
                    .cost = if (cm.cost) |c| Cost{
                        .input = c.input orelse 0,
                        .output = c.output orelse 0,
                    } else null,
                });
            }
        }

        return cat;
    }
};

// ============================================================================
// Trim — models.dev's payload -> our shape
// ============================================================================

/// models.dev's payload -> our compact shape. `ignore_unknown_fields` is what
/// makes this a trim: the raw document is ~5.45 MB and carries ~20 fields per
/// model, of which pabrik consumes seven.
pub fn trimRawPayload(alloc: Allocator, body: []const u8, fetched_at_ms: i64) ![]u8 {
    var parsed = std.json.parseFromSlice(RawPayload, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidPayloadJson;
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"schema\":");
    try w.print("{d}", .{SCHEMA_VERSION});
    try w.writeAll(",\"fetched_at_ms\":");
    try w.print("{d}", .{fetched_at_ms});
    try w.writeAll(",\"source\":");
    try std.json.Stringify.encodeJsonString(SOURCE_URL, .{}, w);
    try w.writeAll(",\"providers\":{");

    const provs = parsed.value;
    const pkeys = provs.map.keys();
    const pvalues = provs.map.values();
    var first_provider = true;
    for (pkeys, pvalues) |pid, rp| {
        if (!first_provider) try w.writeByte(',');
        first_provider = false;

        try std.json.Stringify.encodeJsonString(pid, .{}, w);
        try w.writeAll(":{\"name\":");
        try std.json.Stringify.encodeJsonString(rp.name orelse pid, .{}, w);

        // Only emit `base_url` when the provider actually has one — 25 of 227
        // do not, and an absent key is the honest encoding of that.
        if (rp.api) |api| {
            if (api.len > 0) {
                try w.writeAll(",\"base_url\":");
                try std.json.Stringify.encodeJsonString(api, .{}, w);
            }
        }
        try w.writeAll(",\"url_style\":");
        try std.json.Stringify.encodeJsonString(urlStyleForNpm(rp.npm), .{}, w);

        if (rp.env) |env_list| {
            if (env_list.len > 0) {
                try w.writeAll(",\"env\":[");
                for (env_list, 0..) |e, i| {
                    if (i > 0) try w.writeByte(',');
                    try std.json.Stringify.encodeJsonString(e, .{}, w);
                }
                try w.writeByte(']');
            }
        }

        try w.writeAll(",\"models\":{");
        if (rp.models) |ms| {
            const mkeys = ms.map.keys();
            const mvalues = ms.map.values();
            var first_model = true;
            for (mkeys, mvalues) |mid, rm| {
                if (!first_model) try w.writeByte(',');
                first_model = false;
                try std.json.Stringify.encodeJsonString(mid, .{}, w);
                try w.writeAll(":{\"name\":");
                try std.json.Stringify.encodeJsonString(rm.name orelse mid, .{}, w);

                if (rm.limit) |lim| {
                    if (lim.context) |c| {
                        try w.writeAll(",\"context\":");
                        try w.print("{d}", .{c});
                    }
                    if (lim.output) |o| {
                        try w.writeAll(",\"output\":");
                        try w.print("{d}", .{o});
                    }
                }

                const kind = reasoningFromRaw(rm);
                try w.writeAll(",\"reasoning\":");
                try std.json.Stringify.encodeJsonString(reasoningKindName(kind), .{}, w);

                if (effortValuesRaw(rm)) |vals| {
                    // Null entries are dropped, not encoded: a `null` is not an
                    // effort level and the cache's own shape is `[]const []const u8`.
                    var kept: usize = 0;
                    for (vals) |maybe| {
                        if (maybe != null) kept += 1;
                    }
                    if (kept > 0) {
                        try w.writeAll(",\"effort_values\":[");
                        var written: usize = 0;
                        for (vals) |maybe| {
                            const v = maybe orelse continue;
                            if (written > 0) try w.writeByte(',');
                            written += 1;
                            try std.json.Stringify.encodeJsonString(v, .{}, w);
                        }
                        try w.writeByte(']');
                    }
                }
                if (budgetMinRaw(rm)) |m| {
                    try w.writeAll(",\"budget_min\":");
                    try w.print("{d}", .{m});
                }
                if (rm.temperature orelse false) {
                    try w.writeAll(",\"temperature\":true");
                }
                if (rm.cost) |c| {
                    try w.writeAll(",\"cost\":{\"input\":");
                    try w.print("{d}", .{c.input orelse 0});
                    try w.writeAll(",\"output\":");
                    try w.print("{d}", .{c.output orelse 0});
                    try w.writeByte('}');
                }
                try w.writeByte('}');
            }
        }
        try w.writeAll("}}");
    }

    try w.writeAll("}}");
    return aw.toOwnedSlice();
}

/// models.dev's `reasoning_options` -> our `ReasoningKind`. A model can declare
/// both an effort control and a token budget; `reasoning: true` with no options
/// at all is a plain on/off toggle.
fn reasoningFromRaw(m: RawModel) ReasoningKind {
    const opts = m.reasoning_options orelse &.{};
    var has_effort = false;
    var has_budget = false;
    for (opts) |o| {
        const t = o.@"type" orelse continue;
        if (std.mem.eql(u8, t, "effort")) has_effort = true;
        if (std.mem.eql(u8, t, "budget_tokens")) has_budget = true;
    }
    if (has_effort and has_budget) return .both;
    if (has_effort) return .effort;
    if (has_budget) return .budget_tokens;
    if (m.reasoning orelse false) return .toggle;
    return .none;
}

/// The model's advertised effort values, nulls included: models.dev puts a bare
/// `null` in this array (`sarvam/sarvam-30b`), and the caller drops it.
fn effortValuesRaw(m: RawModel) ?[]const ?[]const u8 {
    const opts = m.reasoning_options orelse return null;
    for (opts) |o| {
        const t = o.@"type" orelse continue;
        if (std.mem.eql(u8, t, "effort")) return o.values;
    }
    return null;
}

/// The model's budget floor. models.dev types this SIGNED and uses `-1` for
/// "none" (nvidia nemotron); anything that cannot be a token floor becomes
/// `null` — "the catalog does not know" — never a clamped lie.
fn budgetMinRaw(m: RawModel) ?u32 {
    const opts = m.reasoning_options orelse return null;
    for (opts) |o| {
        const t = o.@"type" orelse continue;
        if (!std.mem.eql(u8, t, "budget_tokens")) continue;
        const raw = o.min orelse return null;
        if (raw <= 0 or raw > std.math.maxInt(u32)) return null;
        return @intCast(raw);
    }
    return null;
}

// ============================================================================
// helpers
// ============================================================================

/// Stored tag name -> kind. Public because the DB store round-trips it.
pub fn parseReasoningKind(raw: ?[]const u8) ReasoningKind {
    const s = raw orelse return .none;
    if (std.mem.eql(u8, s, "toggle")) return .toggle;
    if (std.mem.eql(u8, s, "effort")) return .effort;
    if (std.mem.eql(u8, s, "budget_tokens")) return .budget_tokens;
    if (std.mem.eql(u8, s, "both")) return .both;
    return .none;
}

pub fn reasoningKindName(k: ReasoningKind) []const u8 {
    return @tagName(k);
}

/// ASCII-lowercase `src` into `buf`. `null` when it does not fit — callers
/// treat that as "no match" rather than allocating, so lookups stay allocation
/// free.
fn lowerInto(buf: []u8, src: []const u8) ?[]u8 {
    if (src.len > buf.len) return null;
    for (src, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..src.len];
}

fn lowerAlloc(a: Allocator, src: []const u8) ![]u8 {
    const out = try a.alloc(u8, src.len);
    for (src, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn qualifiedInto(buf: []u8, lower_provider: []const u8, lower_model: []const u8) ?[]u8 {
    const need = lower_provider.len + 1 + lower_model.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..lower_provider.len], lower_provider);
    buf[lower_provider.len] = '/';
    @memcpy(buf[lower_provider.len + 1 ..][0..lower_model.len], lower_model);
    return buf[0..need];
}

fn qualifiedAlloc(a: Allocator, lower_provider: []const u8, lower_model: []const u8) ![]u8 {
    const out = try a.alloc(u8, lower_provider.len + 1 + lower_model.len);
    @memcpy(out[0..lower_provider.len], lower_provider);
    out[lower_provider.len] = '/';
    @memcpy(out[lower_provider.len + 1 ..], lower_model);
    return out;
}

fn dupeStrings(a: Allocator, src: ?[]const []const u8) ![]const []const u8 {
    const list = src orelse return &.{};
    const out = try a.alloc([]const u8, list.len);
    for (list, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

/// The model's advertised effort values, filtered to the ones pabrik can send.
/// Order follows the model's own list, so the UI can name them in that order.
fn intersectSendable(a: Allocator, values: []const []const u8) ![]const []const u8 {
    var n: usize = 0;
    for (values) |v| {
        for (SENDABLE_EFFORT_VALUES) |s| {
            if (std.ascii.eqlIgnoreCase(v, s)) {
                n += 1;
                break;
            }
        }
    }
    if (n == 0) return &.{};
    const out = try a.alloc([]const u8, n);
    var i: usize = 0;
    for (values) |v| {
        for (SENDABLE_EFFORT_VALUES) |s| {
            if (std.ascii.eqlIgnoreCase(v, s)) {
                out[i] = s;
                i += 1;
                break;
            }
        }
    }
    return out;
}

// ============================================================================
// Trim + cache file
// ============================================================================

pub fn freeCatalog(backing: Allocator, cat: *Catalog) void {
    cat.deinit();
    backing.destroy(cat);
}

// ============================================================================
// Process-wide holder The compaction decision is made deep inside the
// workflow loop, which has no request context to thread a catalog through.

var singleton: ?*Catalog = null;
/// Retired catalogs are deliberately NOT freed on swap: a refresh handler
/// swaps the pointer while a workflow thread may still be reading through the
/// old one, and a use-after-free is not worth a bounded-memory win.
var retired: std.ArrayList(*Catalog) = .empty;
var retired_owner: ?Allocator = null;

pub fn getSingleton() ?*const Catalog {
    return singleton;
}

/// Install `cat` (may be null). Any previously installed catalog is retired,
/// never freed — see the note above.
pub fn setSingleton(cat: ?*Catalog, owner: Allocator) void {
    if (singleton) |old| {
        retired.append(owner, old) catch {};
        retired_owner = owner;
    }
    singleton = cat;
}

pub fn retireCount() usize {
    return retired.items.len;
}

/// Tear the holder down. For tests and process shutdown only — never called
/// from a request path.
pub fn deinitSingleton(owner: Allocator) void {
    if (singleton) |cur| freeCatalog(owner, cur);
    singleton = null;
    for (retired.items) |old| freeCatalog(owner, old);
    retired.deinit(owner);
    retired = .empty;
    retired_owner = null;
}

/// models.dev `provider.npm` -> pabrik's `url_style`.
pub fn urlStyleForNpm(npm: ?[]const u8) []const u8 {
    const s = npm orelse return "openai";
    if (std.mem.indexOf(u8, s, "anthropic") != null) return "anthropic";
    return "openai";
}

// ============================================================================
// Tests These exercise the PURE half only — parse + lookup.

const testing = std.testing;

/// Shaped exactly like a real cache file. `deepseek-flash` deliberately appears
/// under TWO providers with the same window, and `anthropic` deliberately has
/// no `base_url` — both states occur in the real catalog.
const FIXTURE =
    \\{
    \\  "schema": 1,
    \\  "fetched_at_ms": 1760000000000,
    \\  "source": "https://models.dev/api.json",
    \\  "providers": {
    \\    "deepseek": {
    \\      "name": "DeepSeek",
    \\      "base_url": "https://api.deepseek.com",
    \\      "url_style": "openai",
    \\      "env": ["DEEPSEEK_API_KEY"],
    \\      "models": {
    \\        "deepseek-flash": {
    \\          "name": "DeepSeek V4.1 Flash",
    \\          "context": 1000000,
    \\          "output": 393216,
    \\          "reasoning": "effort",
    \\          "effort_values": ["low", "high", "max"],
    \\          "temperature": true,
    \\          "cost": { "input": 0.15, "output": 0.6 }
    \\        }
    \\      }
    \\    },
    \\    "anthropic": {
    \\      "name": "Anthropic",
    \\      "url_style": "anthropic",
    \\      "env": ["ANTHROPIC_API_KEY"],
    \\      "models": {
    \\        "claude-haiku-4-5": {
    \\          "name": "Claude Haiku 4.5 (latest)",
    \\          "context": 200000,
    \\          "output": 64000,
    \\          "reasoning": "budget_tokens",
    \\          "budget_min": 1024
    \\        }
    \\      }
    \\    },
    \\    "opencode-go": {
    \\      "name": "opencode-go",
    \\      "base_url": "https://opencode.ai/inference/go/v1",
    \\      "url_style": "openai",
    \\      "models": {
    \\        "deepseek-flash": { "name": "DeepSeek V4.1 Flash (go)", "context": 1000000 }
    \\      }
    \\    }
    \\  }
    \\}
;

test "ModelCatalog: an unknown model resolves to null, never a fabricated window" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    try testing.expect(cat.lookup(null, "gpt-does-not-exist") == null);
    try testing.expect(cat.lookup("deepseek", "gpt-does-not-exist") == null);
    try testing.expect(cat.lookup("no-such-provider", "no-such-model") == null);
    // Empty input is not a lookup, it is a missing field.
    try testing.expect(cat.lookup(null, "") == null);
}

test "ModelCatalog: the catalog reports its own size" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    try testing.expectEqual(@as(usize, 3), cat.providerCount());
    try testing.expectEqual(@as(usize, 3), cat.modelCount());
    try testing.expectEqual(@as(i64, 1_760_000_000_000), cat.fetched_at_ms);
    try testing.expectEqualStrings("https://models.dev/api.json", cat.source);
}

test "ModelCatalog: provider-scoped lookup answers for THAT provider's endpoint" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    const ds = cat.lookup("deepseek", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek", ds.provider_id);
    try testing.expectEqualStrings("https://api.deepseek.com", ds.base_url);
    try testing.expectEqual(@as(u32, 1_000_000), ds.context_window.?);
    try testing.expectEqual(@as(u32, 393_216), ds.output_tokens.?);
    try testing.expectEqualStrings("openai", ds.url_style);
    try testing.expect(ds.temperature);
    try testing.expectEqual(@as(f64, 0.15), ds.cost.?.input);
    try testing.expectEqual(@as(f64, 0.6), ds.cost.?.output);

    // Same model id, different provider, different endpoint.
    const go = cat.lookup("opencode-go", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("opencode-go", go.provider_id);
    try testing.expectEqualStrings("https://opencode.ai/inference/go/v1", go.base_url);
}

test "ModelCatalog: a KNOWN provider that lacks the model does not fall through" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    // `anthropic` exists but ships no `deepseek-flash`. Answering with
    // DeepSeek's copy would silently describe the wrong endpoint.
    try testing.expect(cat.lookup("anthropic", "deepseek-flash") == null);

    // An UNKNOWN provider id is a different case: the user typed a custom
    // provider, so the bare-name match is the best available answer.
    const via_unknown = cat.lookup("my-self-hosted", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek", via_unknown.provider_id);
}

test "ModelCatalog: a bare model name resolves, and names the provider it picked" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    const facts = cat.lookup(null, "deepseek-flash") orelse return error.TestUnexpectedResult;
    // First wins in cache order — the caller must show which one it got.
    try testing.expectEqualStrings("deepseek", facts.provider_id);
    try testing.expectEqual(@as(u32, 1_000_000), facts.context_window.?);
}

test "ModelCatalog: lookup is case-insensitive on both halves" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    try testing.expect(cat.lookup("DeepSeek", "DeepSeek-Flash") != null);
    try testing.expect(cat.lookup(null, "DEEPSEEK-FLASH") != null);
    const p = cat.provider("Anthropic") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("anthropic", p.id);
}

test "ModelCatalog: a provider with no api keeps its style and an empty base url" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    const p = cat.provider("anthropic") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", p.base_url);
    try testing.expectEqualStrings("anthropic", p.url_style);
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", p.env[0]);

    // The model inherits it — an empty base_url is a real state, not a bug.
    const m = cat.lookup("anthropic", "claude-haiku-4-5") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", m.base_url);
    try testing.expectEqualStrings("anthropic", m.url_style);
    try testing.expectEqual(ReasoningKind.budget_tokens, m.reasoning);
    try testing.expect(m.reasoning.hasBudget());
    try testing.expect(!m.reasoning.hasEffort());
    try testing.expectEqual(@as(u32, 1024), m.budget_min.?);
    try testing.expect(m.cost == null);
}

test "ModelCatalog: effort values are intersected with what pabrik can send" {
    var cat = try Catalog.fromCacheJson(testing.allocator, FIXTURE);
    defer cat.deinit();

    const m = cat.lookup("deepseek", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.effort, m.reasoning);
    try testing.expect(m.reasoning.hasEffort());
    try testing.expect(!m.reasoning.hasBudget());

    // The model advertises three; pabrik speaks four. `max` is not one of them,
    // so it is reported to the user but never offered for sending.
    try testing.expectEqual(@as(usize, 3), m.effort_values.len);
    try testing.expectEqualStrings("max", m.effort_values[2]);
    try testing.expectEqual(@as(usize, 2), m.effort_values_sendable.len);
    try testing.expectEqualStrings("low", m.effort_values_sendable[0]);
    try testing.expectEqualStrings("high", m.effort_values_sendable[1]);
}

test "ModelCatalog: url_style comes from the provider npm package" {
    try testing.expectEqualStrings("anthropic", urlStyleForNpm("@ai-sdk/anthropic"));
    try testing.expectEqualStrings("anthropic", urlStyleForNpm("@ai-sdk/google-vertex/anthropic"));
    try testing.expectEqualStrings("openai", urlStyleForNpm("@ai-sdk/openai-compatible"));
    try testing.expectEqualStrings("openai", urlStyleForNpm("@openrouter/ai-sdk-provider"));
    // 25 of 227 providers have no npm either; openai is the safe shape.
    try testing.expectEqualStrings("openai", urlStyleForNpm(null));
}

test "ModelCatalog: a cache that is not our JSON is an ERROR, not an empty catalog" {
    try testing.expectError(CatalogError.InvalidCacheJson, Catalog.fromCacheJson(testing.allocator, "not json at all"));
    try testing.expectError(CatalogError.InvalidCacheJson, Catalog.fromCacheJson(testing.allocator, "[]"));
    try testing.expectError(CatalogError.InvalidCacheJson, Catalog.fromCacheJson(testing.allocator, ""));
    // Truncated mid-object — the torn-write case.
    try testing.expectError(CatalogError.InvalidCacheJson, Catalog.fromCacheJson(testing.allocator, "{\"schema\":1,\"providers\":{"));
}

test "ModelCatalog: a cache from another schema version is rejected, not mis-parsed" {
    try testing.expectError(CatalogError.UnsupportedCacheSchema, Catalog.fromCacheJson(testing.allocator, "{\"schema\":99}"));
    try testing.expectError(CatalogError.UnsupportedCacheSchema, Catalog.fromCacheJson(testing.allocator, "{}"));
}

test "ModelCatalog: an empty provider map is a VALID empty catalog" {
    var cat = try Catalog.fromCacheJson(testing.allocator, "{\"schema\":1,\"providers\":{}}");
    defer cat.deinit();

    try testing.expectEqual(@as(usize, 0), cat.providerCount());
    try testing.expectEqual(@as(usize, 0), cat.modelCount());
    try testing.expect(cat.lookup(null, "anything") == null);
}

/// Shaped like models.dev's OWN api.json — deliberately carrying the fields
/// pabrik drops, so the trim test can prove they are dropped.
const RAW_FIXTURE =
    \\{
    \\  "deepseek": {
    \\    "id": "deepseek",
    \\    "env": ["DEEPSEEK_API_KEY"],
    \\    "npm": "@ai-sdk/openai-compatible",
    \\    "api": "https://api.deepseek.com",
    \\    "name": "DeepSeek",
    \\    "doc": "https://api-docs.deepseek.com",
    \\    "models": {
    \\      "deepseek-flash": {
    \\        "id": "deepseek-flash",
    \\        "name": "DeepSeek V4.1 Flash",
    \\        "description": "reasoning and agentic coding",
    \\        "family": "deepseek-flash",
    \\        "attachment": true,
    \\        "reasoning": true,
    \\        "reasoning_options": [{ "type": "toggle" }, { "type": "effort", "values": ["low", "high", "max"] }],
    \\        "tool_call": true,
    \\        "knowledge": "2025-05",
    \\        "release_date": "2026-09-10",
    \\        "modalities": { "input": ["text", "image"], "output": ["text"] },
    \\        "open_weights": true,
    \\        "limit": { "context": 1000000, "output": 393216 },
    \\        "temperature": true,
    \\        "status": "deprecated",
    \\        "cost": { "input": 0.15, "output": 0.6, "cache_read": 0.003 },
    \\        "canonical_model_id": "deepseek/deepseek-v4.1-flash"
    \\      }
    \\    }
    \\  },
    \\  "anthropic": {
    \\    "id": "anthropic",
    \\    "env": ["ANTHROPIC_API_KEY"],
    \\    "npm": "@ai-sdk/anthropic",
    \\    "name": "Anthropic",
    \\    "doc": "https://docs.anthropic.com",
    \\    "models": {
    \\      "claude-haiku-4-5": {
    \\        "id": "claude-haiku-4-5",
    \\        "name": "Claude Haiku 4.5 (latest)",
    \\        "reasoning": true,
    \\        "reasoning_options": [{ "type": "budget_tokens", "min": 1024 }],
    \\        "temperature": true,
    \\        "limit": { "context": 200000, "output": 64000 },
    \\        "cost": { "input": 1, "output": 5 }
    \\      }
    \\    }
    \\  },
    \\  "toggle-only": {
    \\    "id": "toggle-only",
    \\    "npm": "@ai-sdk/openai-compatible",
    \\    "name": "Toggle Only",
    \\    "models": {
    \\      "thinks": { "id": "thinks", "name": "Thinks", "reasoning": true, "limit": { "context": 128000 } },
    \\      "plain": { "id": "plain", "name": "Plain", "limit": { "context": 8000 } }
    \\    }
    \\  }
    \\}
;

test "ModelCatalog: trim keeps the seven fields pabrik acts on and drops the rest" {
    const alloc = testing.allocator;
    const trimmed = try trimRawPayload(alloc, RAW_FIXTURE, 1_760_000_000_000);
    defer alloc.free(trimmed);

    // Fields pabrik never reads must not survive the trim — that is the whole
    // point of shipping a 2.3 MB cache instead of a 5.45 MB payload.
    for ([_][]const u8{
        "deprecated",   "canonical_model_id", "modalities",
        "open_weights", "knowledge",          "release_date",
        "description",  "tool_call",          "cache_read",
    }) |dropped| {
        try testing.expect(std.mem.indexOf(u8, trimmed, dropped) == null);
    }

    var cat = try Catalog.fromCacheJson(alloc, trimmed);
    defer cat.deinit();

    const m = cat.lookup("deepseek", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1_000_000), m.context_window.?);
    try testing.expectEqual(@as(u32, 393_216), m.output_tokens.?);
    try testing.expectEqual(ReasoningKind.effort, m.reasoning);
    try testing.expectEqualStrings("https://api.deepseek.com", m.base_url);
    try testing.expect(m.temperature);

    // The provider without an `api` key keeps its style and no base url.
    const a = cat.provider("anthropic") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("anthropic", a.url_style);
    try testing.expectEqualStrings("", a.base_url);
    const c = cat.lookup("anthropic", "claude-haiku-4-5") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1024), c.budget_min.?);
}

test "ModelCatalog: trim infers the reasoning shape, including a bare toggle" {
    const alloc = testing.allocator;
    const trimmed = try trimRawPayload(alloc, RAW_FIXTURE, 0);
    defer alloc.free(trimmed);

    var cat = try Catalog.fromCacheJson(alloc, trimmed);
    defer cat.deinit();

    // `reasoning: true` with no options at all is an on/off toggle.
    const t = cat.lookup("toggle-only", "thinks") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.toggle, t.reasoning);
    try testing.expect(!t.reasoning.hasEffort());
    try testing.expect(!t.reasoning.hasBudget());

    // A model that declares no extended reasoning gets `none`, not a guess.
    const p = cat.lookup("toggle-only", "plain") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.none, p.reasoning);
    try testing.expectEqual(@as(u32, 8000), p.context_window.?);

    // Effort + toggle together is still an effort control: the toggle is
    // pabrik's own `thinking` field, which the effort dropdown does not replace.
    const d = cat.lookup("deepseek", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.effort, d.reasoning);
}

test "ModelCatalog: trim rejects a payload that is not models.dev JSON" {
    try testing.expectError(error.InvalidPayloadJson, trimRawPayload(testing.allocator, "nope", 0));
    try testing.expectError(error.InvalidPayloadJson, trimRawPayload(testing.allocator, "", 0));
    // Truncated mid-download.
    try testing.expectError(error.InvalidPayloadJson, trimRawPayload(testing.allocator, "{\"deepseek\":{\"models\":", 0));
}

/// Two REAL models.dev rows, copied verbatim from the 2026-10-16 payload, that
/// used to reject the whole document. `raw` stays a string literal so the exact
/// bytes under test are visible in the test.
const RAW_HOSTILE_FIXTURE =
    \\{
    \\  "sarvam": {
    \\    "id": "sarvam",
    \\    "name": "Sarvam",
    \\    "models": {
    \\      "sarvam-30b": {
    \\        "id": "sarvam-30b",
    \\        "name": "Sarvam 30B",
    \\        "reasoning": true,
    \\        "reasoning_options": [{ "type": "effort", "values": [null, "low", "medium", "high"] }],
    \\        "limit": { "context": 131072 }
    \\      }
    \\    }
    \\  },
    \\  "nvidia": {
    \\    "id": "nvidia",
    \\    "name": "NVIDIA",
    \\    "models": {
    \\      "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning": {
    \\        "name": "Nemotron 3 Nano Omni 30B A3B Reasoning",
    \\        "reasoning": true,
    \\        "reasoning_options": [{ "type": "toggle" }, { "type": "budget_tokens", "min": -1, "max": 32768 }],
    \\        "limit": { "context": 131072, "output": 32768 }
    \\      }
    \\    }
    \\  }
    \\}
;

test "ModelCatalog: trim survives the two real rows that used to blank the catalog" {
    const alloc = testing.allocator;

    // WHY (2026-10-16): these two rows failed the ENTIRE payload's parse, which
    // is why the DB stayed empty and every agent answered "no catalog yet".
    const trimmed = try trimRawPayload(alloc, RAW_HOSTILE_FIXTURE, 0);
    defer alloc.free(trimmed);

    var cat = try Catalog.fromCacheJson(alloc, trimmed);
    defer cat.deinit();

    // Neither provider was lost to the other one's bad row.
    try testing.expectEqual(@as(usize, 2), cat.providerCount());
    try testing.expectEqual(@as(usize, 2), cat.modelCount());

    // The null entry is DROPPED, the real effort levels survive in order.
    const sarvam = cat.lookup("sarvam", "sarvam-30b") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.effort, sarvam.reasoning);
    try testing.expectEqual(@as(usize, 3), sarvam.effort_values.len);
    try testing.expectEqualStrings("low", sarvam.effort_values[0]);
    try testing.expectEqualStrings("medium", sarvam.effort_values[1]);
    try testing.expectEqualStrings("high", sarvam.effort_values[2]);
    try testing.expectEqual(@as(u32, 131_072), sarvam.context_window.?);

    // A non-positive floor is "the catalog does not know a floor" — not a parse
    // failure, and not a clamped `1` either.
    const nvidia = cat.lookup("nvidia", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(ReasoningKind.budget_tokens, nvidia.reasoning);
    try testing.expect(nvidia.reasoning.hasBudget());
    try testing.expect(nvidia.budget_min == null);
    try testing.expectEqual(@as(u32, 131_072), nvidia.context_window.?);
    try testing.expectEqual(@as(u32, 32_768), nvidia.output_tokens.?);
}

test "ModelCatalog: installing a catalog retires the previous one instead of freeing it" {
    const alloc = testing.allocator;
    const first = try alloc.create(Catalog);
    first.* = try Catalog.fromCacheJson(alloc, FIXTURE);
    const second = try alloc.create(Catalog);
    second.* = try Catalog.fromCacheJson(alloc, FIXTURE);

    defer deinitSingleton(alloc);
    const before = retireCount();

    setSingleton(first, alloc);
    try testing.expect(getSingleton().?.lookup("deepseek", "deepseek-flash") != null);

    setSingleton(second, alloc);
    // The swap is visible AND the old catalog was retired, not freed — a
    // workflow thread may still be reading through it.
    try testing.expectEqual(@as(usize, before + 1), retireCount());
    try testing.expect(getSingleton().? == second);

    setSingleton(null, alloc);
    try testing.expect(getSingleton() == null);
}
