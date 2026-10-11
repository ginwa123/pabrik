const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const config = pabrikcore.config;
const user_config_store = pabrikcore.user_config_store;
const web_search_mask = @import("web_search_mask.zig");
const parse_thinking_mod = pabrikcore.parse_thinking;
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const LlmConfig = config.LlmConfig;

/// Parse the PUT body into a `ConfigInput`.
///
/// Public so the test file can exercise the same parse path the HTTP
/// handler uses — important because the handler's wire format has
/// evolved (array-of-changes → object-map-and-array, see
/// plan 2026-07-07) and tests are the only way to lock in the
/// parser's tolerance of the on-disk shape that `PabrikSettings.vue`
/// actually sends.
pub fn parseConfigInput(
    allocator: std.mem.Allocator,
    body: []const u8,
) !ConfigInput {
    return std.json.parseFromSliceLeaky(ConfigInput, allocator, body, .{
        .ignore_unknown_fields = true,
    });
}

/// PUT /api/config/pabrik - Save pabrik.json configuration
pub fn pabrikConfigPutHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    // Auth mode: resolve the session user up front. The existing-config
    // source below loads from users.config_json and the save below
    // writes back there; config.json is never read or written.
    var auth_user_id: ?[]const u8 = null;
    var auth_sess: ?auth_common.SessionLookup = null;
    defer if (auth_sess) |s| auth_common.freeSessionLookup(allocator, s);
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
        auth_sess = sess;
        auth_user_id = sess.user_id;
    }
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    // Cast const away since getDefaultConfigDir doesn't actually modify environment
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

    // Get the default config path
    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("Failed to get config dir: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config directory" }),
        });
    };

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("Failed to build config path: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build config path" }),
        });
    };

    // Create config directory if it doesn't exist
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("Failed to create config dir: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create config directory" }),
        });
    };

    // Read request body
    const body = req.body;

    // Parse input — delegate to the shared pub helper so the test
    // file can exercise the same parse path with the user's exact
    // body shape. The helper returns a tagged-union error set so
    // the test can assert the specific failure mode (e.g. JSON
    // syntax error vs wire-format mismatch) without coupling to the
    // HTTP response shape.
    const input = parseConfigInput(allocator, body) catch |err| {
        std.log.err("Failed to parse input: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON input" }),
        });
    };

    // Read existing config if it exists (file mode) or from
    // users.config_json (auth mode). The merge logic below is
    // source-agnostic.
    var existing_content: ?[]u8 = null;

    if (auth_user_id) |uid| {
        existing_content = user_config_store.loadRaw(allocator, di.db, uid) catch |err| {
            std.log.err("Failed to load user config: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to load user config" }),
            });
        };
    } else {
        const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch null;
        if (file) |f| {
            defer f.close(io);
            var read_buffer: [4096]u8 = undefined;
            var reader = f.reader(io, &read_buffer);
            existing_content = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        }
    }

    // Build new config
    var config_json: ConfigJson = ConfigJson{};
    if (existing_content) |content| {
        const parsed = try std.json.parseFromSliceLeaky(ConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        });
        config_json = parsed;
    }

    // Update with new values.
    //
    // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
    // defaults (api_key / model / base_url / url_style / max_tokens /
    // system_prompt) are NO LONGER persisted. The write struct below
    // doesn't declare them, so Stringify.valueAlloc never re-emits them
    // to disk. Bodies that still send them (old frontends, curl scripts)
    // are tolerated via `ignore_unknown_fields` and silently dropped.
    if (input.notify_on_complete) |n| {
        config_json.notify_on_complete = n;
    }
    // notify_on_error: parallel to notify_on_complete, gated on the
    // error path of the workflow (transport failure, TooManyRetries,
    // outer catch). Absent = preserve existing on-disk value.
    if (input.notify_on_error) |n| {
        config_json.notify_on_error = n;
    }
    // web_launch_enabled: parallel to notify_on_complete. Absent =
    // preserve existing on-disk value.
    if (input.web_launch_enabled) |n| {
        config_json.web_launch_enabled = n;
    }
    if (input.model_compaction_size_kb) |kb| {
        config_json.model_compaction_size_kb = kb;
    }
    // Top-level compaction defaults — restored in plan
    // 2026-07-07-compaction-inline. `null` is a legitimate value (the
    // cascade wildcard); clients opt out of the top-level override by
    // sending null.
    if (input.max_capacity_token_model) |mc| {
        config_json.max_capacity_token_model = mc;
    }
    if (input.compaction_threshold_percent) |tp| {
        if (tp > 100) return error.InvalidThresholdPercent;
        config_json.compaction_threshold_percent = tp;
    }
    // retry_delay_ms: clamp to [0, 60_000]. Values > 60_000 would let a
    // user lock themselves out of cancelable recovery (one cancellation
    // attempt would have to wait the full delay). Values < 0 are
    // impossible at the type level (u32). `null` means "no change" so
    // an omit-from-PUT doesn't reset the existing value.
    if (input.retry_delay_ms) |ms| {
        config_json.retry_delay_ms = if (ms > 60_000) 60_000 else ms;
    }
    // Handle the `tools` default checklist (plan
    // 2026-09-22-tools-menu-config-default-tools, D2). Absent key AND
    // explicit JSON `null` both parse to `null` (the desired collapse) →
    // no change, so a Settings save from another tab never erases the
    // on-disk list. A present array — including `[]` — replaces the
    // whole list, but only after every name is checked against
    // `UNIFIED_TOOL_REGISTRY` (the load path stays tolerant of
    // hand-edited names; PUT is the validation gate).
    // Web-search providers are validated HERE, at save time, rather than
    // being tolerated at load time. Without this,
    // `parseWebSearchProviderEntry` would `warn` and DROP a bad entry, and
    // the symptom would be "Settings shows a provider, the agent says none
    // are configured" — the exact indistinguishable-failure class this
    // repo keeps fighting. A 400 naming the offending provider is the
    // difference between a five-second fix and a bug report.
    if (try applyWebSearchInput(allocator, &config_json, input.web_search)) |bad| {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = bad.message }),
        });
    }

    if (try applyToolsInput(allocator, &config_json, input.tools)) |bad| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "InvalidToolName: '{s}' is not in the unified tool registry",
            .{bad},
        );
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }),
        });
    }

    // Skill Evals. `null` (absent key, or explicit JSON null — both parse
    // to `null`) means "no change", so the on-disk block parsed into
    // `config_json` above survives a save from any Settings tab that does
    // not render the Evals section. A present object replaces it wholesale,
    // duping `apply_mode` because the parsed input slice dies with this
    // function's scope.
    if (input.skill_evals) |se| {
        config_json.skill_evals = .{
            .enabled = se.enabled,
            .max_skills_per_run = se.max_skills_per_run,
            .max_evals_per_day = se.max_evals_per_day,
            .fact_lease_seconds = se.fact_lease_seconds,
            .include_listed_without_loading = se.include_listed_without_loading,
            .apply_mode = if (se.apply_mode) |am| try allocator.dupe(u8, am) else null,
        };
    }

    // Handle profiles - accept BOTH the on-disk shape (object map) and the
    // granular change-list shape (array of ProfileChange). The frontend's
    // main settings panel sends the on-disk shape (Record<name, profile>);
    // the sub-agent add/edit/delete UIs send the array shape. Plan
    // 2026-07-07 inline-compaction + PUT 400 bug fix: previously the
    // handler only accepted the array shape, causing the main settings
    // save to 400 with "Invalid JSON input" because parseFromSliceLeaky
    // rejected the on-disk object map.
    if (input.profiles) |profiles_value| {
        // Create new profiles object
        var profiles_obj = try json.ObjectMap.init(allocator, &.{}, &.{});

        // Copy existing profiles first (deep copy to avoid freed memory from parsed deinit)
        if (config_json.profiles_models) |existing| {
            var iter = existing.object.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                // Deep copy the value to avoid freed memory
                const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                try profiles_obj.put(allocator, key, copied_value);
            }
        }

        switch (profiles_value) {
            // Granular change-list shape: array of ProfileChange entries.
            .array => |arr| {
                for (arr.items) |item| {
                    // Re-serialize the item to JSON text first: `item`
                    // is an already-parsed `json.Value`, and parsing
                    // its raw struct bytes (the old `asBytes` trick)
                    // is a guaranteed SyntaxError → 500. The
                    // stringify round-trip is the correct bridge into
                    // the typed `ProfileChange` struct.
                    const item_str = try std.json.Stringify.valueAlloc(allocator, item, .{});
                    defer allocator.free(item_str);
                    const profile_change = try json.parseFromSliceLeaky(
                        ProfileChange,
                        allocator,
                        item_str,
                        .{ .ignore_unknown_fields = true },
                    );
                    const action = profile_change.action;
                    if (action.len > 0) {
                        if (std.mem.eql(u8, action, "delete")) {
                            _ = profiles_obj.swapRemove(profile_change.name);
                        } else if (std.mem.eql(u8, action, "add") or std.mem.eql(u8, action, "update")) {
                            var profile_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                            try profile_obj.put(allocator, "model", if (profile_change.model.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.model) } else json.Value{ .string = "" });
                            try profile_obj.put(allocator, "base_url", if (profile_change.base_url.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.base_url) } else json.Value{ .string = "" });
                            try profile_obj.put(allocator, "thinking", json.Value{ .string = try allocator.dupe(u8, profile_change.thinking) });
                            try profile_obj.put(allocator, "temperature", json.Value{ .string = try allocator.dupe(u8, profile_change.temperature) });
                            try profile_obj.put(allocator, "url_style", json.Value{ .string = try allocator.dupe(u8, profile_change.url_style) });
                            try profile_obj.put(allocator, "api_key", if (profile_change.api_key.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.api_key) } else json.Value{ .string = "" });
                            // Per-profile compaction overrides (Chunk 7). When
                            // the input omits them, we omit the JSON key so an
                            // "update" doesn't clobber the existing on-disk
                            // value. When present, validate the threshold range.
                            if (profile_change.max_capacity_tokens) |mct| {
                                try profile_obj.put(allocator, "max_capacity_tokens", json.Value{ .integer = mct });
                            }
                            if (profile_change.compaction_threshold_percent) |tp| {
                                if (tp > 100) return error.InvalidThresholdPercent;
                                try profile_obj.put(allocator, "compaction_threshold_percent", json.Value{ .integer = tp });
                            }
                            // === Model-thinking knobs (plan 2026-08-23-model-thinking) ===
                            // Validate inline (NOT at JSON-parse time) so a
                            // single error path serves both the granular
                            // change-list shape (this branch) and the
                            // on-disk object-map shape (validated via
                            // validateModelThinkingOnDiskProfileMap
                            // below). We return early with a 400 + a
                            // structured body so the caller sees a
                            // descriptive message (the gserverz error
                            // path returns a generic "Handler error" 500).
                            if (profile_change.thinking_budget_tokens) |t| {
                                if (t == 0 or t > 2_000_000) {
                                    return res.jsonResponse(.{
                                        .status_code = 400,
                                        .data = try http_response.makeErrorResponse(
                                            allocator,
                                            .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                                        ),
                                    });
                                }
                                try profile_obj.put(allocator, "thinking_budget_tokens", json.Value{ .integer = t });
                            }
                            if (profile_change.reasoning_effort) |re| {
                                _ = parse_thinking_mod.parseReasoningEffort(re) catch {
                                    return res.jsonResponse(.{
                                        .status_code = 400,
                                        .data = try http_response.makeErrorResponse(
                                            allocator,
                                            .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                                        ),
                                    });
                                };
                                try profile_obj.put(allocator, "reasoning_effort", json.Value{ .string = try allocator.dupe(u8, re) });
                            }
                            // === Per-profile sub_agents (plan 2026-09-04-subagents-per-profile) ===
                            // When the change provides a list, validate +
                            // serialize it onto the profile object. When
                            // omitted on "update", preserve the existing
                            // on-disk list so a profile edit doesn't wipe
                            // the profile's subagents.
                            if (profile_change.sub_agents) |sas| {
                                for (sas) |sa| {
                                    if (sa.thinking_budget_tokens) |t| {
                                        if (t == 0 or t > 2_000_000) {
                                            return res.jsonResponse(.{
                                                .status_code = 400,
                                                .data = try http_response.makeErrorResponse(
                                                    allocator,
                                                    .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                                                ),
                                            });
                                        }
                                    }
                                    if (sa.reasoning_effort) |re| {
                                        _ = parse_thinking_mod.parseReasoningEffort(re) catch {
                                            return res.jsonResponse(.{
                                                .status_code = 400,
                                                .data = try http_response.makeErrorResponse(
                                                    allocator,
                                                    .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                                                ),
                                            });
                                        };
                                    }
                                    if (sa.compaction_threshold_percent) |tp| {
                                        if (tp > 100) return error.InvalidThresholdPercent;
                                    }
                                }
                                try profile_obj.put(allocator, "sub_agents", try subAgentsJsonToValue(allocator, sas));
                            } else if (std.mem.eql(u8, action, "update")) {
                                if (profiles_obj.get(profile_change.name)) |existing| {
                                    if (existing == .object) {
                                        if (existing.object.get("sub_agents")) |sas_value| {
                                            try profile_obj.put(allocator, "sub_agents", try deepCopyJsonValue(allocator, sas_value));
                                        }
                                    }
                                }
                            }
                            const profile_value_obj = json.Value{ .object = profile_obj };
                            try profiles_obj.put(allocator, try allocator.dupe(u8, profile_change.name), profile_value_obj);
                        }
                    }
                }
            },
            // On-disk shape: object map. Each entry is the full profile
            // metadata for a single profile. Deep-copy each entry so
            // the borrowed slice from the parsed request stays valid
            // across the `parsed.deinit()` at scope exit.
            .object => |obj| {
                // Validate model-thinking fields before copying. The
                // validation must reject bad values BEFORE we write
                // anything to disk. Plan 2026-08-23-model-thinking.
                // We translate the error variant into a 400 + a
                // structured body inline so the caller sees a
                // descriptive message (the gserverz error path returns
                // a generic "Handler error" 500).
                validateModelThinkingOnDiskProfileMap(obj) catch |err| switch (err) {
                    error.InvalidThinkingBudgetTokens => {
                        return res.jsonResponse(.{
                            .status_code = 400,
                            .data = try http_response.makeErrorResponse(
                                allocator,
                                .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                            ),
                        });
                    },
                    error.InvalidReasoningEffort => {
                        return res.jsonResponse(.{
                            .status_code = 400,
                            .data = try http_response.makeErrorResponse(
                                allocator,
                                .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                            ),
                        });
                    },
                };

                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                    try profiles_obj.put(allocator, key, copied_value);
                }
            },
            else => return error.InvalidJson,
        }

        config_json.profiles_models = json.Value{ .object = profiles_obj };
    }

    // Handle active profile
    if (input.active_profile) |ap| {
        if (ap.len > 0) {
            config_json.active_profile = try allocator.dupe(u8, ap);
        } else {
            config_json.active_profile = null;
        }
    }

    // Handle MCP servers: if the input provides an `mcp_servers` map, replace
    // the existing list wholesale (whole-list replace matches the UI's
    // add/edit/delete workflow). The input map is deep-copied so the parsed
    // struct can safely go out of scope.
    if (input.mcp_servers) |servers_value| {
        switch (servers_value) {
            .object => |obj| {
                var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer new_obj.deinit(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                    try new_obj.put(allocator, key, copied_value);
                }
                config_json.mcp_servers = json.Value{ .object = new_obj };
            },
            else => {
                // Non-object value: silently drop (e.g. user sent `null`).
                config_json.mcp_servers = null;
            },
        }
    }

    // Handle top-level sub_agents (DEPRECATED — plan
    // 2026-09-04-subagents-per-profile: subagents are per-profile now).
    // Kept as a compat write path: old clients may still send it, and
    // the next load migrates it into profiles with empty lists. New
    // clients must use per-profile `sub_agents` via `ProfileChange`.
    // If the input provides a `sub_agents`
    // array, replace the existing list wholesale (whole-list replace matches
    // the UI's add/edit/delete workflow). Each entry's 8 string fields are
    // duped onto the allocator so the new array is independent of the
    // parsed input slice (which goes out of scope after this function).
    if (input.sub_agents) |sas| {
        // === Model-thinking validation (plan 2026-08-23-model-thinking) ===
        // Validate each sub-agent's `thinking_budget_tokens` and
        // `reasoning_effort` BEFORE any dup'ing so a bad value is
        // rejected at the HTTP layer rather than silently written
        // to disk. Translate the error into a 400 + structured body
        // inline so the caller sees a descriptive message.
        for (sas) |sa| {
            if (sa.thinking_budget_tokens) |t| {
                if (t == 0 or t > 2_000_000) {
                    return res.jsonResponse(.{
                        .status_code = 400,
                        .data = try http_response.makeErrorResponse(
                            allocator,
                            .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                        ),
                    });
                }
            }
            if (sa.reasoning_effort) |re| {
                _ = parse_thinking_mod.parseReasoningEffort(re) catch {
                    return res.jsonResponse(.{
                        .status_code = 400,
                        .data = try http_response.makeErrorResponse(
                            allocator,
                            .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                        ),
                    });
                };
            }
        }
        const owned = try allocator.alloc(LlmConfig.SubAgentJson, sas.len);
        errdefer allocator.free(owned);
        for (sas, 0..) |sa, i| {
            owned[i] = .{
                .name = try allocator.dupe(u8, sa.name),
                .model = try allocator.dupe(u8, sa.model),
                .base_url = try allocator.dupe(u8, sa.base_url),
                .thinking = try allocator.dupe(u8, sa.thinking),
                .temperature = try allocator.dupe(u8, sa.temperature),
                .url_style = try allocator.dupe(u8, sa.url_style),
                .api_key = try allocator.dupe(u8, sa.api_key),
                .system_prompt = try allocator.dupe(u8, sa.system_prompt),
                // Model-thinking knobs (plan 2026-08-23-model-thinking).
                // Already range-validated above; thread through as-is.
                .thinking_budget_tokens = sa.thinking_budget_tokens,
                .reasoning_effort = if (sa.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
            };
        }
        config_json.sub_agents = owned;
    }

    // Plan 2026-09-04-subagents-per-profile: disk-side migration.
    // Fold any deprecated top-level `sub_agents` into profiles that
    // lack their own list, then strip the key so the file on disk
    // is per-profile-only after this save.
    try migrateTopLevelSubAgentsOnDisk(allocator, &config_json);

    // Write config
    const config_str = try std.json.Stringify.valueAlloc(allocator, config_json, .{
        .whitespace = .indent_tab,
    });

    // Auth mode: persist to users.config_json and return early.
    // config.json is untouched and the global singleton is NOT swapped
    // (config is per-user). Still invalidate the MCP tools cache so the
    // next workflow run refetches.
    if (auth_user_id) |uid| {
        user_config_store.saveRaw(allocator, di.db, uid, config_str) catch |err| {
            std.log.err("Failed to save user config: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to save user config" }),
            });
        };
        di.clearMcpToolsCache();
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved successfully" }),
        });
    }

    var write_file = try std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    });
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    try writer.interface.writeAll(config_str);
    try writer.flush();

    // === Live-reload App.llm_config ===
    // Reload from disk so the running workflow picks up the new API key,
    // model, base_url, mcp_servers, and profiles without a server restart.
    // On any failure we still respond 200 (disk is already authoritative)
    // but log the error and skip the swap so the running config is stable.
    {
        const env_for_reload: *std.process.Environ.Map = @ptrCast(@constCast(di.environment orelse environment));

        var new_cfg = config.LlmConfig.init(di.allocator, io, null, env_for_reload) catch |err| {
            std.log.err("PUT /api/config/pabrik: live reload parse failed: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved to disk but live reload parse failed" }),
            });
        };

        new_cfg.validate() catch |err| {
            std.log.err("PUT /api/config/pabrik: live reload validation failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved to disk but failed validation" }),
            });
        };

        const new_ptr = di.allocator.create(config.LlmConfig) catch |err| {
            std.log.err("PUT /api/config/pabrik: alloc failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        new_ptr.* = new_cfg;

        // Atomically swap. Previous-pointer free happens inside setLlmConfig.
        pabrikcore.setLlmConfig(di, new_ptr);
        std.log.info("PUT /api/config/pabrik: live-reloaded llm_config (model={s}, base_url={s})", .{ new_ptr.model, new_ptr.base_url });

        // Fetch-once cache (plan: mcp-fetch-once-cache): lazy-invalidate
        // so the next workflow run refetches once. Also force registry
        // clients to rebuild on next fetch — otherwise an edited URL /
        // command with the same server name would keep serving the old
        // cached client (HTTP has no self-healing; stdio only heals on
        // error). Config saves are rare; one reconnect per save is fine.
        di.clearMcpToolsCache();
        if (new_ptr.mcpServers()) |servers_val| {
            if (servers_val == .object) {
                var it = servers_val.object.iterator();
                while (it.next()) |entry| {
                    pabrikcore.mcpStdioRegistry(di.allocator).markStale(entry.key_ptr.*);
                    if (di.mcp_http_registry) |hreg| hreg.evict(entry.key_ptr.*);
                }
            }
        }
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved successfully" }),
    });
}

