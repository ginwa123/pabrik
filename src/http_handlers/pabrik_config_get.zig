const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const config = pabrikcore.config;
const user_config_store = pabrikcore.user_config_store;
const web_search_mask = @import("web_search_mask.zig");
const LlmConfig = config.LlmConfig;

/// GET /api/config/pabrik - Get pabrik.json configuration
pub fn pabrikConfigGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    // Auth mode: per-user config from users.config_json (Migration 092).
    // config.json is ignored. NULL/empty = defaults (same as missing file).
    if (di.auth_enabled) {
        const tok = auth_common.parseSessionToken(req.headers) orelse {
            return res.jsonResponse(.{
                .status_code = 401,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
            });
        };
        const sess = auth_common.lookupSession(allocator, di.db, tok) orelse {
            return res.jsonResponse(.{
                .status_code = 401,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
            });
        };
        defer auth_common.freeSessionLookup(allocator, sess);
        const stored = user_config_store.loadRaw(allocator, di.db, sess.user_id) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to load user config" }),
            });
        };
        defer if (stored) |s| allocator.free(s);
        const content = stored orelse {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try http_response.makePabrikConfigResponse(allocator, .{}),
            });
        };
        const parsed = std.json.parseFromSliceLeaky(ConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse user config: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON in user config" }),
            });
        };
        const cfg = parsed;

        // Masking happens inside `makeConfigResponse`, which is the ONE
        // place the wire shape is built - so this branch and the file branch
        // below cannot disagree about it.
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try makeConfigResponse(allocator, cfg),
        });
    }
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    // Cast const away since getDefaultConfigPath doesn't actually modify environment
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

    // Get the default config path
    const config_path = config.getDefaultConfigPath(allocator, environment) catch |err| {
        std.log.err("Failed to get config path: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config path" }),
        });
    };

    // Try to read the config file
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch {
        // If file doesn't exist, return an empty profile-only config
        // (plan 2026-08-24-config-simplify-remove-defaults: no top-level
        // LLM defaults on the wire).
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try http_response.makePabrikConfigResponse(allocator, .{}),
        });
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("Failed to read config: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read config" }),
        });
    };

    // Parse and return the config
    const parsed = std.json.parseFromSliceLeaky(ConfigJson, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse config: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON in config" }),
        });
    };

    const cfg = parsed;

    // Masking happens inside `makeConfigResponse` - see the auth branch above.
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try makeConfigResponse(allocator, cfg),
    });
}

/// The wire shape for one parsed config, in ONE place.
pub fn makeConfigResponse(allocator: std.mem.Allocator, cfg: ConfigJson) ![]u8 {
    // Mask every provider credential before it reaches the browser. The
    // parse tree `cfg` borrows from is released by the caller AFTER this
    // returns, so the masked values stay alive for the serialization.
    const masked_web_search = web_search_mask.maskProviders(allocator, cfg.web_search);
    return http_response.makePabrikConfigResponse(allocator, .{
        // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
        // defaults are no longer on the wire. Profiles + operational
        // settings only.
        .profiles = cfg.profiles_models,
        .active_profile = cfg.active_profile,
        .mcp_servers = cfg.mcp_servers,
        .notify_on_complete = cfg.notify_on_complete,
        .notify_on_error = cfg.notify_on_error,
        .web_launch_enabled = cfg.web_launch_enabled,
        .chat_view = config.chatViewModeName(config.parseChatViewMode(cfg.chat_view)),
        .model_compaction_size_kb = cfg.model_compaction_size_kb,
        // Top-level compaction defaults - plan 2026-07-07-compaction-inline.
        .max_capacity_token_model = cfg.max_capacity_token_model,
        .compaction_threshold_percent = cfg.compaction_threshold_percent,
        .retry_delay_ms = cfg.retry_delay_ms,
        .tools = cfg.tools,
        .web_search = masked_web_search,
        .skill_evals = .{
            .enabled = cfg.skill_evals.enabled,
            .max_skills_per_run = cfg.skill_evals.max_skills_per_run,
            .max_evals_per_day = cfg.skill_evals.max_evals_per_day,
            .fact_lease_seconds = cfg.skill_evals.fact_lease_seconds,
            .include_listed_without_loading = cfg.skill_evals.include_listed_without_loading,
            .apply_mode = cfg.skill_evals.apply_mode,
        },
    });
}