/// Wire format for the PUT body. Public so the test file
/// (`pabrik_config_put.zig`) can re-parse the same body the
/// HTTP handler would parse and assert the wire format matches the
/// frontend's actual `PabrikSettings.vue` shape.
pub const ConfigInput = struct {
    // Plan 2026-08-24-config-simplify-remove-defaults: the old
    // api_endpoint/api_key/model/url_style/max_tokens/system_prompt
    // fields were REMOVED. Bodies that still send them are tolerated
    // via `ignore_unknown_fields` (silently dropped — the top-level
    // defaults are no longer persisted to config.json).
    temperature: f64 = 0.7,
    profiles: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Whole-list replace for the `mcp_servers` map (snake_case).
    /// When present, replaces the existing MCP servers entirely.
    /// When absent, existing MCP servers are preserved.
    mcp_servers: ?json.Value = null,
    /// When true, fire an OS-level notification when an LLM response
    /// finishes with `finish_reason == "stop"`. Absent = preserve
    /// existing on-disk value. Mirrors the `LlmConfigJson` default
    /// (`false`) so a brand-new config has notifications off.
    notify_on_complete: ?bool = null,
    /// When true, fire an OS-level notification when the LLM workflow
    /// hits an error (transport failure, TooManyRetries, outer catch).
    /// Absent = preserve existing on-disk value. Mirrors the
    /// `LlmConfigJson` default (`false`) so a brand-new config has
    /// error notifications off.
    notify_on_error: ?bool = null,
    /// When true, the agent may launch URLs in the user's web browser.
    /// Absent = preserve existing on-disk value. Mirrors the
    /// `LlmConfigJson` default (`false`).
    web_launch_enabled: ?bool = null,
    /// Threshold (in KB) above which the session compactor is invoked
    /// to shrink the LLM context. Absent = preserve existing on-disk
    /// value. Mirrors the `LlmConfigJson` default (`100`).
    model_compaction_size_kb: ?usize = null,
    /// Optional top-level override for the context window (in tokens).
    /// Restored in plan 2026-07-07-compaction-inline. `null` = fall
    /// through to per-profile override, then built-in default. Per-profile
    /// overrides (`ProfileChange.max_capacity_tokens`) coexist independently.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold percentage (0-100).
    /// Restored in plan 2026-07-07-compaction-inline. `null` = fall
    /// through to per-profile override, then built-in 80. Values > 100
    /// are rejected with `error.InvalidThresholdPercent`.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// Range-validated at apply time: 0 ≤ value ≤ 60_000. `null` means
    /// "no change" so an omit-from-PUT doesn't reset the existing
    /// value. Matches `LlmConfig.retry_delay_ms` (Config.zig) and the
    /// GET handler's `ConfigJson` shape.
    retry_delay_ms: ?u32 = null,
    // Note: per-profile compaction overrides (max_capacity_tokens,
    // compaction_threshold_percent) live on `ProfileChange` below.
    // Both layers coexist: top-level for Defaults tab, per-profile for
    // profile-specific overrides.
    /// Whole-list replace for the top-level `sub_agents` array.
    /// When present, replaces the existing sub-agents entirely.
    /// When absent, existing sub-agents are preserved. Borrowed slices
    /// from the request body — the handler dupes each entry's strings
    /// before assigning to `config_json.sub_agents`.
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
    /// Whole-list replace for the `tools` default checklist (plan
    /// 2026-09-22-tools-menu-config-default-tools, D2). Absent OR
    /// explicit JSON `null` → no change (both parse to `null` — the
    /// desired collapse, so a Settings save that omits `tools` preserves
    /// the on-disk value). A present array (including `[]`) replaces the
    /// list after registry validation at apply time. Borrowed slices from
    /// the request body — the handler dupes them before writing.
    tools: ?[]const []const u8 = null,
    web_search: ?json.Value = null,
    /// Skill Evals master switch + knobs. Absent OR explicit JSON `null`
    /// → no change, so a Settings save from a tab that never rendered
    /// the Evals section preserves the on-disk block. A present object
    /// replaces it wholesale. Mirrors `config.SkillEvalsJson` — the
    /// tolerant shape, so an unrecognised `apply_mode` degrades on the
    /// next load rather than making config.json unloadable.
    skill_evals: ?config.SkillEvalsJson = null,
};

const ProfileChange = struct {
    name: []const u8,
    action: []const u8, // "add", "update", "delete"
    model: []const u8 = "",
    base_url: []const u8 = "",
    thinking: []const u8 = "auto",
    temperature: []const u8 = "auto",
    url_style: []const u8 = "openai",
    api_key: []const u8 = "",
    /// Optional override for the per-profile context window (in tokens).
    /// Mirrors `LlmProfile.max_capacity_tokens` in Config.zig. When
    /// non-null, the JSON write below sets the `max_capacity_tokens`
    /// key on the profile object. When null, the key is omitted
    /// (preserves existing on-disk value if the action is "update").
    max_capacity_tokens: ?u32 = null,
    /// Optional per-profile compaction threshold percentage (0-100).
    /// Mirrors `LlmProfile.compaction_threshold_percent`. Values > 100
    /// are rejected with `error.InvalidThresholdPercent` at the apply
    /// block above (per-profile validation is layered on top of the
    /// top-level model_compaction_size_kb check).
    compaction_threshold_percent: ?u8 = null,
    /// Anthropic-only override for `thinking.budget_tokens`. Plan
    /// 2026-08-23-model-thinking. Must be in (0, 2_000_000] when
    /// present — values outside that range are rejected with
    /// `error.InvalidThinkingBudgetTokens`.
    thinking_budget_tokens: ?u32 = null,
    /// OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1).
    /// One of "low" | "medium" | "high" | "auto". Invalid values
    /// are rejected with `error.InvalidReasoningEffort` via the
    /// parse_thinking helper (so the validation logic lives in
    /// exactly one place — see parse_thinking.zig).
    reasoning_effort: ?[]const u8 = null,
    /// Per-profile sub-agents (plan 2026-09-04-subagents-per-profile).
    /// Each profile owns its list — there is no global list anymore.
    /// When non-null on add/update, replaces the profile's list
    /// wholesale. When null on update, the existing on-disk list is
    /// preserved (same omit-doesn't-clobber rule as
    /// `max_capacity_tokens` above).
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
};