pub const ConfigJson = struct {
    /// Configured web-search providers, keyed by provider name. Raw so the
    /// handler can mask each `key` on the way out without re-typing it.
    web_search: ?json.Value = null,
    /// Configured MCP servers (snake_case, matches PABRIK.md JSON convention).
    /// Each value is a `{"url": "...", "headers": {...}}` object.
    mcp_servers: ?json.Value = null,
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Opt-in OS notification flag (see LlmConfigJson in Config.zig).
    notify_on_complete: bool = false,
    /// Opt-in OS notification flag for the error path (see LlmConfigJson).
    /// Defaults to `false` so a missing-on-disk config is silent on errors.
    notify_on_error: bool = false,
    /// Opt-in web-launch flag (see LlmConfigJson in Config.zig).
    /// Defaults to `false` so a missing-on-disk config has web launch off.
    web_launch_enabled: bool = false,
    /// How the chat draws tool calls (see LlmConfigJson in Config.zig).
    chat_view: []const u8 = "dev",
    /// Compaction threshold in KB (see LlmConfigJson in Config.zig).
    model_compaction_size_kb: usize = 100,
    /// Optional top-level context window override (see
    /// LlmConfigJson in Config.zig). Restored in plan
    /// 2026-07-07-compaction-inline.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold (see LlmConfigJson).
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// See `LlmConfig.retry_delay_ms` for semantics.
    retry_delay_ms: u32 = 0,
    /// Default tool checklist (Tools tab, plan
    /// 2026-09-22-tools-menu-config-default-tools). Emitted as JSON
    /// `null` when the on-disk key is absent (mirrors `mcp_servers`).
    tools: ?[]const []const u8 = null,
    /// Skill Evals block, read so the Settings toggle can render the current
    /// switch.
    skill_evals: config.SkillEvalsJson = .{},
};

// ===== Tests merged from pabrik_config_get_test.zig (2026-09-11 flatten) =====
const testing = std.testing;

test "PabrikConfigResponse serializes tools: null when absent, array when set" {
    // D2 wire contract: the frontend must be able to tell "key absent"
    // (`tools: null` → legacy defaults) from an explicit `[]` (zero tools).
    const allocator = testing.allocator;

    const absent = try http_response.makePabrikConfigResponse(allocator, .{});
    defer allocator.free(absent);
    if (std.mem.indexOf(u8, absent, "\"tools\":null") == null) {
        std.debug.print("!! default PabrikConfigResponse omits tools or does not emit null !!\n", .{});
        return error.ToolsNullNotSerialized;
    }

    const names = [_][]const u8{ "command", "read_file" };
    const present = try http_response.makePabrikConfigResponse(allocator, .{ .tools = &names });
    defer allocator.free(present);
    if (std.mem.indexOf(u8, present, "\"tools\":[\"command\",\"read_file\"]") == null) {
        std.debug.print("!! PabrikConfigResponse does not serialize the tools array !!\n", .{});
        return error.ToolsArrayNotSerialized;
    }

    const empty = [_][]const u8{};
    const empty_resp = try http_response.makePabrikConfigResponse(allocator, .{ .tools = &empty });
    defer allocator.free(empty_resp);
    if (std.mem.indexOf(u8, empty_resp, "\"tools\":[]") == null) {
        std.debug.print("!! explicit [] does not serialize as an empty array !!\n", .{});
        return error.ToolsEmptyNotSerialized;
    }
}

// ─── web_search masking guard ──────────────────────────────────────────────

test "GET /api/config/pabrik never ships a web_search key in cleartext" {
    // `GET /api/config/pabrik` builds its response through TWO allowlist
    // sites: one for `--auth` mode (users.config_json) and one for file mode.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const secret = "SENTINEL_SECRET_DO_NOT_LEAK";

    const config_text =
        \\{"web_search":{"brave":{"url":"https://api.search.brave.com",
        \\ "key":"SENTINEL_SECRET_DO_NOT_LEAK",
        \\ "curl":"https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H \"X-Subscription-Token: {key}\""}}}
    ;
    const cfg = try std.json.parseFromSliceLeaky(ConfigJson, allocator, config_text, .{
        .ignore_unknown_fields = true,
    });

    // Positive control: the parsed config really does hold the secret,
    // and serializing it verbatim WOULD leak it.
    const un_masked = try http_response.makePabrikConfigResponse(allocator, .{ .web_search = cfg.web_search });
    try testing.expect(std.mem.indexOf(u8, un_masked, secret) != null);

    // What the handler actually emits: mask first, then serialize.
    const masked_web_search = web_search_mask.maskProviders(allocator, cfg.web_search);
    try testing.expect(masked_web_search != null);
    const wire = try http_response.makePabrikConfigResponse(allocator, .{ .web_search = masked_web_search });
    try testing.expect(std.mem.indexOf(u8, wire, secret) == null);

    // The provider block still ships — masking must redact the key, not
    // drop the whole section the Settings UI renders.
    try testing.expect(std.mem.indexOf(u8, wire, "\"web_search\":{") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"url\":\"https://api.search.brave.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"key\":") != null);
}