const ConfigJson = struct {
    // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
    // defaults (api_key/model/base_url/url_style/max_tokens/system_prompt)
    // were REMOVED from the on-disk shape. This struct is the serializer
    // for `Stringify.valueAlloc` — fields absent here are never written
    // to config.json.
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Configured MCP servers (snake_case, matches PABRIK.md JSON convention).
    mcp_servers: ?json.Value = null,
    /// Opt-in OS notification flag. Default `false` matches
    /// `LlmConfigJson` (Config.zig:96); a brand-new config has
    /// notifications off.
    notify_on_complete: bool = false,
    /// Opt-in OS notification flag for the error path. Default `false`
    /// matches `LlmConfigJson` (Config.zig); a brand-new config has
    /// error notifications off.
    notify_on_error: bool = false,
    /// Opt-in web-launch flag. Default `false` matches `LlmConfigJson`
    /// (Config.zig); a brand-new config has web launch off.
    web_launch_enabled: bool = false,
    /// Compaction threshold in KB. Default `100` matches
    /// `LlmConfigJson` (Config.zig:92).
    model_compaction_size_kb: usize = 100,
    /// Top-level context window override. Restored in plan
    /// 2026-07-07-compaction-inline. `null` is the cascade wildcard
    /// (falls through to per-profile override, then built-in).
    max_capacity_token_model: ?u32 = null,
    /// Top-level compaction threshold. Restored in plan
    /// 2026-07-07-compaction-inline. `null` is the cascade wildcard.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// Mirrors `LlmConfig.retry_delay_ms` (Config.zig). Clamped to
    /// [0, 60_000] by the apply block. Default 0 = no delay.
    retry_delay_ms: u32 = 0,
    /// Top-level sub-agents array (snake_case, matches PABRIK.md JSON
    /// convention). Parsed into the typed `LlmConfig.SubAgentJson` shape
    /// (borrowed from the parsed file content), or replaced by an
    /// owned copy (duped from the request body) when the input provides
    /// a new list.
    sub_agents: ?[]LlmConfig.SubAgentJson = null,
    /// Default tool checklist (Tools tab, plan
    /// 2026-09-22-tools-menu-config-default-tools). Parsed from the
    /// on-disk file so an input that omits `tools` round-trips the
    /// existing value instead of erasing it; replaced wholesale by an
    /// owned copy when the input provides a new list. `null` emits JSON
    /// `null`, which every reader treats as "key absent".
    tools: ?[]const []const u8 = null,
    /// Web-search providers, keyed by name. Parsed from the on-disk document
    /// so an input that omits `web_search` round-trips the existing value
    /// instead of erasing it; replaced wholesale when the input provides a
    /// new map. Same contract as `tools` directly above.
    web_search: ?json.Value = null,
    /// Skill Evals block. NON-OPTIONAL so it is always re-emitted: a
    /// `?… = null` here would serialize to JSON `null`, which the
    /// runtime parser rejects for this struct and which would erase a
    /// user's opt-in on every save. Absent on disk → the field defaults
    /// (`enabled = false`), which is the same value the runtime would
    /// have used anyway, so materializing it changes no behaviour.
    skill_evals: config.SkillEvalsJson = .{},
};

/// Apply the optional `tools` input onto the on-disk write struct.
/// Returns the first unknown name (the caller turns it into a 400)
/// WITHOUT touching `config_json`. A `null` input — absent key or
/// explicit JSON `null`, which std.json collapses to the same thing —
/// leaves the on-disk list untouched, so a Settings save from another
/// tab never erases the checklist. A present list (including `[]`)
/// replaces it wholesale with owned copies (validated first, so a
/// rejected name can never half-apply).
/// A rejected provider: which one, and why.
const WebSearchRejection = struct {
    provider: []const u8,
    reason: []const u8,
    message: []const u8, // owned
    allocator: std.mem.Allocator,
};

/// Validate and store `web_search`. Returns a rejection the caller turns
/// into a 400, or null on success / when the field is absent.
///
/// An entry with a blank `key` has the field REMOVED rather than stored as
/// `""`: `SqliteBackend.exec` binds an empty slice as SQL NULL, and `""` is
/// exactly the shape that survives a JSON round-trip while meaning "unset".
/// A masked key (`sk…7f2`) is also removed here — it means "unchanged", and
/// the stored secret is restored from the existing document further down.
fn applyWebSearchInput(
    allocator: std.mem.Allocator,
    config_json: *ConfigJson,
    input: ?json.Value,
) !?WebSearchRejection {
    const body = input orelse return null;
    if (body != .object) {
        const message = try std.fmt.allocPrint(allocator, "web_search must be an object", .{});
        return .{ .provider = "", .reason = "", .message = message, .allocator = allocator };
    }

    var out = try json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer out.deinit(allocator);

    var it = body.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const reason = web_search_mask.validateProvider(name, entry.value_ptr.*) catch |e| blk: {
            const r = switch (e) {
                error.BadProviderName => "has no usable name",
                error.BadPinnedUrl => "`url` must be https and must not be loopback, private or link-local",
                error.MissingCurl => "`curl` is required and must not be empty",
                error.MissingKeyPlaceholder => "has a key configured but its curl has no {key} — put {key} where the credential belongs",
                error.UnexpectedKeyPlaceholder => "has no key configured but its curl contains {key}",
                error.UnparseableCurl => "has a curl this tool cannot parse as a GET request",
            };
            break :blk r;
        };
        if (reason) |r| {
            const message = try std.fmt.allocPrint(
                allocator,
                "web_search provider '{s}': {s}",
                .{ name, r },
            );
            return .{ .provider = name, .reason = r, .message = message, .allocator = allocator };
        }

        var clean = try json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer clean.deinit(allocator);
        var inner = entry.value_ptr.object.iterator();
        while (inner.next()) |f| {
            // Drop an empty or masked credential; never store `""`. The
            // stored secret is grafted back below.
            if (std.mem.eql(u8, f.key_ptr.*, "key")) {
                const k = switch (f.value_ptr.*) {
                    .string => |v| v,
                    else => {
                        try clean.put(allocator, f.key_ptr.*, f.value_ptr.*);
                        continue;
                    },
                };
                if (k.len == 0 or web_search_mask.isMaskFor(k)) continue;
            }
            try clean.put(allocator, f.key_ptr.*, f.value_ptr.*);
        }
        // Graft the stored key back when the incoming one was the mask.
        // `config_json.web_search` still holds the ON-DISK document at this
        // point — it is only overwritten at the end.
        if (clean.get("key") == null) {
            if (config_json.web_search) |prev| {
                if (prev == .object) {
                    if (prev.object.get(name)) |before| {
                        if (before == .object) {
                            if (before.object.get("key")) |k| try clean.put(allocator, "key", k);
                        }
                    }
                }
            }
        }
        try out.put(allocator, name, .{ .object = clean });
    }
    config_json.web_search = .{ .object = out };
    return null;
}

fn applyToolsInput(
    allocator: std.mem.Allocator,
    config_json: *ConfigJson,
    tools: ?[]const []const u8,
) !?[]const u8 {
    const tool_names = tools orelse return null;
    if (firstUnknownToolName(tool_names)) |bad| return bad;

    const owned = try allocator.alloc([]const u8, tool_names.len);
    errdefer allocator.free(owned);
    for (tool_names, 0..) |name, i| {
        owned[i] = try allocator.dupe(u8, name);
    }
    config_json.tools = owned;
    return null;
}

/// First name in `names` that is absent from `UNIFIED_TOOL_REGISTRY()`,
/// or `null` when every name is known. An empty list (`[]`) is a valid
/// explicit-zero checklist and returns `null` (no error).
fn firstUnknownToolName(names: []const []const u8) ?[]const u8 {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();
    for (names) |name| {
        var known = false;
        for (registry) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                known = true;
                break;
            }
        }
        if (!known) return name;
    }
    return null;
}

/// Serialize a borrowed `[]SubAgentJson` slice into an owned
/// `json.Value` array for writing onto a profile object (plan
/// 2026-09-04-subagents-per-profile). All strings are duped onto
/// the allocator so the value outlives the parsed request body.
fn subAgentsJsonToValue(allocator: std.mem.Allocator, sas: []const LlmConfig.SubAgentJson) error{OutOfMemory}!json.Value {
    var arr = json.Array.init(allocator);
    errdefer arr.deinit();
    for (sas) |sa| {
        var obj = try json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", json.Value{ .string = try allocator.dupe(u8, sa.name) });
        try obj.put(allocator, "model", json.Value{ .string = try allocator.dupe(u8, sa.model) });
        try obj.put(allocator, "base_url", json.Value{ .string = try allocator.dupe(u8, sa.base_url) });
        try obj.put(allocator, "thinking", json.Value{ .string = try allocator.dupe(u8, sa.thinking) });
        try obj.put(allocator, "temperature", json.Value{ .string = try allocator.dupe(u8, sa.temperature) });
        try obj.put(allocator, "url_style", json.Value{ .string = try allocator.dupe(u8, sa.url_style) });
        try obj.put(allocator, "api_key", json.Value{ .string = try allocator.dupe(u8, sa.api_key) });
        try obj.put(allocator, "system_prompt", json.Value{ .string = try allocator.dupe(u8, sa.system_prompt) });
        if (sa.max_capacity_tokens) |mct| {
            try obj.put(allocator, "max_capacity_tokens", json.Value{ .integer = mct });
        }
        if (sa.compaction_threshold_percent) |tp| {
            try obj.put(allocator, "compaction_threshold_percent", json.Value{ .integer = tp });
        }
        if (sa.thinking_budget_tokens) |t| {
            try obj.put(allocator, "thinking_budget_tokens", json.Value{ .integer = t });
        }
        if (sa.reasoning_effort) |re| {
            try obj.put(allocator, "reasoning_effort", json.Value{ .string = try allocator.dupe(u8, re) });
        }
        try arr.append(json.Value{ .object = obj });
    }
    return json.Value{ .array = arr };
}

/// Disk-side twin of the load migration in `Config.zig`
/// (`migrateTopLevelSubAgentsIntoEmptyProfiles`).
///
/// When the on-disk config still carries the deprecated top-level
/// `sub_agents` array, copy it into every profile object that lacks
/// a non-empty `sub_agents` array, then strip the top-level key so
/// fresh writes are per-profile-only. Profiles with their own list
/// are untouched. When there are no profiles to migrate into, the
/// top-level key is kept (nowhere to move the entries).
fn migrateTopLevelSubAgentsOnDisk(
    allocator: std.mem.Allocator,
    config_json: *ConfigJson,
) error{OutOfMemory}!void {
    const top = config_json.sub_agents orelse return;
    if (top.len == 0) {
        config_json.sub_agents = null;
        return;
    }
    const profiles_value = config_json.profiles_models orelse return;
    if (profiles_value != .object) return;

    // Serialize once, deep-copy per profile that needs it.
    const arr_value = try subAgentsJsonToValue(allocator, top);
    var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer new_obj.deinit(allocator);
    var iter = profiles_value.object.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        var copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
        if (copied_value == .object) {
            const needs = blk: {
                if (copied_value.object.get("sub_agents")) |sas| {
                    if (sas == .array and sas.array.items.len > 0) break :blk false;
                }
                break :blk true;
            };
            if (needs) {
                try copied_value.object.put(allocator, "sub_agents", try deepCopyJsonValue(allocator, arr_value));
            }
        }
        try new_obj.put(allocator, key, copied_value);
    }
    config_json.profiles_models = json.Value{ .object = new_obj };
    config_json.sub_agents = null;
}

/// Deep copy a json.Value to avoid use-after-free from parsed.deinit()
fn deepCopyJsonValue(allocator: std.mem.Allocator, value: json.Value) error{OutOfMemory}!json.Value {
    switch (value) {
        .null => return json.Value{ .null = {} },
        .bool => |b| return json.Value{ .bool = b },
        .integer => |i| return json.Value{ .integer = i },
        .float => |f| return json.Value{ .float = f },
        .number_string => |s| return json.Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return json.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try deepCopyJsonValue(allocator, item));
            }
            return json.Value{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key, copied_value);
            }
            return json.Value{ .object = new_obj };
        },
    }
}

/// Validate every profile in the on-disk object-map shape for the
/// model-thinking fields (`thinking_budget_tokens`,
/// `reasoning_effort`). The granular change-list shape (array of
/// `ProfileChange`) is validated inline at its apply block above;
/// this helper covers the on-disk shape because that path deep-
/// copies the raw `json.Value` directly to disk without parsing
/// through `ProfileChange`.
///
/// Returns `error.InvalidThinkingBudgetTokens` /
/// `error.InvalidReasoningEffort` for any bad value, mirroring the
/// change-list validation's error contract.
fn validateModelThinkingOnDiskProfileMap(obj: json.ObjectMap) !void {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const profile_value = entry.value_ptr.*;
        if (profile_value != .object) continue; // malformed entry, but the parser will catch it
        const profile_obj = profile_value.object;

        // thinking_budget_tokens: must be a positive integer in
        // (0, 2_000_000]. Type-check the raw JSON value because the
        // on-disk shape bypasses the `ProfileChange` parse struct.
        // JSON `.null` is the legitimate "no override" sentinel
        // (matches `LlmProfile.thinking_budget_tokens: ?u32 = null`
        // in Config.zig) — must be accepted, not rejected.
        if (profile_obj.get("thinking_budget_tokens")) |tbt| {
            switch (tbt) {
                .null => {},
                .integer => |i| {
                    if (i <= 0 or i > 2_000_000) return error.InvalidThinkingBudgetTokens;
                },
                else => return error.InvalidThinkingBudgetTokens,
            }
        }

        // reasoning_effort: must be one of low / medium / high / auto,
        // or `.null` for "no override" (matches
        // `LlmProfile.reasoning_effort: ?[]const u8 = null`).
        if (profile_obj.get("reasoning_effort")) |re| {
            switch (re) {
                .null => {},
                .string => |s| {
                    _ = parse_thinking_mod.parseReasoningEffort(s) catch return error.InvalidReasoningEffort;
                },
                else => return error.InvalidReasoningEffort,
            }
        }
    }
}

// ===== Tests merged from pabrik_config_put_parse_test.zig (2026-09-11 flatten) =====
// Tests for the `parseConfigInput` helper used by
// `PUT /api/config/pabrik`.
//
// These tests exercise the PARSE step of the PUT handler — the
// call into `std.json.parseFromSliceLeaky` that historically rejected
// the on-disk object-map shape and returned 400 "Invalid JSON input"
// to the user. Plan 2026-07-07 + PUT-400 bug fix: `ConfigInput.profiles`
// was changed from `?[]const ProfileChange` (array of granular
// changes) to `?json.Value` (accepts BOTH the array and the on-disk
// object map). This test locks in the new behavior so a future
// refactor can't regress it.
//
// Convention: handler internals stay scoped under
// `pabrikcore.http_handlers.*` (see `pabrik_config_profile_delete_test.zig`'s
// header comment for the rationale).

const testing = std.testing;

// ---------- Helpers ----------

/// The exact body shape the user's main settings panel sends on save.
/// Reproduces the real-world PUT body that triggered the 400 error:
///   - top-level `profiles` is a Record<name, PabrikProfile> (on-disk shape)
///   - top-level `sub_agents` is an array of SubAgentJson (with non-ASCII
///     bytes in `system_prompt` from the agent spec text — em-dash + arrow)
///   - top-level `max_capacity_token_model` + `compaction_threshold_percent`
///     are present (new top-level defaults, plan 2026-07-07)
///   - per-profile `max_capacity_tokens` + `compaction_threshold_percent`
///     are present as `null` (cascading wildcards)
///   - per-profile `sub_agents` is `[]` (empty array, not omitted)
const USER_BODY =
    \\{"api_endpoint":"https://api.minimax.io/v1","api_key":"sk-test","model":"MiniMax-M3","url_style":"openai","temperature":0,"max_tokens":"","system_prompt":"","profiles":{"profile1":{"model":"MiniMax-M2.723223233","base_url":"https://api.minimax.io/v122","thinking":"on","temperature":"0","url_style":"anthropic","api_key":"sk-cp-0","sub_agents":[],"max_capacity_tokens":null,"compaction_threshold_percent":null},"profile2":{"model":"MiniMax-M2.7","base_url":"https://api.minimax.io/v1","thinking":"auto","temperature":"auto","url_style":"openai","api_key":"sk-cp-1","sub_agents":[],"max_capacity_tokens":null,"compaction_threshold_percent":null}},"active_profile":null,"mcp_servers":null,"sub_agents":[{"name":"CodeImplementationAgent","model":"MiniMax-M3","base_url":"https://api.minimax.io/v1","thinking":"false","temperature":"auto","url_style":"openai","api_key":"sk-cp-x","system_prompt":"em-dash here: \u2014, arrow here: \u2192, fully valid UTF-8."},{"name":"DebuggingAgent","model":"MiniMax-M3","base_url":"https://api.minimax.io/v1","thinking":"true","temperature":"auto","url_style":"openai","api_key":"sk-cp-x","system_prompt":"another agent with binary-search comment out halves \u2014 fully valid UTF-8."}],"notify_on_complete":true,"model_compaction_size_kb":100,"max_capacity_token_model":500000,"compaction_threshold_percent":95}
;

// ---------- Tests ----------

test "parseConfigInput: accepts the on-disk object-map shape (user's main settings panel body)" {
    // `parseFromSliceLeaky` does allocate (slice headers for the
    // `[]SubAgentJson`, internal ObjectMap storage for `?json.Value`),
    // so we back it with an arena. Production handlers don't need
    // this because the per-request arena in GinwaServer reaps all
    // request allocations (see project memory
    // `custom-http-server-per-request-arena`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `parseConfigInput` uses `std.json.parseFromSliceLeaky` — the
    // returned struct's string slices borrow from the input body
    // (no copies made). The user must keep `USER_BODY` alive for
    // the lifetime of the parsed struct. USER_BODY is at module
    // scope, so it's alive for the whole test function.
    const input = try parseConfigInput(arena.allocator(), USER_BODY);

    // Sanity: the top-level scalars parsed.
    // Plan 2026-08-24-config-simplify-remove-defaults: the old
    // model/url_style/api_endpoint/max_tokens assertions are gone —
    // those fields no longer exist on ConfigInput (silently dropped
    // via ignore_unknown_fields).
    try testing.expectEqual(@as(?u32, 500000), input.max_capacity_token_model);
    try testing.expectEqual(@as(?u8, 95), input.compaction_threshold_percent);
    try testing.expect(input.notify_on_complete == true);
    try testing.expectEqual(@as(usize, 100), input.model_compaction_size_kb);

    // The fix: `profiles` is a json.Value object map (NOT an array).
    // Pre-fix the type was `?[]const ProfileChange` and this test would
    // fail with `error.InvalidCharacter` because the object map doesn't
    // match the array shape.
    const profiles_value = input.profiles orelse return error.ProfilesFieldMissing;
    try testing.expect(profiles_value == .object);
    try testing.expectEqual(@as(usize, 2), profiles_value.object.count());

    // The keys are the profile names from the user's body.
    var iter = profiles_value.object.iterator();
    var seen_profile1 = false;
    var seen_profile2 = false;
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "profile1")) {
            seen_profile1 = true;
            // profile1 carries the per-profile compaction overrides as
            // null (cascading wildcards) — verify they round-trip.
            const p1 = entry.value_ptr.*;
            try testing.expect(p1 == .object);
            try testing.expect(p1.object.get("max_capacity_tokens").? == .null);
            try testing.expect(p1.object.get("compaction_threshold_percent").? == .null);
        } else if (std.mem.eql(u8, entry.key_ptr.*, "profile2")) {
            seen_profile2 = true;
        } else {
            return error.UnexpectedProfileKey;
        }
    }
    try testing.expect(seen_profile1);
    try testing.expect(seen_profile2);

    // The `sub_agents` array is also present and parsed (with non-ASCII
    // bytes in the system_prompts — would have failed the parse before
    // any change if the field were missing or wrongly typed).
    const sub_agents = input.sub_agents orelse return error.SubAgentsFieldMissing;
    try testing.expectEqual(@as(usize, 2), sub_agents.len);
    try testing.expectEqualStrings("CodeImplementationAgent", sub_agents[0].name);
    try testing.expectEqualStrings("DebuggingAgent", sub_agents[1].name);
    // The em-dash and arrow survive the parse round-trip (the
    // pre-fix parse error was triggered by this exact byte sequence).
    // Em-dash is U+2014 = 0xE2 0x80 0x94 in UTF-8.
    const em_dash = "\xe2\x80\x94";
    try testing.expect(std.mem.indexOf(u8, sub_agents[0].system_prompt, em_dash) != null);
    try testing.expect(std.mem.indexOf(u8, sub_agents[1].system_prompt, em_dash) != null);
}

test "parseConfigInput: accepts the granular array-of-changes shape (regression)" {
    // Pre-fix this was the ONLY shape that worked. The fix must keep
    // it working — the sub-agent add/edit/delete UIs send this shape.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `body` stays alive for the test (constant slice — parsed slices borrow).
    const body =
        \\{"api_key":"k","model":"m","api_endpoint":"https://api.test/v1","profiles":[{"name":"alpha","action":"add","model":"m","base_url":"https://api.test/v1","thinking":"auto","temperature":"auto","url_style":"openai","api_key":"k","sub_agents":[]}]}
    ;

    const input = try parseConfigInput(arena.allocator(), body);

    const profiles_value = input.profiles orelse return error.ProfilesFieldMissing;
    try testing.expect(profiles_value == .array);
    try testing.expectEqual(@as(usize, 1), profiles_value.array.items.len);
    // The single entry is a full profile object map (the array form is
    // a "replace" semantic, not granular per-field changes).
    const entry = profiles_value.array.items[0];
    try testing.expect(entry == .object);
    try testing.expectEqualStrings("m", entry.object.get("model").?.string);
}

test "parseConfigInput: accepts a body with NO profiles field (regression)" {
    // Pre-existing on-disk files may omit `profiles` entirely. The
    // handler should treat that as "no change to profiles" — the parse
    // step must NOT require the field.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m","api_endpoint":"https://api.test/v1"}
    ;

    const input = try parseConfigInput(arena.allocator(), body);

    try testing.expect(input.profiles == null);
    try testing.expect(input.sub_agents == null);
    try testing.expect(input.mcp_servers == null);
    try testing.expect(input.max_capacity_token_model == null);
    try testing.expect(input.compaction_threshold_percent == null);
}

test "parseConfigInput: rejects malformed JSON with SyntaxError (not InvalidCharacter)" {
    const body =
        \\{"api_key":"k","model":"m",broken}
    ;

    const result = parseConfigInput(testing.allocator, body);
    try testing.expectError(error.SyntaxError, result);
}

// ─── active_profile wire contract (Reset button regression) ────────────────
//
// The Reset button previously sent `active_profile: undefined` (stripped
// to no key) which the parser + handler treated as "don't touch".
// The fix is for the frontend to send `active_profile: ""` (empty
// string) — the existing handler at pabrik_config_put.zig:246-252
// already interprets an empty string as "clear". These tests lock
// in the parser's contract for both wire states.
//
// (The empty-string sentinel is slightly less explicit than a JSON
// null, but it works within the existing `?[]const u8` type. Using
// `null` would require a type change to `?json.Value` to distinguish
// absent vs present-null in std.json — not worth the migration cost
// for one optional field.)

test "parseConfigInput: active_profile absent in body → null (don't touch)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m"}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.active_profile == null);
}

test "parseConfigInput: active_profile explicit empty string → Some(\"\") (clear sentinel)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The exact body PabrikSettings.vue::clearActiveProfile sends.
    // Empty string is the "clear" sentinel — the handler interprets
    // ap.len == 0 as "drop the active_profile field".
    const body =
        \\{"api_key":"k","model":"m","active_profile":""}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.active_profile != null);
    try testing.expectEqualStrings("", input.active_profile.?);
}

test "parseConfigInput: active_profile explicit non-empty string → Some(\"work\") (set)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The exact body PabrikSettings.vue::setActiveProfile sends.
    const body =
        \\{"api_key":"k","model":"m","active_profile":"work"}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.active_profile != null);
    try testing.expectEqualStrings("work", input.active_profile.?);
}

// ─── notify_on_error wire contract (task_1787671269086_0) ──────────────────
//
// The General settings tab in PabrikSettings.vue toggles this field
// alongside `notify_on_complete`. The wire parser must accept both
// `true` and `false` values, and must leave the field at `null` when
// omitted (so omitting on a PUT doesn't accidentally reset the
// existing on-disk value — same convention as `notify_on_complete`).
test "parseConfigInput: notify_on_error true → Some(true)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m","notify_on_error":true}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.notify_on_error != null);
    try testing.expectEqual(true, input.notify_on_error.?);
}

test "parseConfigInput: notify_on_error false → Some(false)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m","notify_on_error":false}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.notify_on_error != null);
    try testing.expectEqual(false, input.notify_on_error.?);
}

test "parseConfigInput: notify_on_error absent → null (don't touch on-disk)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m"}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expect(input.notify_on_error == null);
}

test "parseConfigInput: notify_on_complete + notify_on_error in same body parse independently" {
    // Both fields are independent booleans. A body that sends BOTH
    // must parse BOTH to the requested values. Lock the contract so a
    // future rename doesn't collapse them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m","notify_on_complete":false,"notify_on_error":true}
    ;

    const input = try parseConfigInput(arena.allocator(), body);
    try testing.expectEqual(false, input.notify_on_complete.?);
    try testing.expectEqual(true, input.notify_on_error.?);
}

// ===== Tests merged from pabrik_config_put_test.zig (2026-09-11 flatten) =====
// Tests for the live-reload `LlmConfigHolder` semantics on `App`.
//
// These tests verify the swap-and-hold pattern that keeps in-flight
// workflows (which captured the old `*const LlmConfig` into a local)
// dereferencing valid memory until the next swap or shutdown.
//
// They do NOT exercise the full HTTP handler — that requires a running
// GinwaServer. The handler-level "reload from disk" path is covered by
// manual smoke test against `pabrik-dev` (see the plan's §4).

const App = pabrikcore.App;
const LlmConfigHolder = pabrikcore.LlmConfigHolder;
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal-but-valid `LlmConfig` on the heap, owned by `allocator`.
/// Caller must `free` via `pabrikcore.freeAllLlmConfigs` (in production) or
/// the explicit `deinit`+`destroy` here (in tests).
fn makeConfig(allocator: std.mem.Allocator, model: []const u8) !*LlmConfig {
    const ptr = try allocator.create(LlmConfig);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, model),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .notify_on_complete = false,
        // Top-level compaction defaults — restored in plan
        // 2026-07-07-compaction-inline. Tests below set these to
        // non-null to verify the PUT handler applies them.
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        // Workflow retry backoff in ms (plan 2026-07-15-retry-delay,
        // Task 1.1). 0 = no delay (current behavior).
        .retry_delay_ms = 0,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
    };
    return ptr;
}

/// Build a minimal `App` carrying the given `LlmConfigHolder`.
/// Other fields are left `undefined` — the holder tests only touch
/// `llm_config_holder` and `allocator`. We must build on the heap because
/// `App` contains a `std.Io.Group` which is not copyable.
fn makeCtx(allocator: std.mem.Allocator, holder: LlmConfigHolder) !*App {
    const ctx = try allocator.create(App);
    ctx.* = .{
        .allocator = allocator,
        .io = undefined, // not used by holder helpers
        .db = undefined, // not used by holder helpers
        .llm_config_holder = holder,
        .logger = undefined, // not used by holder helpers
        .environment = null, // not used by holder helpers
        .event_bus = undefined, // not used by holder helpers
        .server = undefined, // not used by holder helpers
        .group_emit_session_create = undefined, // not used by holder helpers
    };
    return ctx;
}

// ---------------------------------------------------------------------------
// 1. Holder initial state
// ---------------------------------------------------------------------------

test "LlmConfigHolder: initial state has null previous, current is reachable" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    defer {
        cfg_a.deinit();
        allocator.destroy(cfg_a);
    }

    const holder: LlmConfigHolder = .{ .current = cfg_a };
    try testing.expectEqual(@as(?*const LlmConfig, null), holder.previous);
    try testing.expectEqualStrings("model-a", holder.current.model);
}

// ---------------------------------------------------------------------------
// 2. setLlmConfig: replaces current and moves old into previous
// ---------------------------------------------------------------------------

test "setLlmConfig: replaces current and moves old into previous" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    pabrikcore.setLlmConfig(ctx, cfg_b);

    try testing.expectEqual(cfg_b, pabrikcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);
    // Both pointers are still readable — old config has not been freed yet.
    try testing.expectEqualStrings("model-a", ctx.llm_config_holder.previous.?.model);
    try testing.expectEqualStrings("model-b", pabrikcore.getLlmConfig(ctx).model);

    // Cleanup: current=cfg_b, previous=cfg_a. freeAllLlmConfigs frees both.
    pabrikcore.freeAllLlmConfigs(ctx);
}

// ---------------------------------------------------------------------------
// 3. setLlmConfig: second swap frees the first old; the most recent old is held
// ---------------------------------------------------------------------------

test "setLlmConfig: second swap frees the first old, holds the most recent" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");
    const cfg_c = try makeConfig(allocator, "model-c");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    // Swap 1: current=cfg_b, previous=cfg_a. No free (previous slot was null).
    pabrikcore.setLlmConfig(ctx, cfg_b);
    try testing.expectEqual(cfg_b, pabrikcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);

    // Swap 2: current=cfg_c, previous=cfg_b. cfg_a is freed inside setLlmConfig
    // (it was the previous slot, promoted to "pending_previous" and freed).
    pabrikcore.setLlmConfig(ctx, cfg_c);
    try testing.expectEqual(cfg_c, pabrikcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_b, ctx.llm_config_holder.previous);

    // cfg_b is still readable (held as previous).
    try testing.expectEqualStrings("model-b", ctx.llm_config_holder.previous.?.model);
    try testing.expectEqualStrings("model-c", pabrikcore.getLlmConfig(ctx).model);

    // Cleanup: current=cfg_c, previous=cfg_b. freeAllLlmConfigs frees both.
    // (cfg_a was already freed inside the 2nd setLlmConfig.)
    pabrikcore.freeAllLlmConfigs(ctx);
}

// ---------------------------------------------------------------------------
// 4. freeAllLlmConfigs: drains both current and previous
// ---------------------------------------------------------------------------

test "freeAllLlmConfigs: drains both current and previous" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    pabrikcore.setLlmConfig(ctx, cfg_b);
    // Now: current=cfg_b, previous=cfg_a

    pabrikcore.freeAllLlmConfigs(ctx);
    // freeAllLlmConfigs sets previous to null (and current to undefined,
    // but we don't read it after).
    try testing.expectEqual(@as(?*const LlmConfig, null), ctx.llm_config_holder.previous);
}

// ---------------------------------------------------------------------------
// 5. Long sequence of swaps: only the most recent two are alive
// ---------------------------------------------------------------------------

test "setLlmConfig: long swap sequence holds only the most recent two configs" {
    const allocator = testing.allocator;

    // Each swap frees the previous-previous. We need 6 unique configs
    // (the initial `current` plus 5 new installs) so that the freed pointer
    // in each call is never reinstalled.
    const cfg_0 = try makeConfig(allocator, "model-0");
    const cfg_1 = try makeConfig(allocator, "model-1");
    const cfg_2 = try makeConfig(allocator, "model-2");
    const cfg_3 = try makeConfig(allocator, "model-3");
    const cfg_4 = try makeConfig(allocator, "model-4");
    const cfg_5 = try makeConfig(allocator, "model-5");

    const ctx = try makeCtx(allocator, .{ .current = cfg_0 });
    defer allocator.destroy(ctx);

    pabrikcore.setLlmConfig(ctx, cfg_1); // previous=cfg_0
    pabrikcore.setLlmConfig(ctx, cfg_2); // previous=cfg_1, cfg_0 freed
    pabrikcore.setLlmConfig(ctx, cfg_3); // previous=cfg_2, cfg_1 freed
    pabrikcore.setLlmConfig(ctx, cfg_4); // previous=cfg_3, cfg_2 freed
    pabrikcore.setLlmConfig(ctx, cfg_5); // previous=cfg_4, cfg_3 freed

    // Only cfg_5 and cfg_4 are alive. cfg_2 and cfg_3 were both freed.
    try testing.expectEqual(cfg_5, pabrikcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_4, ctx.llm_config_holder.previous);
    try testing.expectEqualStrings("model-5", pabrikcore.getLlmConfig(ctx).model);
    try testing.expectEqualStrings("model-4", ctx.llm_config_holder.previous.?.model);

    pabrikcore.freeAllLlmConfigs(ctx); // frees cfg_5 + cfg_4
}

// ---------------------------------------------------------------------------
// 5b. Live-reload-per-iteration semantics (plan 2026-08-06-live-config-reload)
//
// The workflow's `runAgenticMultiStepnew` reads
// `pabrikcore.getLlmConfig(di.di)` at the top of every loop iteration.
// These tests verify the holder contract that makes that work:
//   - `getLlmConfig` returns the most recently swapped pointer
//   - in-flight readers of the old pointer keep working (held in `previous`)
//   - the swap is visible WITHOUT waiting for any background task
// ---------------------------------------------------------------------------

test "live-reload: getLlmConfig returns the latest pointer immediately after setLlmConfig" {
    // This is the property that makes the per-iteration re-read in
    // `runAgenticMultiStepnew` actually pick up PabrikSettings changes.
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    // Sanity: initial config visible.
    try testing.expectEqualStrings("model-a", pabrikcore.getLlmConfig(ctx).model);

    // Swap — no synchronization, no waiting for any background task.
    pabrikcore.setLlmConfig(ctx, cfg_b);

    // Next call to getLlmConfig (i.e. the workflow's next iteration)
    // sees the new config without delay.
    try testing.expectEqualStrings("model-b", pabrikcore.getLlmConfig(ctx).model);

    // And the old config is still readable for any in-flight workflow
    // that captured it before the swap (memory safety).
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);
    try testing.expectEqualStrings("model-a", ctx.llm_config_holder.previous.?.model);

    pabrikcore.freeAllLlmConfigs(ctx);
}

test "live-reload: swapping the same model name twice returns the new pointer each time" {
    // The model string is the same in both configs (e.g. user clicked
    // "Save" without changing the value), but the holder still swaps
    // the pointer — the workflow's per-iteration `getProfile()` etc.
    // picks up any sub-field change too (e.g. updated API key).
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-same");
    const cfg_b = try makeConfig(allocator, "model-same");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    pabrikcore.setLlmConfig(ctx, cfg_b);
    try testing.expectEqual(cfg_b, pabrikcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);

    pabrikcore.freeAllLlmConfigs(ctx);
}

// ---------------------------------------------------------------------------
// 6. Public API surface
// ---------------------------------------------------------------------------

test "pabrikcore exposes LlmConfigHolder, getLlmConfig, setLlmConfig, freeAllLlmConfigs" {
    try testing.expect(@hasDecl(pabrikcore, "LlmConfigHolder"));
    try testing.expect(@hasDecl(pabrikcore, "getLlmConfig"));
    try testing.expect(@hasDecl(pabrikcore, "setLlmConfig"));
    try testing.expect(@hasDecl(pabrikcore, "freeAllLlmConfigs"));
    // `*const LlmConfig` must be a single aligned pointer (same size as
    // a usize on the target) so concurrent readers can do an atomic load
    // without a lock.
    const PtrType = *const LlmConfig;
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(PtrType));
}

// ===== tools checklist: parse + apply semantics (plan 2026-09-22-tools-menu, D2) =====
//
// The PUT body's `tools` field is the Settings Tools tab save. Contract:
//   - absent key AND explicit JSON `null` both parse to `null` → NO change
//     (a Settings save from another tab must not erase the on-disk list),
//   - a present array (including `[]`) → whole-list replace after registry
//     validation,
//   - an unknown name → the bad name is returned so the handler can 400.

test "parseConfigInput: tools absent → null (don't touch on-disk)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = try parseConfigInput(arena.allocator(), "{\"notify_on_complete\":true}");
    try testing.expect(input.tools == null);
}

test "parseConfigInput: tools explicit null → null (collapses with absent, the desired semantics)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = try parseConfigInput(arena.allocator(), "{\"tools\":null}");
    try testing.expect(input.tools == null);
}

test "parseConfigInput: tools array parses the names in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = try parseConfigInput(arena.allocator(), "{\"tools\":[\"command\",\"read_file\"]}");
    const tools = input.tools orelse return error.ToolsFieldMissing;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("command", tools[0]);
    try testing.expectEqualStrings("read_file", tools[1]);
}

test "parseConfigInput: tools empty array parses to a non-null empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = try parseConfigInput(arena.allocator(), "{\"tools\":[]}");
    const tools = input.tools orelse return error.ToolsFieldMissing;
    try testing.expectEqual(@as(usize, 0), tools.len);
}

test "applyToolsInput: null input preserves the on-disk list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const on_disk = [_][]const u8{"command"};
    var cj = ConfigJson{ .tools = &on_disk };

    const bad = try applyToolsInput(arena.allocator(), &cj, null);
    try testing.expect(bad == null);
    try testing.expect(cj.tools != null);
    try testing.expectEqual(@as(usize, 1), cj.tools.?.len);
    try testing.expectEqualStrings("command", cj.tools.?[0]);
}

test "applyToolsInput: null input with no on-disk value stays null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var cj = ConfigJson{};
    const bad = try applyToolsInput(arena.allocator(), &cj, null);
    try testing.expect(bad == null);
    try testing.expect(cj.tools == null);
}

test "applyToolsInput: present list replaces wholesale with owned copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const on_disk = [_][]const u8{ "command", "glob", "search" };
    var cj = ConfigJson{ .tools = &on_disk };

    const new_list = [_][]const u8{ "read_file", "write_file" };
    const bad = try applyToolsInput(arena.allocator(), &cj, &new_list);
    try testing.expect(bad == null);
    try testing.expectEqual(@as(usize, 2), cj.tools.?.len);
    try testing.expectEqualStrings("read_file", cj.tools.?[0]);
    try testing.expectEqualStrings("write_file", cj.tools.?[1]);
    // Owned: names were duped off the input slice.
    try testing.expect(cj.tools.?[0].ptr != new_list[0].ptr);
}

test "applyToolsInput: [] replaces with an explicit empty (non-null) list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const on_disk = [_][]const u8{"command"};
    var cj = ConfigJson{ .tools = &on_disk };

    const empty = [_][]const u8{};
    const bad = try applyToolsInput(arena.allocator(), &cj, &empty);
    try testing.expect(bad == null);
    // D2: `[]` must be distinguishable from "absent" after apply — a
    // non-null zero-length slice serializes as `[]`, not `null`.
    try testing.expect(cj.tools != null);
    try testing.expectEqual(@as(usize, 0), cj.tools.?.len);
}

test "applyToolsInput: unknown name is returned and the config is untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const on_disk = [_][]const u8{"command"};
    var cj = ConfigJson{ .tools = &on_disk };

    const new_list = [_][]const u8{ "read_file", "definitely_not_a_tool" };
    const bad = try applyToolsInput(arena.allocator(), &cj, &new_list);
    try testing.expect(bad != null);
    try testing.expectEqualStrings("definitely_not_a_tool", bad.?);
    // Validation runs BEFORE any mutation — the rejected list never
    // half-applies.
    try testing.expectEqual(@as(usize, 1), cj.tools.?.len);
    try testing.expectEqualStrings("command", cj.tools.?[0]);
}

test "applyToolsInput: serialization — null emits JSON null, list emits the array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cj_null = ConfigJson{};
    const null_str = try std.json.Stringify.valueAlloc(arena.allocator(), cj_null, .{});
    try testing.expect(std.mem.indexOf(u8, null_str, "\"tools\":null") != null);

    var cj_list = ConfigJson{};
    const names = [_][]const u8{"command"};
    const bad = try applyToolsInput(arena.allocator(), &cj_list, &names);
    try testing.expect(bad == null);
    const list_str = try std.json.Stringify.valueAlloc(arena.allocator(), cj_list, .{});
    try testing.expect(std.mem.indexOf(u8, list_str, "\"tools\":[\"command\"]") != null);
}

test "an enabled skill_evals block round-trips through the PUT write struct" {
    // The grep test above proves the field is DECLARED. This proves it
    // BEHAVES: the exact round-trip that used to return
    // `skill_evals survived=false`.
    const allocator = std.testing.allocator;
    const on_disk =
        \\{"skill_evals":{"enabled":true,"max_skills_per_run":3},"notify_on_complete":true}
    ;
    var parsed = try std.json.parseFromSlice(ConfigJson, allocator, on_disk, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expect(parsed.value.skill_evals.enabled);
    try testing.expectEqual(@as(u32, 3), parsed.value.skill_evals.max_skills_per_run);

    // A save that does not mention skill_evals (every other Settings tab)
    // re-serializes the whole config. The opt-in must still be there.
    const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_tab });
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "\"skill_evals\"") == null) {
        std.debug.print("!! skill_evals was stripped on save: {s}\n", .{out});
        return error.SkillEvalsStrippedOnSave;
    }
    if (std.mem.indexOf(u8, out, "\"enabled\": true") == null) {
        std.debug.print("!! skill_evals.enabled lost its value on save: {s}\n", .{out});
        return error.SkillEvalsEnabledLostOnSave;
    }

    // And the block must never serialize to JSON null — the runtime parser
    // rejects null for this struct, so that would make config unloadable.
    if (std.mem.indexOf(u8, out, "\"skill_evals\": null") != null) {
        std.debug.print("!! skill_evals serialized to null: {s}\n", .{out});
        return error.SkillEvalsSerializedToNull;
    }
}

test "the response serializes skill_evals.enabled so the toggle can render it" {
    const allocator = std.testing.allocator;
    const off = try http_response.makePabrikConfigResponse(allocator, .{});
    defer allocator.free(off);
    // Absent on disk must read as OFF, never a phantom ON.
    if (std.mem.indexOf(u8, off, "\"skill_evals\":{\"enabled\":false") == null) {
        std.debug.print("!! default response omits skill_evals.enabled: {s}\n", .{off});
        return error.SkillEvalsMissingFromDefaultResponse;
    }

    const on = try http_response.makePabrikConfigResponse(allocator, .{
        .skill_evals = .{ .enabled = true, .apply_mode = "propose" },
    });
    defer allocator.free(on);
    if (std.mem.indexOf(u8, on, "\"enabled\":true") == null) {
        std.debug.print("!! response does not serialize skill_evals.enabled=true: {s}\n", .{on});
        return error.SkillEvalsEnabledNotSerialized;
    }
}
