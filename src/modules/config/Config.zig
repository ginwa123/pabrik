const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const LLMModels = @import("../agent/LLMModels.zig");
const model_catalog = @import("../../agentic_loop/model_catalog.zig");
const helpers = @import("helpers");
const parse_thinking = @import("parse_thinking.zig");

/// Skill Evals — the agent evaluates the skills it actually used.
pub const SkillEvalsConfig = struct {
    /// Master switch. False = the feature is off and cannot spend anything.
    enabled: bool = false,
    /// Upper bound on sub-agent fan-out within a single run. Above this the
    /// remaining skills are recorded as skipped rather than silently dropped.
    max_skills_per_run: u32 = 8,
    /// Daily ceiling on eval runs, counted from `skill_eval_runs.created_at`.
    max_evals_per_day: u32 = 10,
    /// How long a `skill_eval_facts` row may sit in the `'computing'` lease
    /// before another session may steal it. A crashed owner must not be able
    /// to poison the shared cache forever.
    fact_lease_seconds: u32 = 300,
    /// Whether a skill that was *listed* but never loaded is evaluated too.
    /// Off would hide the "the agent was offered the right skill and ignored
    /// it" finding, which is a real one, so this defaults on.
    include_listed_without_loading: bool = true,
    /// What may be done with a verdict. `propose` records and surfaces it but
    /// never writes to a skill without a human clicking Apply.
    apply_mode: ApplyMode = .propose,

    pub const ApplyMode = enum { off, propose, auto_low_risk };
};

/// Tolerant JSON mirror of `SkillEvalsConfig`. A separate type from the
/// runtime one for the same reason `ProfileJson` is separate from
/// `LlmProfile`: the JSON side must survive a user typo.
pub const SkillEvalsJson = struct {
    enabled: bool = false,
    max_skills_per_run: u32 = 8,
    max_evals_per_day: u32 = 10,
    fact_lease_seconds: u32 = 300,
    include_listed_without_loading: bool = true,
    apply_mode: ?[]const u8 = null,
};

/// Map the tolerant `config.json` string to the runtime enum.
fn parseApplyMode(raw: ?[]const u8) SkillEvalsConfig.ApplyMode {
    const s = raw orelse return .propose;
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "auto_low_risk")) return .auto_low_risk;
    return .propose;
}

/// Map the wire block onto the runtime struct.
pub fn skillEvalsFromJson(wire: SkillEvalsJson) SkillEvalsConfig {
    return .{
        .enabled = wire.enabled,
        .max_skills_per_run = wire.max_skills_per_run,
        .max_evals_per_day = wire.max_evals_per_day,
        .fact_lease_seconds = wire.fact_lease_seconds,
        .include_listed_without_loading = wire.include_listed_without_loading,
        // Tolerant: absent or unrecognised degrades to `propose`.
        .apply_mode = parseApplyMode(wire.apply_mode),
    };
}

pub const LlmConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    model_compaction_size_kb: usize,
    mcpServers_parsed: ?json.Parsed(json.Value),
    /// Typed map of MCP servers. Keys are server names, values are owned
    /// `McpServerConfig` (with their own owned `url` and `headers`).
    mcp_servers: McpServersMap,
    /// Parsed profiles from profiles_models
    profiles_models: ProfilesMap,
    /// Top-level sub-agents array. Each entry is a typed `SubAgentConfig`
    /// with its own owned strings.
    sub_agents: SubAgentsList,
    url_style: []const u8,
    /// When true, fire an OS-level notification when an LLM response finishes
    /// with `finish_reason === 'stop'`. Off by default — the user opts in via
    /// the config.
    notify_on_complete: bool = true,
    /// When true, fire an OS-level notification when the LLM workflow hits a
    /// transport error, retries exhaust (TooManyRetries), or the outer
    /// agentic loop catches an unrecoverable error.
    notify_on_error: bool = false,
    /// When true, browser mode is on: the same UI served to the desktop
    /// webview is advertised for the user's system browser on a random local
    /// port (settings General tab shows the URL + auto-opens it).
    web_launch_enabled: bool = false,
    /// Skill Evals — the agent evaluates the skills it actually used. Off by
    /// default; see `SkillEvalsConfig` for the switch and the reasoning.
    skill_evals: SkillEvalsConfig = .{},
    /// Delay in milliseconds that the workflow sleeps before retrying a
    /// failed `callDynamicAgentNew` call. 0 = no delay (current behavior, the
    /// retry fires immediately on the next loop iteration).
    retry_delay_ms: u32 = 0,
    /// Optional top-level override for the context window (in tokens).
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold as a percentage (0-100) of the
    /// model's context window.
    compaction_threshold_percent: ?u8 = null,
    /// Add a model-written summary to each compaction envelope. Off by default:
    /// the envelope is deterministic without it.
    compaction_llm_summary: bool = false,
    /// Plan 2026-08-06-set-active-profile-default — optional name of a
    /// profile in `profiles_models` that the workflow uses as the default
    /// when neither the session's `selected_profile_model` nor the POST
    active_profile: ?[]const u8 = null,
    /// Owned slice of random sub-agent names that `resolveSubAgent` generated
    /// for the random-fallback case. Each name is allocated on
    /// `self.allocator` and is freed in `deinit`.
    random_names: [][]u8 = &.{},
    /// Default tool checklist from config.json (plan
    /// 2026-09-22-tools-menu-config-default-tools).
    tools: ?[]const []const u8 = null,
    /// User-configured web-search providers, keyed by the provider name the
    /// agent passes as the `provider` tool argument.
    web_search: ?WebSearchProvidersMap = null,

    pub const LoadError = error{
        ConfigFileNotFound,
        ConfigFileReadError,
        InvalidJson,
        MissingRequiredField,
        OutOfMemory,
        HomeNotFound,
        ConfigDirNotFound,
        /// `compaction_threshold_percent` outside the 0..100 range.
        InvalidThresholdPercent,
        /// `thinking_budget_tokens` outside the (0, 2_000_000] range.
        /// Surfaced by the HTTP PUT handler (plan 2026-08-23-model-thinking).
        InvalidThinkingBudgetTokens,
        /// `reasoning_effort` outside the {low, medium, high, auto} set.
        /// Surfaced by the HTTP PUT handler via the `parse_thinking`
        /// helper.
        InvalidReasoningEffort,
    };

    /// Canonical `backend` values — the transport discriminator, orthogonal
    /// to `url_style` (which describes HTTP wire format only).
    pub const Backend = struct {
        /// POST to `base_url` using the profile's `url_style`. The default
        /// for every config that does not name a backend.
        pub const http = "http";
        /// Run the local `claude` CLI (subscription auth via `claude login`).
        /// `base_url` / `api_key` / `url_style` do not apply.
        pub const claude_code = "claude-code";
        /// Run the local `opencode` CLI (agentic loop via `opencode run`).
        /// `base_url` / `api_key` / `url_style` do not apply.
        pub const opencode = "opencode";
    };

    /// Individual profile settings.
    pub const LlmProfile = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
        url_style: []const u8 = "openai",
        /// Transport discriminator — `""` (unset → resolves to `"http"`) or
        /// `"claude-code"`.
        backend: []const u8 = "",
        /// Claude Code only: the directory the `claude` CLI reads its
        /// credentials/config from (`CLAUDE_CONFIG_DIR`).
        config_dir: ?[]const u8 = null,
        /// Claude Code only: agentic turn ceiling passed as
        /// `--max-turns`. `null` = the CLI's own default.
        max_turns: ?u32 = null,
        /// OpenCode only: which of the CLI's agents runs the turn
        /// (`--agent`). `null` = the CLI's default agent.
        opencode_agent: ?[]const u8 = null,
        /// OpenCode only: whether to pass `--auto`. `null` = on (the headless
        /// default); `false` = off. Stored as an optional so the absent key
        /// costs no allocation and `freeProfilesMap` stays balanced.
        opencode_auto: ?bool = null,
        /// Per-profile sub-agents. Owned `[]SubAgentConfig` (default empty).
        /// Each entry's strings are allocated with the parent `LlmConfig.allocator`.
        sub_agents: SubAgentsList = &.{},
        /// Optional override for the context window (in tokens) used by this
        /// profile.
        max_capacity_tokens: ?u32 = null,
        /// Compaction threshold as a percentage (0-100) of the model's
        /// context window. `null` = use the built-in 80. Values > 100
        /// are rejected by the HTTP layer with `error.InvalidThresholdPercent`.
        compaction_threshold_percent: ?u8 = null,
        /// Anthropic-only: override for `thinking.budget_tokens`. When set,
        /// used directly by `buildJsonAnthropicRequest` (clamped to >=1024
        /// and <max_tokens).
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1). One
        /// of "low" | "medium" | "high" | "auto". Validated by
        /// `parse_thinking.parseReasoningEffort`.
        reasoning_effort: ?[]const u8 = null,
    };

    /// Typed configuration for a single sub-agent. Mirrors `LlmProfile`
    /// fields plus an additional `system_prompt` and two compaction-related
    /// overrides that cascade over the parent profile.
    pub const SubAgentConfig = struct {
        name: []const u8,
        model: []const u8,
        base_url: []const u8,
        thinking: []const u8,
        temperature: []const u8,
        url_style: []const u8,
        api_key: []const u8,
        system_prompt: []const u8,
        /// Transport discriminator — `"http"` (default) | `"claude-code"`.
        /// Empty = inherit the parent orchestrator's backend.
        backend: []const u8 = "",
        /// Claude Code only: `CLAUDE_CONFIG_DIR` override. `null` =
        /// inherit the parent profile (then the CLI default).
        config_dir: ?[]const u8 = null,
        /// Claude Code only: `--max-turns` override. `null` = inherit the
        /// parent profile.
        max_turns: ?u32 = null,
        /// OpenCode only: `--agent` override. `null` = inherit the parent
        /// profile.
        opencode_agent: ?[]const u8 = null,
        /// OpenCode only: `--auto` override. `null` = inherit the parent
        /// profile.
        opencode_auto: ?bool = null,
        /// Optional override for the context window (in tokens) for
        /// this sub-agent. `null` = inherit from the parent profile (or
        /// the built-in default if no profile).
        max_capacity_tokens: ?u32 = null,
        /// Compaction threshold percentage (0-100) for this sub-agent.
        /// `null` = inherit from the parent profile (or 80 if no profile).
        compaction_threshold_percent: ?u8 = null,
        /// Anthropic-only override for `thinking.budget_tokens`. See
        /// `LlmProfile.thinking_budget_tokens` for full semantics.
        /// `null` = inherit from the parent profile.
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
        /// See `LlmProfile.reasoning_effort` for full semantics.
        /// `null` = inherit from the parent profile.
        reasoning_effort: ?[]const u8 = null,
    };

    /// Owned slice of `SubAgentConfig` entries. The slice itself (when non-empty)
    /// is allocated with the parent `LlmConfig.allocator`, and each entry's
    /// string fields are individually allocated on the same allocator.
    pub const SubAgentsList = []SubAgentConfig;

    /// Resolved sub-agent configuration — the output of `resolveSubAgent`.
    pub const ResolvedSubAgent = struct {
        /// Name to record as `agent_name` for the sub-agent's session
        /// and to embed in the session_id suffix.
        name: []const u8,

        /// True iff `agent_name` was provided but not found in any
        /// sub_agents list. False when the name was found.
        is_random_fallback: bool,

        /// The name the LLM originally requested. Useful for
        /// logging. Empty if no `agent_name` was provided.
        requested_name: []const u8,

        /// Resolved LLM endpoint fields (overlay applied).
        model: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        url_style: []const u8,

        /// Resolved transport — `"http"` | `"claude-code"`.
        backend: []const u8,

        /// Claude Code only: resolved `CLAUDE_CONFIG_DIR` (`null` =
        /// inherit / CLI default).
        config_dir: ?[]const u8,

        /// Claude Code only: resolved `--max-turns` (`null` = inherit).
        max_turns: ?u32,

        /// OpenCode only: resolved `--agent` (`null` = inherit / CLI
        /// default).
        opencode_agent: ?[]const u8,

        /// OpenCode only: resolved `--auto` (`null` = inherit).
        opencode_auto: ?bool,

        /// Resolved `thinking` setting. `null` = "auto" — inherit
        /// from parent's value at run time.
        is_thinking: ?bool,

        /// Resolved `temperature` setting. `null` = "auto" — inherit
        /// from parent's value at run time.
        temperature: ?f32,

        /// Resolved Anthropic `thinking.budget_tokens` override. `null`
        /// = inherit from the parent profile. Range-validated upstream
        /// (HTTP layer rejects 0 or > 2_000_000).
        thinking_budget_tokens: ?u32,

        /// Resolved OpenAI `reasoning_effort` value (already validated
        /// to one of "low" | "medium" | "high" | "auto"). `null` =
        /// inherit from the parent profile.
        reasoning_effort: ?[]const u8,

        /// System prompt to inject as the sub-agent's
        /// `## Your Active Agent Configuration`. Empty for the
        /// random-fallback case.
        system_prompt: []const u8,

        /// Which sub_agents list supplied this config: the profile name (e.g.
        /// `"profile1"`) or `""` for top-level.
        source: []const u8,
    };

    const ProfileJson = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
        url_style: []const u8 = "openai",
        /// Transport discriminator. Absent key = `"http"`, which is what
        /// keeps every pre-existing config byte-identical.
        backend: []const u8 = "http",
        /// Claude Code only: `CLAUDE_CONFIG_DIR`. Null = CLI default.
        config_dir: ?[]const u8 = null,
        /// Claude Code only: `--max-turns`. Null = CLI default.
        max_turns: ?u32 = null,
        /// OpenCode only: `--agent`. Null = CLI default agent.
        opencode_agent: ?[]const u8 = null,
        /// OpenCode only: `--auto`. Null = on (the headless default).
        opencode_auto: ?bool = null,
        /// Per-profile sub-agents (typed — defaults to absent).
        sub_agents: ?[]SubAgentJson = null,
        /// Optional per-profile override for the context window (in tokens).
        /// Null = use LLMModels built-in per-model default.
        max_capacity_tokens: ?u32 = null,
        /// Optional per-profile override for the compaction threshold
        /// percentage (0-100). Null = use built-in 80. Range-validated
        /// at the HTTP layer.
        compaction_threshold_percent: ?u8 = null,
        /// Anthropic-only override for `thinking.budget_tokens`. Range-
        /// validated upstream (HTTP layer rejects 0 or > 2_000_000).
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
        /// Parsed via `parse_thinking.parseReasoningEffort`; a bad
        /// value here surfaces at HTTP layer as `InvalidReasoningEffort`.
        reasoning_effort: ?[]const u8 = null,
    };

    const LlmConfigJson = struct {
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        url_style: []const u8 = "openai",
        model_compaction_size_kb: usize = 100,
        /// Opt-in: fire an OS notification when an LLM response finishes
        /// with `finish_reason === 'stop'`. Default false (user must
        /// explicitly enable in config to avoid surprise notifications).
        notify_on_complete: bool = false,
        /// Opt-in: fire an OS notification when the LLM workflow hits an
        /// error (transport failure, TooManyRetries, outer catch). Default
        /// false.
        notify_on_error: bool = false,
        /// Opt-in: allow the agent to launch URLs in the user's web
        /// browser. Default false. Mirrors `notify_on_complete`.
        web_launch_enabled: bool = false,
        /// Skill Evals.
        skill_evals: SkillEvalsJson = .{},
        /// Delay in milliseconds before retrying a failed workflow call.
        /// See `LlmConfig.retry_delay_ms` for semantics. Plan
        /// 2026-07-15-retry-delay.
        retry_delay_ms: u32 = 0,
        /// Optional top-level override for the context window (in tokens).
        /// Null = fall through to the per-profile override, then built-in.
        max_capacity_token_model: ?u32 = null,
        /// Optional top-level compaction threshold as a percentage (0-100).
        /// Null = fall through to per-profile override, then 80.
        compaction_threshold_percent: ?u8 = null,
        /// Add a model-written summary to each compaction envelope. Off by
        /// default: the envelope is deterministic without it.
        compaction_llm_summary: bool = false,
        /// Plan 2026-08-06-set-active-profile-default — name of the profile
        /// to use as the default when no other selection is set.
        active_profile: ?[]const u8 = null,
        /// Configured MCP servers (snake_case, matches PABRIK.md JSON convention).
        mcp_servers: ?std.json.Value = null,
        /// Profiles - parsed as json.Value then converted to map
        profiles_models: ?std.json.Value = null,
        /// Top-level sub-agents array. Raw JSON value parsed via
        /// `parseSubAgentsList` into an owned `[]SubAgentConfig`.
        sub_agents: ?std.json.Value = null,
        /// Stable per-install UUID used as the LLM-API end-user identifier.
        /// Empty string when missing from the parsed JSON (legacy configs).
        user_identifier: []const u8 = "",
        /// Default tool checklist (plan
        /// 2026-09-22-tools-menu-config-default-tools).
        tools: ?[]const []const u8 = null,
        /// Configured web-search providers (snake_case). Raw JSON value
        /// parsed into the typed `WebSearchProvidersMap`; the map owns the
        /// duped strings because this parse struct borrows.
        web_search: ?std.json.Value = null,
    };

    /// JSON-side parse struct for a single sub-agent entry. Mirrors
    /// `SubAgentConfig` exactly (borrowed slices from the parsed JSON blob,
    /// vs `SubAgentConfig`'s owned allocator slices).
    pub const SubAgentJson = struct {
        name: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        url_style: []const u8 = "openai",
        api_key: []const u8 = "",
        system_prompt: []const u8 = "",
        /// Transport discriminator. Empty = inherit the parent profile's
        /// backend (see `SubAgentConfig.backend`).
        backend: []const u8 = "",
        /// Claude Code only: `CLAUDE_CONFIG_DIR` override.
        config_dir: ?[]const u8 = null,
        /// Claude Code only: `--max-turns` override.
        max_turns: ?u32 = null,
        /// OpenCode only: `--agent` override.
        opencode_agent: ?[]const u8 = null,
        /// OpenCode only: `--auto` override.
        opencode_auto: ?bool = null,
        /// Optional per-sub-agent override for the context window (in tokens).
        max_capacity_tokens: ?u32 = null,
        /// Optional per-sub-agent override for the compaction threshold
        /// percentage (0-100).
        compaction_threshold_percent: ?u8 = null,
        /// Anthropic-only override for `thinking.budget_tokens`. See
        /// `LlmProfile.thinking_budget_tokens`.
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style `reasoning_effort`. See `LlmProfile.reasoning_effort`.
        reasoning_effort: ?[]const u8 = null,
    };

    /// Profiles storage after parsing from JSON
    pub const ProfilesMap = std.StringHashMap(LlmProfile);

    /// A single header (key/value pair) for an MCP server request.
    pub const McpHeader = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Map of HTTP header name to header value for a single MCP server.
    /// The map owns both the keys and the values (all are allocated strings).
    pub const McpHeadersMap = std.StringHashMap([]const u8);

    /// Typed configuration for a single MCP server. Each entry is EITHER an
    /// HTTP server (with `url` + optional `headers`) OR a stdio server (with
    /// `command` + optional `args` + optional `cwd`).
    pub const McpServerConfig = struct {
        /// HTTP transport: the URL of the MCP server. Null for stdio entries.
        url: ?[]const u8,
        /// HTTP transport: optional request headers (e.g. `Authorization`).
        headers: McpHeadersMap,
        /// stdio transport: the command to spawn. Null for HTTP entries.
        command: ?[]const u8,
        /// stdio transport: command-line args. Null when not specified.
        args: ?[]const []const u8,
        /// stdio transport: working directory. Null = inherit from parent.
        cwd: ?[]const u8,
        /// Whether the server is enabled. Defaults to true — absent or
        /// non-bool `enabled` values parse as true (ignored, not fatal).
        enabled: bool = true,

        pub const Transport = enum { http, stdio };

        /// Returns the transport discriminator — derived from which
        /// field is set. `command` takes precedence over `url` (so a
        /// future "hybrid" entry would default to stdio).
        pub fn transport(self: McpServerConfig) Transport {
            if (self.command) |c| if (c.len > 0) return .stdio;
            return .http;
        }

        /// Returns true when the server is configured with exactly one
        /// non-empty transport (HTTP url OR stdio command, but not both,
        /// not neither, not either empty).
        pub fn isValid(self: McpServerConfig) bool {
            const has_url = if (self.url) |u| u.len > 0 else false;
            const has_cmd = if (self.command) |c| c.len > 0 else false;
            return has_url != has_cmd; // exactly one
        }
    };

    /// Map of MCP server name (e.g. "context7") to its typed configuration.
    /// The map owns the server-name keys and the `McpServerConfig` payloads.
    pub const McpServersMap = std.StringHashMap(McpServerConfig);

    /// One user-configured web-search provider.
    pub const WebSearchProviderEntry = struct {
        /// The host pin. This is the ONLY host whose requests may ever
        /// carry `key`; it is compared against the host of whatever curl
        /// the agent sends, before substitution happens.
        url: []const u8,
        /// The credential. Optional — a self-hosted provider needs none.
        /// An absent field means "no credential"; `""` is never a valid
        /// stored value (see `isUsable`).
        key: ?[]const u8 = null,
        /// Request template copied from the provider's own docs, with
        /// `{key}` where the credential goes.
        curl: []const u8,
        /// Free-text note the user writes about when to prefer this
        /// provider. Optional. `curl` says HOW to call it; this says
        /// WHEN to use it.
        description: ?[]const u8 = null,
        /// Defaults to true, mirroring `McpServerConfig.enabled`.
        enabled: bool = true,

        /// True when this entry can actually be dispatched: it is enabled,
        /// has a host pin and a template, and — if it declares a credential —
        /// that credential is non-empty.
        pub fn isUsable(self: WebSearchProviderEntry) bool {
            if (!self.enabled) return false;
            if (self.url.len == 0) return false;
            if (self.curl.len == 0) return false;
            if (self.key) |k| {
                if (k.len == 0) return false;
            }
            return true;
        }
    };

    /// Map of provider name (e.g. "tinyfish") to its configuration. The
    /// name is what the agent passes as the `provider` tool argument.
    pub const WebSearchProvidersMap = std.StringHashMap(WebSearchProviderEntry);

    /// Free every owned string in a `WebSearchProvidersMap`, then the map.
    pub fn freeWebSearchProvidersMap(map: *WebSearchProvidersMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            const cfg = entry.value_ptr;
            allocator.free(cfg.url);
            allocator.free(cfg.curl);
            if (cfg.key) |k| allocator.free(k);
            if (cfg.description) |d| allocator.free(d);
        }
        map.deinit();
    }

    /// Parse one provider entry from its JSON object. Returns null (with a
    /// warning) for a malformed entry rather than aborting the whole map:
    /// one bad paste must not take every other provider down with it.
    fn parseWebSearchProviderEntry(
        allocator: std.mem.Allocator,
        name: []const u8,
        value: json.Value,
    ) !?WebSearchProviderEntry {
        if (value != .object) {
            std.log.warn("web_search provider '{s}' is not an object; skipping", .{name});
            return null;
        }
        const obj = value.object;

        // A hand-edited entry with a numeric or null field is a typo, not
        // a crash. Read each field defensively rather than trusting the
        // shape the way a typed parse struct would.
        const url_raw = switch (obj.get("url") orelse json.Value{ .null = {} }) {
            .string => |s| s,
            else => {
                std.log.info("web_search provider '{s}' has no string `url`; skipping", .{name});
                return null;
            },
        };
        const curl_raw = switch (obj.get("curl") orelse json.Value{ .null = {} }) {
            .string => |s| s,
            else => {
                std.log.info("web_search provider '{s}' has no string `curl`; skipping", .{name});
                return null;
            },
        };

        var entry = WebSearchProviderEntry{
            .url = try allocator.dupe(u8, url_raw),
            .curl = try allocator.dupe(u8, curl_raw),
            .key = null,
            .description = null,
            .enabled = true,
        };
        errdefer {
            allocator.free(entry.url);
            allocator.free(entry.curl);
        }

        // `key` is OPTIONAL — a self-hosted provider has none. An empty
        // string is normalised to absent here so `isUsable` has a single
        // rule to check.
        if (obj.get("key")) |kv| switch (kv) {
            .string => |s| if (s.len > 0) {
                entry.key = try allocator.dupe(u8, s);
            },
            else => std.log.info("web_search provider '{s}' has a non-string `key`; treating as absent", .{name}),
        };

        if (obj.get("description")) |dv| switch (dv) {
            .string => |s| if (s.len > 0) {
                entry.description = try allocator.dupe(u8, s);
            },
            else => std.log.info("web_search provider '{s}' has a non-string `description`; ignoring", .{name}),
        };

        if (obj.get("enabled")) |ev| switch (ev) {
            .bool => |b| entry.enabled = b,
            else => std.log.info("web_search provider '{s}' has a non-bool `enabled`; treating as true", .{name}),
        };

        return entry;
    }

    /// Free the owned strings in one provider entry. The name key is NOT
    /// freed — the map owns it.
    fn freeWebSearchProviderEntry(cfg: *WebSearchProviderEntry, allocator: std.mem.Allocator) void {
        allocator.free(cfg.url);
        allocator.free(cfg.curl);
        if (cfg.key) |k| allocator.free(k);
        if (cfg.description) |d| allocator.free(d);
    }

    /// Parse a full `WebSearchProvidersMap` from the body of `web_search`.
    pub fn parseWebSearchProvidersMap(
        allocator: std.mem.Allocator,
        raw: json.Value,
    ) !WebSearchProvidersMap {
        var providers = WebSearchProvidersMap.init(allocator);
        errdefer freeWebSearchProvidersMap(&providers, allocator);

        if (raw != .object) {
            std.log.info("`web_search` is not an object; ignoring", .{});
            return providers;
        }

        var it = raw.object.iterator();
        while (it.next()) |entry| {
            // A hand-edited file with the same provider name twice keeps the
            // first entry. JSON parsers hand us both, and silently letting
            // the last one win would make the pin depend on document order.
            if (providers.contains(entry.key_ptr.*)) {
                std.log.warn("duplicate web_search provider '{s}'; keeping the first", .{entry.key_ptr.*});
                continue;
            }
            const provider = (try parseWebSearchProviderEntry(
                allocator,
                entry.key_ptr.*,
                entry.value_ptr.*,
            )) orelse continue;

            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_dup);
            providers.put(key_dup, provider) catch |err| return err;
        }
        return providers;
    }

    /// Initialize an `LlmConfig` from disk (boot / file mode only). Thin I/O
    /// wrapper around `initFromJsonText`: resolves the path, reads the file,
    /// then delegates to the single JSON -> struct mapping.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8, environment: *std.process.Environ.Map) LoadError!LlmConfig {
        const config_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try getDefaultConfigPath(allocator, environment);
        defer allocator.free(config_path);

        // `config_path` is either the validated default path (see
        // `getDefaultConfigDir`) or an explicit `--config <path>` argument.
        if (!std.fs.path.isAbsolute(config_path)) {
            std.log.warn("Config path is not an absolute path: {s}", .{config_path});
            return error.ConfigFileNotFound;
        }

        const file = Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // First-run auto-init: only for the default path. An explicit
                // path that doesn't exist is treated as a user error (they
                // asked us to read a specific file and it's missing).
                if (path != null) {
                    std.log.info("Config file not found at explicit path {s}", .{config_path});
                    return error.ConfigFileNotFound;
                }
                std.log.info(
                    "Config file not found at {s}; auto-creating with empty placeholders. Edit this file to set api_key/model/base_url.",
                    .{config_path},
                );
                writeDefaultConfig(allocator, io, config_path) catch |write_err| {
                    std.log.warn("Failed to auto-create config file {s}: {s}", .{ config_path, @errorName(write_err) });
                    return error.ConfigFileNotFound;
                };
                // Retry the open. If THIS fails (e.g. permission denied on
                // the new file), surface it as ConfigFileNotFound to match
                // the rest of the catch arm's behavior.
                break :blk Io.Dir.openFileAbsolute(io, config_path, .{}) catch |retry_err| {
                    std.log.warn("Failed to open auto-created config file {s}: {s}", .{ config_path, @errorName(retry_err) });
                    return error.ConfigFileNotFound;
                };
            },
            else => {
                std.log.warn("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
                return error.ConfigFileNotFound;
            },
        };
        defer file.close(io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
            std.log.warn("Failed to read config file: {s}", .{@errorName(err)});
            return error.ConfigFileReadError;
        };
        defer allocator.free(content);

        return initFromJsonText(allocator, content);
    }

    /// Build an `LlmConfig` from in-memory JSON text, applying the same
    /// shape, tolerance (`ignore_unknown_fields`) and post-processing
    /// (`parseToolsList`, `backfillTopLevelFromProfiles`,
    pub fn initFromJsonText(
        allocator: std.mem.Allocator,
        content: []const u8,
    ) LoadError!LlmConfig {
        const parsed = json.parseFromSlice(LlmConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.info("Failed to parse JSON config: {s}", .{@errorName(err)});
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const config_json = parsed.value;

        var config = LlmConfig{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config_json.api_key),
            .model = try allocator.dupe(u8, config_json.model),
            .base_url = try allocator.dupe(u8, config_json.base_url),
            .url_style = try allocator.dupe(u8, config_json.url_style),
            .model_compaction_size_kb = config_json.model_compaction_size_kb,
            .notify_on_complete = config_json.notify_on_complete,
            .notify_on_error = config_json.notify_on_error,
            .web_launch_enabled = config_json.web_launch_enabled,
            .skill_evals = skillEvalsFromJson(config_json.skill_evals),
            .retry_delay_ms = config_json.retry_delay_ms,
            // Top-level compaction defaults — restored in plan
            // 2026-07-07-compaction-inline.
            .max_capacity_token_model = config_json.max_capacity_token_model,
            .compaction_threshold_percent = config_json.compaction_threshold_percent,
            .compaction_llm_summary = config_json.compaction_llm_summary,
            // Plan 2026-08-06-set-active-profile-default — load the
            // user-chosen default profile from JSON.
            .active_profile = blk: {
                const raw = config_json.active_profile orelse break :blk null;
                if (raw.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, raw);
            },
            .mcpServers_parsed = null,
            .mcp_servers = LlmConfig.McpServersMap.init(allocator),
            .profiles_models = LlmConfig.ProfilesMap.init(allocator),
            .sub_agents = &.{},
        };
        errdefer {
            allocator.free(config.api_key);
            allocator.free(config.model);
            allocator.free(config.base_url);
            allocator.free(config.url_style);
            if (config.active_profile) |ap| allocator.free(ap);
            freeMcpServersMap(&config.mcp_servers, allocator);
            freeProfilesMap(&config.profiles_models, allocator);
            freeSubAgentsList(config.sub_agents, allocator);
            freeToolsList(config.tools, allocator);
            if (config.web_search) |*ws| freeWebSearchProvidersMap(ws, allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

        // Owned copy of the `tools` checklist — `parsed` deinits at the end
        // of `init`, so the borrowed slices must be duped here.
        config.tools = try parseToolsList(allocator, config_json.tools);

        // Web-search providers: absent key = no providers. Parsed from the
        // borrowed `config_json` tree, so every string is duped.
        if (config_json.web_search) |ws| {
            config.web_search = try parseWebSearchProvidersMap(allocator, ws);
        }

        if (config_json.mcp_servers) |mcp| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(allocator, mcp, .{}) catch |err| {
                std.log.err("Failed to serialize mcp_servers: {s}", .{@errorName(err)});
                return error.ConfigFileReadError;
            };
            defer allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("Failed to parse mcp_servers: {s}", .{@errorName(err)});
                return error.InvalidJson;
            };
            // Store the full Parsed wrapper so we can call .deinit() on it later
            config.mcpServers_parsed = reparsed;

            // Also populate the typed map. Both representations stay in sync
            // because they are built from the same JSON object.
            const typed = reparsed.value;
            switch (typed) {
                .object => |obj| {
                    config.mcp_servers = parseMcpServersMap(allocator, obj) catch |err| {
                        std.log.err("Failed to parse mcp_servers: {s}", .{@errorName(err)});
                        return error.InvalidJson;
                    };
                },
                else => {},
            }
        }

        // Parse profiles_models into ProfilesMap.
        // 2026-08-06-config-profiles-arbitrary-keys: the previous
        // implementation parsed `profiles_models` against a hardcoded 4-field
        if (config_json.profiles_models) |profiles| {
            const profiles_str = std.json.Stringify.valueAlloc(allocator, profiles, .{}) catch {
                return error.InvalidJson;
            };
            defer allocator.free(profiles_str);

            const profiles_parsed = json.parseFromSlice(json.Value, allocator, profiles_str, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            defer profiles_parsed.deinit();

            switch (profiles_parsed.value) {
                .object => |obj| {
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        // entry.key_ptr.* is the user-chosen profile
                        // name (e.g. "900ribu"). entry.value_ptr is a
                        // json.Value for the profile object.
                        const profile_json_str = std.json.Stringify.valueAlloc(
                            allocator,
                            entry.value_ptr,
                            .{},
                        ) catch continue;
                        defer allocator.free(profile_json_str);

                        const profile_parsed = json.parseFromSlice(
                            ProfileJson,
                            allocator,
                            profile_json_str,
                            .{ .ignore_unknown_fields = true },
                        ) catch continue;
                        defer profile_parsed.deinit();

                        try addProfile(
                            &config.profiles_models,
                            entry.key_ptr.*,
                            profile_parsed.value,
                            allocator,
                        );
                    }
                },
                else => {},
            }
        }

        // Parse top-level sub_agents (skip-with-warning on bad entries).
        config.sub_agents = try parseSubAgentsList(allocator, config_json.sub_agents);

        // Plan 2026-09-04-subagents-per-profile: one-time load migration. Old
        // configs carry subagents ONLY at the top level.
        try migrateTopLevelSubAgentsIntoEmptyProfiles(&config);

        // Plan 2026-08-24-config-simplify-remove-defaults: config.json no
        // longer carries top-level api_key/model/base_url/url_style.
        try backfillTopLevelFromProfiles(&config);

        return config;
    }

    /// Derive empty top-level LLM fields from the resolved profile.
    fn backfillTopLevelFromProfiles(config: *LlmConfig) LoadError!void {
        const needs_backfill =
            config.model.len == 0 or
            config.base_url.len == 0 or
            config.api_key.len == 0;
        if (!needs_backfill) return;

        // resolveSessionProfileCompat walks selected→active; here there is
        // no session context, so selection is just active_profile.
        var p: ?LlmProfile = config.resolveSessionProfileCompat("");
        if (p == null) {
            // No active profile (or it names a missing entry): fall back to
            // the first profile with a non-empty model.
            var it = config.profiles_models.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.model.len > 0) {
                    p = entry.value_ptr.*;
                    break;
                }
            }
        }
        const prof = p orelse return; // no usable profile → leave as-is

        if (config.model.len == 0) {
            config.model = try config.allocator.dupe(u8, prof.model);
        }
        if (config.base_url.len == 0) {
            config.base_url = try config.allocator.dupe(u8, prof.base_url);
        }
        if (config.api_key.len == 0) {
            config.api_key = try config.allocator.dupe(u8, prof.api_key);
        }
        // url_style: profile-wins rule (see doc comment above). Only when
        // we actually backfilled something AND the profile's style is set.
        if (prof.url_style.len > 0 and !std.mem.eql(u8, config.url_style, prof.url_style)) {
            // Free the old owned slice before replacing (url_style is
            // always heap-owned: duped in init/clone).
            config.allocator.free(config.url_style);
            config.url_style = try config.allocator.dupe(u8, prof.url_style);
        }
    }

    /// Parse the top-level `tools` checklist into an owned slice of owned
    /// names.
    fn parseToolsList(allocator: std.mem.Allocator, src: ?[]const []const u8) LoadError!?[]const []const u8 {
        const list = src orelse return null;
        const owned = try allocator.alloc([]const u8, list.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |name| allocator.free(name);
            allocator.free(owned);
        }
        for (list) |name| {
            owned[filled] = try allocator.dupe(u8, name);
            filled += 1;
        }
        return owned;
    }

    /// Free the owned `tools` checklist (names + slice header). No-op on
    /// `null` and on `[]` (a zero-length `free` is a no-op).
    fn freeToolsList(list: ?[]const []const u8, allocator: std.mem.Allocator) void {
        const names = list orelse return;
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    /// Free all keys and value strings inside a ProfilesMap, then deinit the map.
    fn freeProfilesMap(map: *ProfilesMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.model);
            allocator.free(entry.value_ptr.base_url);
            allocator.free(entry.value_ptr.thinking);
            allocator.free(entry.value_ptr.temperature);
            allocator.free(entry.value_ptr.api_key);
            allocator.free(entry.value_ptr.url_style);
            if (entry.value_ptr.backend.len > 0) allocator.free(entry.value_ptr.backend);
            if (entry.value_ptr.config_dir) |d| allocator.free(d);
            if (entry.value_ptr.opencode_agent) |a| allocator.free(a);
            if (entry.value_ptr.reasoning_effort) |re| allocator.free(re);
            freeSubAgentsList(entry.value_ptr.sub_agents, allocator);
        }
        map.deinit();
    }

    /// Add a single profile to the map, duplicating all strings onto the allocator.
    fn addProfile(m: *ProfilesMap, name: []const u8, p: ?ProfileJson, alloc: std.mem.Allocator) !void {
        const profile = p orelse return;

        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);

        const model = try alloc.dupe(u8, profile.model);
        errdefer alloc.free(model);

        const base_url = try alloc.dupe(u8, profile.base_url);
        errdefer alloc.free(base_url);

        const thinking = try alloc.dupe(u8, profile.thinking);
        errdefer alloc.free(thinking);

        const temperature = try alloc.dupe(u8, profile.temperature);
        errdefer alloc.free(temperature);

        const url_style = try alloc.dupe(u8, profile.url_style);
        errdefer alloc.free(url_style);

        const api_key = try alloc.dupe(u8, profile.api_key);
        errdefer alloc.free(api_key);

        // Transport + its Claude Code knobs.
        const backend: []const u8 = if (profile.backend.len > 0)
            try alloc.dupe(u8, profile.backend)
        else
            "";
        errdefer if (backend.len > 0) alloc.free(backend);
        const config_dir: ?[]const u8 = blk: {
            const d = profile.config_dir orelse break :blk null;
            if (d.len == 0) break :blk null;
            break :blk try alloc.dupe(u8, d);
        };
        errdefer if (config_dir) |d| alloc.free(d);
        // OpenCode's `--agent` follows the same "empty stays absent" rule as
        // `config_dir`, so an absent key costs no allocation.
        const opencode_agent: ?[]const u8 = blk: {
            const a = profile.opencode_agent orelse break :blk null;
            if (a.len == 0) break :blk null;
            break :blk try alloc.dupe(u8, a);
        };
        errdefer if (opencode_agent) |a| alloc.free(a);

        const profile_sub_agents = try parseSubAgentsJson(alloc, profile.sub_agents);
        errdefer freeSubAgentsList(profile_sub_agents, alloc);

        try m.put(key, LlmProfile{
            .model = model,
            .base_url = base_url,
            .thinking = thinking,
            .temperature = temperature,
            .api_key = api_key,
            .url_style = url_style,
            .backend = backend,
            .config_dir = config_dir,
            .max_turns = profile.max_turns,
            .opencode_agent = opencode_agent,
            .opencode_auto = profile.opencode_auto,
            .sub_agents = profile_sub_agents,
            // Per-profile compaction overrides — optional, parsed from JSON.
            .max_capacity_tokens = profile.max_capacity_tokens,
            .compaction_threshold_percent = profile.compaction_threshold_percent,
            // Model-thinking knobs — Anthropic budget + OpenAI effort.
            .thinking_budget_tokens = profile.thinking_budget_tokens,
            .reasoning_effort = if (profile.reasoning_effort) |re| try alloc.dupe(u8, re) else null,
        });
    }

    /// Free all owned memory inside a `SubAgentsList` (per-entry strings
    /// plus the slice header itself). Safe to call with an empty slice.
    fn freeSubAgentsList(slice: SubAgentsList, allocator: std.mem.Allocator) void {
        for (slice) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.model);
            allocator.free(sa.base_url);
            allocator.free(sa.thinking);
            allocator.free(sa.temperature);
            allocator.free(sa.url_style);
            allocator.free(sa.api_key);
            allocator.free(sa.system_prompt);
            // Empty = "inherit the parent's backend", stored as the struct's
            // literal default rather than a heap copy — freeing it would
            // abort on a non-heap pointer. Only a non-empty value was duped.
            if (sa.backend.len > 0) allocator.free(sa.backend);
            if (sa.config_dir) |d| allocator.free(d);
            if (sa.opencode_agent) |a| allocator.free(a);
            if (sa.reasoning_effort) |re| allocator.free(re);
        }
        if (slice.len > 0) allocator.free(slice);
    }

    /// Parse a `SubAgentsList` from an already-typed `[]SubAgentJson` (the
    /// parse target for `ProfileJson.sub_agents`).
    fn parseSubAgentsJson(allocator: std.mem.Allocator, items: ?[]const SubAgentJson) !SubAgentsList {
        const unwrapped = items orelse return &.{};

        var list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (list.items) |sa| {
                allocator.free(sa.name);
                allocator.free(sa.model);
                allocator.free(sa.base_url);
                allocator.free(sa.thinking);
                allocator.free(sa.temperature);
                allocator.free(sa.url_style);
                allocator.free(sa.api_key);
                allocator.free(sa.system_prompt);
                if (sa.backend.len > 0) allocator.free(sa.backend);
                if (sa.config_dir) |d| allocator.free(d);
                if (sa.opencode_agent) |a| allocator.free(a);
            }
            list.deinit(allocator);
        }

        for (unwrapped) |j| {
            if (j.name.len == 0) {
                std.log.warn("sub_agents entry has empty 'name'; skipping", .{});
                continue;
            }

            const name = try allocator.dupe(u8, j.name);
            errdefer allocator.free(name);
            const model = try allocator.dupe(u8, j.model);
            errdefer allocator.free(model);
            const base_url = try allocator.dupe(u8, j.base_url);
            errdefer allocator.free(base_url);
            const thinking = try allocator.dupe(u8, j.thinking);
            errdefer allocator.free(thinking);
            const temperature = try allocator.dupe(u8, j.temperature);
            errdefer allocator.free(temperature);
            const url_style = try allocator.dupe(u8, j.url_style);
            errdefer allocator.free(url_style);
            const api_key = try allocator.dupe(u8, j.api_key);
            errdefer allocator.free(api_key);
            const system_prompt = try allocator.dupe(u8, j.system_prompt);
            errdefer allocator.free(system_prompt);
            // Empty backend/config_dir stay literal/absent — see
            // `freeSubAgentsList` for why only non-empty values are freed.
            const backend: []const u8 = if (j.backend.len > 0)
                try allocator.dupe(u8, j.backend)
            else
                "";
            errdefer if (backend.len > 0) allocator.free(backend);
            const config_dir: ?[]const u8 = blk: {
                const d = j.config_dir orelse break :blk null;
                if (d.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, d);
            };
            errdefer if (config_dir) |d| allocator.free(d);
            const opencode_agent: ?[]const u8 = blk: {
                const a = j.opencode_agent orelse break :blk null;
                if (a.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, a);
            };
            errdefer if (opencode_agent) |a| allocator.free(a);

            try list.append(allocator, .{
                .name = name,
                .model = model,
                .base_url = base_url,
                .thinking = thinking,
                .temperature = temperature,
                .url_style = url_style,
                .api_key = api_key,
                .system_prompt = system_prompt,
                .backend = backend,
                .config_dir = config_dir,
                .max_turns = j.max_turns,
                .opencode_agent = opencode_agent,
                .opencode_auto = j.opencode_auto,
                // Per-sub-agent compaction overrides — optional, parsed from JSON.
                .max_capacity_tokens = j.max_capacity_tokens,
                .compaction_threshold_percent = j.compaction_threshold_percent,
                // Model-thinking knobs — Anthropic budget + OpenAI effort.
                .thinking_budget_tokens = j.thinking_budget_tokens,
                .reasoning_effort = if (j.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// Parse a `SubAgentsList` from a raw JSON array value.
    fn parseSubAgentsList(allocator: std.mem.Allocator, value: ?std.json.Value) !SubAgentsList {
        const unwrapped = value orelse return &.{};
        const arr = switch (unwrapped) {
            .array => |a| a,
            else => return &.{},
        };

        var list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (list.items) |sa| {
                allocator.free(sa.name);
                allocator.free(sa.model);
                allocator.free(sa.base_url);
                allocator.free(sa.thinking);
                allocator.free(sa.temperature);
                allocator.free(sa.url_style);
                allocator.free(sa.api_key);
                allocator.free(sa.system_prompt);
                if (sa.backend.len > 0) allocator.free(sa.backend);
                if (sa.config_dir) |d| allocator.free(d);
                if (sa.reasoning_effort) |re| allocator.free(re);
            }
            list.deinit(allocator);
        }

        for (arr.items) |item| {
            const obj = item.object;
            const name_val = obj.get("name") orelse {
                std.log.warn("sub_agents entry missing 'name'; skipping", .{});
                continue;
            };
            if (name_val != .string or name_val.string.len == 0) {
                std.log.warn("sub_agents entry has empty/non-string 'name'; skipping", .{});
                continue;
            }

            const item_str = try std.json.Stringify.valueAlloc(allocator, item, .{});
            defer allocator.free(item_str);
            const parsed = json.parseFromSlice(SubAgentJson, allocator, item_str, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.warn("Failed to parse sub_agents entry: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();

            const j = parsed.value;
            const name = try allocator.dupe(u8, j.name);
            errdefer allocator.free(name);
            const model = try allocator.dupe(u8, j.model);
            errdefer allocator.free(model);
            const base_url = try allocator.dupe(u8, j.base_url);
            errdefer allocator.free(base_url);
            const thinking = try allocator.dupe(u8, j.thinking);
            errdefer allocator.free(thinking);
            const temperature = try allocator.dupe(u8, j.temperature);
            errdefer allocator.free(temperature);
            const url_style = try allocator.dupe(u8, j.url_style);
            errdefer allocator.free(url_style);
            const api_key = try allocator.dupe(u8, j.api_key);
            errdefer allocator.free(api_key);
            const system_prompt = try allocator.dupe(u8, j.system_prompt);
            errdefer allocator.free(system_prompt);
            const backend: []const u8 = if (j.backend.len > 0)
                try allocator.dupe(u8, j.backend)
            else
                "";
            errdefer if (backend.len > 0) allocator.free(backend);
            const config_dir: ?[]const u8 = blk: {
                const d = j.config_dir orelse break :blk null;
                if (d.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, d);
            };
            errdefer if (config_dir) |d| allocator.free(d);
            const opencode_agent: ?[]const u8 = blk: {
                const a = j.opencode_agent orelse break :blk null;
                if (a.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, a);
            };
            errdefer if (opencode_agent) |a| allocator.free(a);

            try list.append(allocator, .{
                .name = name,
                .model = model,
                .base_url = base_url,
                .thinking = thinking,
                .temperature = temperature,
                .url_style = url_style,
                .api_key = api_key,
                .system_prompt = system_prompt,
                .backend = backend,
                .config_dir = config_dir,
                .max_turns = j.max_turns,
                .opencode_agent = opencode_agent,
                .opencode_auto = j.opencode_auto,
                // Model-thinking knobs — Anthropic budget + OpenAI effort.
                // Range validation is the HTTP layer's job; this site
                // just threads the JSON-parsed values through.
                .thinking_budget_tokens = j.thinking_budget_tokens,
                .reasoning_effort = if (j.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// Deep-copy one already-parsed `SubAgentConfig` onto `allocator`.
    /// Used by the top-level → per-profile load migration and by `clone`.
    fn dupeSubAgentConfig(allocator: std.mem.Allocator, sa: SubAgentConfig) !SubAgentConfig {
        return SubAgentConfig{
            .name = try allocator.dupe(u8, sa.name),
            .model = try allocator.dupe(u8, sa.model),
            .base_url = try allocator.dupe(u8, sa.base_url),
            .thinking = try allocator.dupe(u8, sa.thinking),
            .temperature = try allocator.dupe(u8, sa.temperature),
            .url_style = try allocator.dupe(u8, sa.url_style),
            .api_key = try allocator.dupe(u8, sa.api_key),
            .system_prompt = try allocator.dupe(u8, sa.system_prompt),
            // Empty/absent stay that way so `freeSubAgentsList`'s
            // "only free non-empty" rule holds for copies too.
            .backend = if (sa.backend.len > 0) try allocator.dupe(u8, sa.backend) else "",
            .config_dir = if (sa.config_dir) |d| try allocator.dupe(u8, d) else null,
            .max_turns = sa.max_turns,
            .opencode_agent = if (sa.opencode_agent) |a| try allocator.dupe(u8, a) else null,
            .opencode_auto = sa.opencode_auto,
            .max_capacity_tokens = sa.max_capacity_tokens,
            .compaction_threshold_percent = sa.compaction_threshold_percent,
            .thinking_budget_tokens = sa.thinking_budget_tokens,
            .reasoning_effort = if (sa.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
        };
    }

    /// Plan 2026-09-04-subagents-per-profile: copy the deprecated top-level
    /// `sub_agents` into every profile whose own list is empty. No-op when
    /// the top-level list is empty.
    fn migrateTopLevelSubAgentsIntoEmptyProfiles(config: *LlmConfig) !void {
        if (config.sub_agents.len == 0) return;
        var it = config.profiles_models.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.sub_agents.len > 0) continue;
            var list = std.ArrayList(SubAgentConfig).empty;
            errdefer {
                for (list.items) |sa| {
                    config.allocator.free(sa.name);
                    config.allocator.free(sa.model);
                    config.allocator.free(sa.base_url);
                    config.allocator.free(sa.thinking);
                    config.allocator.free(sa.temperature);
                    config.allocator.free(sa.url_style);
                    config.allocator.free(sa.api_key);
                    config.allocator.free(sa.system_prompt);
                    if (sa.opencode_agent) |a| config.allocator.free(a);
                    if (sa.reasoning_effort) |re| config.allocator.free(re);
                }
                list.deinit(config.allocator);
            }
            for (config.sub_agents) |sa| {
                try list.append(config.allocator, try dupeSubAgentConfig(config.allocator, sa));
            }
            entry.value_ptr.sub_agents = try list.toOwnedSlice(config.allocator);
        }
    }

    /// Free all owned memory inside a `McpHeadersMap` (header keys + values)
    /// and then deinit the map itself. Safe to call with an empty map.
    fn freeMcpHeadersMap(map: *McpHeadersMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    /// Free all owned memory inside a `McpServersMap`:
    /// the server-name keys, the per-server `url`, and the per-server headers.
    /// Safe to call with an empty map.
    fn freeMcpServersMap(map: *McpServersMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeMcpServerConfig(entry.value_ptr, allocator);
        }
        map.deinit();
    }

    /// Parse a `McpHeadersMap` from a JSON object map.
    /// Non-string header values are silently skipped (with a warning).
    fn parseMcpHeadersMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !McpHeadersMap {
        var headers = McpHeadersMap.init(allocator);
        errdefer freeMcpHeadersMap(&headers, allocator);

        var it = obj.iterator();
        while (it.next()) |entry| {
            const header_value: []const u8 = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => {
                    std.log.info("MCP header '{s}' is not a string; skipping", .{entry.key_ptr.*});
                    continue;
                },
            };
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_dup);

            const value_dup = try allocator.dupe(u8, header_value);
            errdefer allocator.free(value_dup);

            try headers.put(key_dup, value_dup);
        }

        return headers;
    }

    /// Parse a single `McpServerConfig` from a JSON object value. Returns
    /// `null` when `value` is not an object, or when the object has neither a
    /// non-empty `url` (HTTP) nor a non-empty `command` (stdio).
    fn parseMcpServerConfig(allocator: std.mem.Allocator, value: std.json.Value) !?McpServerConfig {
        const obj = switch (value) {
            .object => |o| o,
            else => return null,
        };

        var config: McpServerConfig = .{
            .url = null,
            .headers = McpHeadersMap.init(allocator),
            .command = null,
            .args = null,
            .cwd = null,
            .enabled = true,
        };
        errdefer freeMcpServerConfig(&config, allocator);

        // ── HTTP branch: `url` field ──────────────────────────────────
        if (obj.get("url")) |url_field| {
            const url_str = switch (url_field) {
                .string => |s| s,
                else => {
                    std.log.info("MCP server 'url' is not a string; skipping", .{});
                    return null;
                },
            };
            if (url_str.len == 0) {
                std.log.info("MCP server 'url' is empty; skipping", .{});
                return null;
            }
            config.url = try allocator.dupe(u8, url_str);

            // Headers (HTTP-only).
            if (obj.get("headers")) |h| {
                if (h == .object) {
                    freeMcpHeadersMap(&config.headers, allocator);
                    config.headers = try parseMcpHeadersMap(allocator, h.object);
                }
            }
        }

        // ── stdio branch: `command` field ─────────────────────────────
        if (obj.get("command")) |cmd_field| {
            const cmd_str = switch (cmd_field) {
                .string => |s| s,
                else => {
                    std.log.info("MCP server 'command' is not a string; skipping", .{});
                    return null;
                },
            };
            if (cmd_str.len == 0) {
                std.log.info("MCP server 'command' is empty; skipping", .{});
                return null;
            }
            config.command = try allocator.dupe(u8, cmd_str);

            // Args (stdio-only, optional).
            if (obj.get("args")) |args_value| {
                const args_arr = switch (args_value) {
                    .array => |a| a,
                    else => {
                        std.log.warn("MCP server 'args' must be a JSON array of strings; skipping", .{});
                        return null;
                    },
                };
                var args_list: std.ArrayList([]const u8) = .empty;
                defer args_list.deinit(allocator);
                for (args_arr.items) |item| {
                    const s = switch (item) {
                        .string => |x| x,
                        else => continue,
                    };
                    try args_list.append(allocator, try allocator.dupe(u8, s));
                }
                config.args = try args_list.toOwnedSlice(allocator);
            }

            // cwd (stdio-only, optional).
            if (obj.get("cwd")) |cwd_field| {
                if (cwd_field == .string) {
                    config.cwd = try allocator.dupe(u8, cwd_field.string);
                }
            }
        }

        // enabled (optional, both transports). Accept only .bool —
        // absent or non-bool values keep the default true (ignored, not fatal).
        if (obj.get("enabled")) |enabled_field| {
            if (enabled_field == .bool) {
                config.enabled = enabled_field.bool;
            }
        }

        // Validate: exactly one transport present.
        const has_url = if (config.url) |u| u.len > 0 else false;
        const has_cmd = if (config.command) |c| c.len > 0 else false;
        if (has_url == has_cmd) {
            std.log.info("MCP server config needs exactly one of 'url' or 'command'; skipping", .{});
            return null;
        }

        return config;
    }

    /// Free all owned memory inside a `McpServerConfig` (but NOT the
    /// `McpServersMap` entry itself). Safe to call with partial configs.
    fn freeMcpServerConfig(cfg: *McpServerConfig, allocator: std.mem.Allocator) void {
        if (cfg.url) |u| allocator.free(u);
        if (cfg.command) |c| allocator.free(c);
        if (cfg.args) |a| {
            for (a) |arg| allocator.free(arg);
            allocator.free(a);
        }
        if (cfg.cwd) |c| allocator.free(c);
        freeMcpHeadersMap(&cfg.headers, allocator);
    }

    /// Parse a full `McpServersMap` from a JSON object map (the body of
    /// `mcp_servers` or `mcpServers`). Malformed entries are skipped with
    /// a warning rather than aborting the whole parse.
    fn parseMcpServersMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !McpServersMap {
        var servers = McpServersMap.init(allocator);
        errdefer freeMcpServersMap(&servers, allocator);

        var it = obj.iterator();
        while (it.next()) |entry| {
            const parsed = parseMcpServerConfig(allocator, entry.value_ptr.*) catch |err| {
                std.log.err("Failed to parse MCP server '{s}': {s}", .{ entry.key_ptr.*, @errorName(err) });
                return err;
            };
            const server = parsed orelse continue;

            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_dup);

            try servers.put(key_dup, server);
        }

        return servers;
    }

    pub fn deinit(self: *LlmConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);
        self.allocator.free(self.url_style);
        // Plan 2026-08-06-set-active-profile-default — owned slice was
        // duped in `init` only when non-empty.
        if (self.active_profile) |ap| self.allocator.free(ap);

        freeMcpServersMap(&self.mcp_servers, self.allocator);
        freeProfilesMap(&self.profiles_models, self.allocator);
        freeSubAgentsList(self.sub_agents, self.allocator);
        freeToolsList(self.tools, self.allocator);
        if (self.web_search) |*ws| freeWebSearchProvidersMap(ws, self.allocator);

        if (self.mcpServers_parsed) |*parsed| {
            parsed.deinit();
        }

        // Free each random sub-agent name that resolveSubAgent generated,
        // then free the tracking slice itself. The names borrow from
        // `self.allocator` and the slice header was grown via `realloc`.
        for (self.random_names) |name| {
            self.allocator.free(name);
        }
        if (self.random_names.len > 0) {
            self.allocator.free(self.random_names);
        }
    }

    pub fn clone(self: *const LlmConfig) LoadError!LlmConfig {
        var config = LlmConfig{
            .allocator = self.allocator,
            .api_key = try self.allocator.dupe(u8, self.api_key),
            .model = try self.allocator.dupe(u8, self.model),
            .base_url = try self.allocator.dupe(u8, self.base_url),
            .url_style = try self.allocator.dupe(u8, self.url_style),
            .model_compaction_size_kb = self.model_compaction_size_kb,
            .notify_on_complete = self.notify_on_complete,
            .notify_on_error = self.notify_on_error,
            .web_launch_enabled = self.web_launch_enabled,
            // Plain value copy — `SkillEvalsConfig` owns no memory, so the
            // clone needs no dupe and `deinit` needs no new free.
            .skill_evals = self.skill_evals,
            // Top-level compaction defaults — primitive copies, no
            // allocation needed (they're plain optionals).
            .max_capacity_token_model = self.max_capacity_token_model,
            .compaction_threshold_percent = self.compaction_threshold_percent,
            .compaction_llm_summary = self.compaction_llm_summary,
            // Plan 2026-08-06-set-active-profile-default — deep-dupe
            // the user-chosen default profile name (null stays null).
            .active_profile = if (self.active_profile) |ap|
                try self.allocator.dupe(u8, ap)
            else
                null,
            .mcpServers_parsed = null,
            .mcp_servers = McpServersMap.init(self.allocator),
            .profiles_models = ProfilesMap.init(self.allocator),
            .sub_agents = &.{},
        };
        errdefer {
            self.allocator.free(config.api_key);
            self.allocator.free(config.model);
            self.allocator.free(config.base_url);
            self.allocator.free(config.url_style);
            if (config.active_profile) |ap| self.allocator.free(ap);
            freeMcpServersMap(&config.mcp_servers, self.allocator);
            freeProfilesMap(&config.profiles_models, self.allocator);
            freeSubAgentsList(config.sub_agents, self.allocator);
            freeToolsList(config.tools, self.allocator);
            if (config.web_search) |*ws| freeWebSearchProvidersMap(ws, self.allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

        // Owned copy of the tools checklist (null stays null).
        config.tools = try parseToolsList(self.allocator, self.tools);

        // Owned copy of the web-search providers.
        if (self.web_search) |src| {
            var copy_map = WebSearchProvidersMap.init(self.allocator);
            errdefer freeWebSearchProvidersMap(&copy_map, self.allocator);

            var it = src.iterator();
            while (it.next()) |entry| {
                const key_dup = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(key_dup);
                var copy = entry.value_ptr.*;
                copy.url = try self.allocator.dupe(u8, copy.url);
                errdefer self.allocator.free(copy.url);
                copy.curl = try self.allocator.dupe(u8, copy.curl);
                errdefer self.allocator.free(copy.curl);
                if (copy.key) |k| {
                    copy.key = try self.allocator.dupe(u8, k);
                    errdefer self.allocator.free(copy.key.?);
                }
                if (copy.description) |d| {
                    copy.description = try self.allocator.dupe(u8, d);
                    errdefer self.allocator.free(copy.description.?);
                }
                copy_map.put(key_dup, copy) catch |err| return err;
            }
            config.web_search = copy_map;
        }

        if (self.mcpServers_parsed) |existing| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(self.allocator, existing.value, .{}) catch {
                return error.InvalidJson;
            };
            defer self.allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, self.allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            config.mcpServers_parsed = reparsed;
        }

        // Deep-copy the typed MCP servers map. Each entry is cloned field
        // by field — only the transport actually in use (url OR command)
        // has its strings duped; the other's slots stay null.
        var mcp_it = self.mcp_servers.iterator();
        while (mcp_it.next()) |entry| {
            const src = entry.value_ptr.*;

            var cloned: McpServerConfig = .{
                .url = null,
                .headers = McpHeadersMap.init(self.allocator),
                .command = null,
                .args = null,
                .cwd = null,
                .enabled = src.enabled,
            };
            errdefer freeMcpServerConfig(&cloned, self.allocator);

            var h_it = src.headers.iterator();
            while (h_it.next()) |h| {
                const k = try self.allocator.dupe(u8, h.key_ptr.*);
                errdefer self.allocator.free(k);
                const v = try self.allocator.dupe(u8, h.value_ptr.*);
                errdefer self.allocator.free(v);
                try cloned.headers.put(k, v);
            }

            if (src.url) |u| cloned.url = try self.allocator.dupe(u8, u);
            if (src.command) |c| cloned.command = try self.allocator.dupe(u8, c);
            if (src.cwd) |c| cloned.cwd = try self.allocator.dupe(u8, c);
            if (src.args) |src_args| {
                const args_dup = try self.allocator.alloc([]const u8, src_args.len);
                errdefer self.allocator.free(args_dup);
                for (src_args, 0..) |a, i| {
                    args_dup[i] = try self.allocator.dupe(u8, a);
                }
                cloned.args = args_dup;
            }

            const key_dup = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_dup);

            try config.mcp_servers.put(key_dup, cloned);
        }

        // Clone all profiles.
        var it = self.profiles_models.iterator();
        while (it.next()) |entry| {
            const owned_sub_agents = blk: {
                if (entry.value_ptr.sub_agents.len == 0) break :blk @as(SubAgentsList, &.{});
                var plist = std.ArrayList(SubAgentConfig).empty;
                errdefer {
                    for (plist.items) |sa| {
                        self.allocator.free(sa.name);
                        self.allocator.free(sa.model);
                        self.allocator.free(sa.base_url);
                        self.allocator.free(sa.thinking);
                        self.allocator.free(sa.temperature);
                        self.allocator.free(sa.url_style);
                        self.allocator.free(sa.api_key);
                        self.allocator.free(sa.system_prompt);
                        if (sa.reasoning_effort) |re| self.allocator.free(re);
                    }
                    plist.deinit(self.allocator);
                }
                for (entry.value_ptr.sub_agents) |sa| {
                    try plist.append(self.allocator, try dupeSubAgentConfig(self.allocator, sa));
                }
                break :blk try plist.toOwnedSlice(self.allocator);
            };
            errdefer freeSubAgentsList(owned_sub_agents, self.allocator);
            try addProfile(
                &config.profiles_models,
                entry.key_ptr.*,
                ProfileJson{
                    .model = entry.value_ptr.model,
                    .base_url = entry.value_ptr.base_url,
                    .thinking = entry.value_ptr.thinking,
                    .temperature = entry.value_ptr.temperature,
                    .api_key = entry.value_ptr.api_key,
                    .url_style = entry.value_ptr.url_style,
                    .backend = entry.value_ptr.backend,
                    .config_dir = entry.value_ptr.config_dir,
                    .max_turns = entry.value_ptr.max_turns,
                    .opencode_agent = entry.value_ptr.opencode_agent,
                    .opencode_auto = entry.value_ptr.opencode_auto,
                    .sub_agents = null,
                },
                self.allocator,
            );
            // `addProfile` always sets an empty list (it only parses
            // from `ProfileJson`); swap in the deep-copied list.
            if (owned_sub_agents.len > 0) {
                const got = config.profiles_models.getPtr(entry.key_ptr.*).?;
                freeSubAgentsList(got.sub_agents, config.allocator);
                got.sub_agents = owned_sub_agents;
            } else {
                if (owned_sub_agents.len == 0) {
                    // `toOwnedSlice` on an empty list may still allocate;
                    // `freeSubAgentsList` is safe on any slice.
                    freeSubAgentsList(owned_sub_agents, self.allocator);
                }
            }
        }

        // Deep-copy top-level sub_agents into a freshly allocated slice.
        var sub_agents_list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (sub_agents_list.items) |sa| {
                self.allocator.free(sa.name);
                self.allocator.free(sa.model);
                self.allocator.free(sa.base_url);
                self.allocator.free(sa.thinking);
                self.allocator.free(sa.temperature);
                self.allocator.free(sa.url_style);
                self.allocator.free(sa.api_key);
                self.allocator.free(sa.system_prompt);
                if (sa.backend.len > 0) self.allocator.free(sa.backend);
                if (sa.config_dir) |d| self.allocator.free(d);
                if (sa.reasoning_effort) |re| self.allocator.free(re);
            }
            sub_agents_list.deinit(self.allocator);
        }
        for (self.sub_agents) |sa| {
            try sub_agents_list.append(self.allocator, try dupeSubAgentConfig(self.allocator, sa));
        }
        config.sub_agents = try sub_agents_list.toOwnedSlice(self.allocator);

        return config;
    }

    pub fn validate(self: *const LlmConfig) LoadError!void {
        // The TRANSPORT decides which fields are required.
        const backend = self.effectiveBackend();

        if (self.model.len == 0) {
            std.log.warn("Missing required field: model", .{});
            return error.MissingRequiredField;
        }
        if (std.mem.eql(u8, backend, Backend.claude_code)) return;
        if (std.mem.eql(u8, backend, Backend.opencode)) return;
        if (self.api_key.len == 0) {
            std.log.warn("Missing required field: api_key", .{});
            return error.MissingRequiredField;
        }
        if (self.base_url.len == 0) {
            std.log.warn("Missing required field: base_url", .{});
            return error.MissingRequiredField;
        }
    }

    /// The transport the ACTIVE profile selects, defaulting to `"http"`.
    pub fn effectiveBackend(self: *const LlmConfig) []const u8 {
        const p = self.resolveSessionProfileCompat("") orelse return Backend.http;
        if (p.backend.len == 0) return Backend.http;
        return p.backend;
    }

    /// Convenience accessor — returns the live json.Value or null.
    pub fn mcpServers(self: *const LlmConfig) ?json.Value {
        return if (self.mcpServers_parsed) |p| p.value else null;
    }

    /// Returns true if any MCP servers are configured.
    pub fn hasMcpServers(self: *const LlmConfig) bool {
        return self.mcp_servers.count() > 0;
    }

    /// Returns true if a server with the given name is configured.
    /// Lookup is by direct hash match on the server name key.
    pub fn hasMcpServer(self: *const LlmConfig, name: []const u8) bool {
        return self.mcp_servers.contains(name);
    }

    /// Get the typed configuration for a single MCP server by name. Returns
    /// null when no server with that name is configured.
    pub fn mcpServerConfig(self: *const LlmConfig, name: []const u8) ?McpServerConfig {
        const entry = self.mcp_servers.getEntry(name) orelse return null;
        return entry.value_ptr.*;
    }

    /// Get the URL for a single MCP server, or null when not configured.
    /// The returned slice borrows from `self` (do not outlive the config).
    pub fn mcpServerUrl(self: *const LlmConfig, name: []const u8) ?[]const u8 {
        return if (self.mcpServerConfig(name)) |c| c.url else null;
    }

    /// Returns the number of configured MCP servers.
    pub fn mcpServerCount(self: *const LlmConfig) u32 {
        return @intCast(self.mcp_servers.count());
    }

    /// Input for `addMcpServerStdio` — the stdio-only transport variant
    /// (HTTP follows in a sibling task). All string fields are borrowed;
    /// the primitive deep-copies them into the live `mcp_servers` map.
    pub const AddMcpServerStdioInput = struct {
        /// The server name (key in `mcp_servers`). Must be non-empty and
        /// must not collide with an existing server. Trailing whitespace is
        /// NOT trimmed — the caller is responsible for the exact key.
        name: []const u8,
        /// The command to spawn. Must be non-empty (an empty command would
        /// never reach the `parseMcpServerConfig` validity check anyway).
        command: []const u8,
        /// Optional argv after `command`. `null` means no args. Each entry
        /// is deep-copied into the new `McpServerConfig.args` slice.
        args: ?[]const []const u8 = null,
        /// Optional working directory. `null` means inherit from the parent.
        cwd: ?[]const u8 = null,
    };

    /// Add a new stdio MCP server to the live config in-place.
    pub fn addMcpServerStdio(
        self: *LlmConfig,
        input: AddMcpServerStdioInput,
    ) !void {
        // ── 1. Validate ────────────────────────────────────────────────────
        if (input.name.len == 0) return error.InvalidName;
        if (input.command.len == 0) return error.InvalidCommand;
        if (self.mcp_servers.contains(input.name)) return error.DuplicateServer;

        // ── 2. Build the new typed entry ───────────────────────────────────
        var entry: McpServerConfig = .{
            .url = null,
            .headers = McpHeadersMap.init(self.allocator),
            .command = try self.allocator.dupe(u8, input.command),
            .args = null,
            .cwd = if (input.cwd) |c| try self.allocator.dupe(u8, c) else null,
            .enabled = true,
        };
        errdefer freeMcpServerConfig(&entry, self.allocator);

        if (input.args) |src_args| {
            const args_dup = try self.allocator.alloc([]const u8, src_args.len);
            errdefer self.allocator.free(args_dup);
            for (src_args, 0..) |a, i| {
                args_dup[i] = try self.allocator.dupe(u8, a);
            }
            entry.args = args_dup;
        }

        // ── 3.
        const _key_dup = blk: {
            const k = try self.allocator.dupe(u8, input.name);
            errdefer self.allocator.free(k);
            try self.mcp_servers.put(k, entry);
            // Transfer ownership of the entry's heap-allocated fields to the
            // map.
            entry = .{
                .url = null,
                .headers = McpHeadersMap.init(self.allocator),
                .command = null,
                .args = null,
                .cwd = null,
                .enabled = true,
            };
            break :blk k;
        };
        _ = _key_dup; // owned by the map now; suppress unused-constant warning

        // ── 4.
        try rebuildMcpServersParsed(self);
    }

    /// Input for `addMcpServerHttp` — the HTTP transport variant.
    /// All string fields are borrowed; the primitive deep-copies them.
    pub const AddMcpServerHttpInput = struct {
        /// The server name (key in `mcp_servers`). Must be non-empty and
        /// must not collide with an existing server.
        name: []const u8,
        /// The MCP server URL. Must be non-empty.
        url: []const u8,
        /// Optional request headers (e.g. `Authorization`). Each entry's
        /// `name` + `value` are deep-copied into the new headers map.
        headers: ?[]const McpHeaderInput = null,
    };

    /// One header entry for `addMcpServerHttp` / `editMcpServer`.
    pub const McpHeaderInput = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Add a new HTTP MCP server to the live config in-place. The stdio
    /// sibling is `addMcpServerStdio`; both mutate the typed map AND
    /// rebuild `mcpServers_parsed`. Errors: InvalidName, InvalidUrl,
    pub fn addMcpServerHttp(
        self: *LlmConfig,
        input: AddMcpServerHttpInput,
    ) !void {
        if (input.name.len == 0) return error.InvalidName;
        if (input.url.len == 0) return error.InvalidUrl;
        if (self.mcp_servers.contains(input.name)) return error.DuplicateServer;

        var entry: McpServerConfig = .{
            .url = try self.allocator.dupe(u8, input.url),
            .headers = McpHeadersMap.init(self.allocator),
            .command = null,
            .args = null,
            .cwd = null,
            .enabled = true,
        };
        errdefer freeMcpServerConfig(&entry, self.allocator);

        if (input.headers) |hdrs| {
            for (hdrs) |h| {
                if (h.name.len == 0) continue;
                const k = try self.allocator.dupe(u8, h.name);
                errdefer self.allocator.free(k);
                const v = try self.allocator.dupe(u8, h.value);
                errdefer self.allocator.free(v);
                try entry.headers.put(k, v);
            }
        }

        const _key_dup = blk: {
            const k = try self.allocator.dupe(u8, input.name);
            errdefer self.allocator.free(k);
            try self.mcp_servers.put(k, entry);
            // Ownership transferred to the map — reset the local so the
            // errdefer above cannot double-free the shared strings.
            entry = .{
                .url = null,
                .headers = McpHeadersMap.init(self.allocator),
                .command = null,
                .args = null,
                .cwd = null,
                .enabled = true,
            };
            break :blk k;
        };
        _ = _key_dup;

        try rebuildMcpServersParsed(self);
    }

    /// Input for `editMcpServer` — a partial update of an existing
    /// server. Every field is optional; a null field means "leave the
    /// stored value alone". `transport` REPLACES the entry's transport.
    pub const EditMcpServerInput = struct {
        /// The server to edit. Must already exist.
        name: []const u8,
        /// New transport. When present, the entry is rebuilt from the
        /// supplied transport-specific fields (a stdio→http switch
        /// drops `command`/`args`/`cwd`, and vice versa).
        transport: ?[]const u8 = null,
        /// stdio command. Required when `transport == "stdio"`.
        command: ?[]const u8 = null,
        /// stdio argv. `null` leaves the stored value; an empty slice
        /// clears it.
        args: ?[]const []const u8 = null,
        /// HTTP URL. Required when `transport == "http"`.
        url: ?[]const u8 = null,
        /// HTTP headers. `null` leaves the stored map; an empty slice
        /// clears it.
        headers: ?[]const McpHeaderInput = null,
        /// Enable/disable toggle. `null` leaves the stored flag.
        enabled: ?bool = null,
    };

    /// Edit an existing MCP server in-place. Mutates the typed map AND
    /// rebuilds `mcpServers_parsed`. A transport switch is a full
    /// rebuild: the OLD transport's fields are dropped. Errors:
    pub fn editMcpServer(
        self: *LlmConfig,
        input: EditMcpServerInput,
    ) !void {
        if (input.name.len == 0) return error.InvalidName;
        const entry_ptr = self.mcp_servers.getPtr(input.name) orelse return error.ServerNotFound;

        // Resolve the target transport first: an explicit `transport`
        // wins, otherwise keep whatever the stored entry already is.
        const target: McpServerConfig.Transport = blk: {
            if (input.transport) |t| {
                if (std.mem.eql(u8, t, "stdio")) break :blk .stdio;
                if (std.mem.eql(u8, t, "http")) break :blk .http;
                return error.InvalidTransport;
            }
            break :blk entry_ptr.transport();
        };

        // Build the replacement entry, then swap it in. Building first
        // means a validation failure leaves the stored entry untouched.
        var next: McpServerConfig = .{
            .url = null,
            .headers = McpHeadersMap.init(self.allocator),
            .command = null,
            .args = null,
            .cwd = null,
            .enabled = if (input.enabled) |e| e else entry_ptr.enabled,
        };
        errdefer freeMcpServerConfig(&next, self.allocator);

        switch (target) {
            .stdio => {
                const cmd = input.command orelse entry_ptr.command orelse return error.InvalidCommand;
                if (cmd.len == 0) return error.InvalidCommand;
                next.command = try self.allocator.dupe(u8, cmd);
                if (input.args) |src| {
                    if (src.len == 0) {
                        next.args = null;
                    } else {
                        const dup = try self.allocator.alloc([]const u8, src.len);
                        errdefer self.allocator.free(dup);
                        for (src, 0..) |a, i| dup[i] = try self.allocator.dupe(u8, a);
                        next.args = dup;
                    }
                } else if (entry_ptr.args) |old| {
                    const dup = try self.allocator.alloc([]const u8, old.len);
                    errdefer self.allocator.free(dup);
                    for (old, 0..) |a, i| dup[i] = try self.allocator.dupe(u8, a);
                    next.args = dup;
                }
                // `cwd` is not editable through the agent tool (the
                // parameter was dropped from `add_mcp_server` on
                // 2026-10-14), so a stdio entry keeps its stored value.
                if (entry_ptr.cwd) |c| next.cwd = try self.allocator.dupe(u8, c);
            },
            .http => {
                const url = input.url orelse entry_ptr.url orelse return error.InvalidUrl;
                if (url.len == 0) return error.InvalidUrl;
                next.url = try self.allocator.dupe(u8, url);
                if (input.headers) |hdrs| {
                    for (hdrs) |h| {
                        if (h.name.len == 0) continue;
                        const k = try self.allocator.dupe(u8, h.name);
                        errdefer self.allocator.free(k);
                        const v = try self.allocator.dupe(u8, h.value);
                        errdefer self.allocator.free(v);
                        try next.headers.put(k, v);
                    }
                } else {
                    // Carry the stored headers over.
                    var it = entry_ptr.headers.iterator();
                    while (it.next()) |h| {
                        const k = try self.allocator.dupe(u8, h.key_ptr.*);
                        errdefer self.allocator.free(k);
                        const v = try self.allocator.dupe(u8, h.value_ptr.*);
                        errdefer self.allocator.free(v);
                        try next.headers.put(k, v);
                    }
                }
            },
        }

        // Swap: free the old payload, install the new one. The map KEY
        // is untouched — the server name is the identity and is not
        // editable here (a rename is a delete + add).
        freeMcpServerConfig(entry_ptr, self.allocator);
        entry_ptr.* = next;

        try rebuildMcpServersParsed(self);
    }

    /// Remove an MCP server from the live config in-place. Mutates the
    /// typed map AND rebuilds `mcpServers_parsed`. Errors: InvalidName,
    /// ServerNotFound.
    pub fn removeMcpServer(self: *LlmConfig, name: []const u8) !void {
        if (name.len == 0) return error.InvalidName;
        const kv = self.mcp_servers.fetchRemove(name) orelse return error.ServerNotFound;
        self.allocator.free(kv.key);
        var removed = kv.value;
        freeMcpServerConfig(&removed, self.allocator);
        try rebuildMcpServersParsed(self);
    }

    /// Serialize the typed `mcp_servers` map back into `mcpServers_parsed`.
    /// Called by `addMcpServerStdio` after each insert; safe to call when
    /// `mcpServers_parsed` is null (re-builds from scratch).
    fn rebuildMcpServersParsed(self: *LlmConfig) !void {
        const allocator = self.allocator;
        var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer new_obj.deinit(allocator);

        var it = self.mcp_servers.iterator();
        while (it.next()) |entry| {
            const server_name = entry.key_ptr.*;
            const cfg = entry.value_ptr.*;
            var server_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer server_obj.deinit(allocator);

            if (cfg.url) |u| {
                try server_obj.put(allocator, "url", .{ .string = try allocator.dupe(u8, u) });
            }
            if (cfg.headers.count() > 0) {
                var hdr_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer hdr_obj.deinit(allocator);
                var h_it = cfg.headers.iterator();
                while (h_it.next()) |h| {
                    const k = try allocator.dupe(u8, h.key_ptr.*);
                    errdefer allocator.free(k);
                    const v = try allocator.dupe(u8, h.value_ptr.*);
                    errdefer allocator.free(v);
                    try hdr_obj.put(allocator, k, .{ .string = v });
                }
                try server_obj.put(allocator, "headers", .{ .object = hdr_obj });
            }
            if (cfg.command) |c| {
                try server_obj.put(allocator, "command", .{ .string = try allocator.dupe(u8, c) });
            }
            if (cfg.args) |a| {
                // Transfer ownership: `args_arr` (and its duped string items)
                // becomes part of the JSON tree.
                var args_arr = json.Array.init(allocator);
                for (a) |arg| {
                    try args_arr.append(.{ .string = try allocator.dupe(u8, arg) });
                }
                try server_obj.put(allocator, "args", .{ .array = args_arr });
            }
            if (cfg.cwd) |c| {
                try server_obj.put(allocator, "cwd", .{ .string = try allocator.dupe(u8, c) });
            }
            // Omit-when-true: only disabled servers serialize `enabled`.
            if (!cfg.enabled) {
                try server_obj.put(allocator, "enabled", .{ .bool = false });
            }

            const name_dup = try allocator.dupe(u8, server_name);
            errdefer allocator.free(name_dup);
            try new_obj.put(allocator, name_dup, .{ .object = server_obj });
        }

        // Parse the new object map as `mcpServers_parsed`.
        const serialized = try std.json.Stringify.valueAlloc(allocator, json.Value{ .object = new_obj }, .{});
        defer allocator.free(serialized);
        const reparsed = try json.parseFromSlice(json.Value, allocator, serialized, .{
            .ignore_unknown_fields = true,
        });
        errdefer reparsed.deinit();

        // Free the source tree manually. ObjectMap.deinit only frees the hash
        // map structure — it does NOT recurse into values or free the outer
        // keys.
        freeNewObjDeep(allocator, &new_obj);

        // Free the old mcpServers_parsed (its underlying ObjectMap is now
        // orphaned — we own a fresh one inside `reparsed`). Matches the
        // deinit pattern in `LlmConfig.deinit`.
        if (self.mcpServers_parsed) |*old| old.deinit();
        self.mcpServers_parsed = reparsed;
    }

    /// Free a `new_obj` tree built by `rebuildMcpServersParsed`.
    fn freeNewObjDeep(allocator: std.mem.Allocator, new_obj: *json.ObjectMap) void {
        var it = new_obj.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            freeServerObjDeep(allocator, &kv.value_ptr.object);
        }
        new_obj.deinit(allocator);
    }

    /// Free a single server's ObjectMap. The KEYS are string literals
    /// ("command", "args", "url", "cwd", "headers", "enabled") — DO NOT
    /// free them. The VALUES own memory (duped strings, headers sub-map).
    fn freeServerObjDeep(allocator: std.mem.Allocator, server_obj: *json.ObjectMap) void {
        var it = server_obj.iterator();
        while (it.next()) |kv| {
            freeServerObjValue(allocator, &kv.value_ptr.*);
        }
        server_obj.deinit(allocator);
    }

    /// Free one value out of a server_obj entry. The captured pattern
    /// `|*arr|` is fragile because switch captures are immutable, so we
    /// pass a pointer to the Value union and dispatch on the active tag.
    fn freeServerObjValue(allocator: std.mem.Allocator, value_ptr: *json.Value) void {
        switch (value_ptr.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| {
                    if (item.* == .string) {
                        allocator.free(item.string);
                    }
                }
                arr.deinit();
            },
            .object => freeHeadersObjDeep(allocator, &value_ptr.object),
            else => {},
        }
    }

    /// Free the headers sub-map. Keys + values are BOTH duped strings.
    fn freeHeadersObjDeep(allocator: std.mem.Allocator, hdr_obj: *json.ObjectMap) void {
        var it = hdr_obj.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.string);
        }
        hdr_obj.deinit(allocator);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Inline tests for `addMcpServerStdio` — plan 2026-08-28-add-mcp-server-agent-tool
    // ─────────────────────────────────────────────────────────────────────

    /// Build a minimal `LlmConfig` for the `addMcpServerStdio` tests. Only
    /// the fields touched by the primitive are wired up; the rest are
    /// sentinel values that `deinit()` doesn't free.
    fn addMcpServerStdioFixture(allocator: std.mem.Allocator) !LlmConfig {
        return .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, ""),
            .model = try allocator.dupe(u8, ""),
            .base_url = try allocator.dupe(u8, ""),
            .url_style = try allocator.dupe(u8, "openai"),
            .model_compaction_size_kb = 100,
            .retry_delay_ms = 0,
            .max_capacity_token_model = null,
            .compaction_threshold_percent = null,
            .active_profile = null,
            .mcpServers_parsed = null,
            .mcp_servers = LlmConfig.McpServersMap.init(allocator),
            .profiles_models = LlmConfig.ProfilesMap.init(allocator),
            .sub_agents = &.{},
            .random_names = &.{},
        };
    }

    test "addMcpServerStdio: valid stdio entry persists command+args+cwd" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "hello",
            .command = "mcp-hello-world",
            .args = &.{ "--port", "3001" },
            .cwd = "/opt/mcp",
        });

        // Typed map populated with deep-copied strings.
        try std.testing.expect(cfg.hasMcpServer("hello"));
        const server = cfg.mcpServerConfig("hello").?;
        try std.testing.expectEqualStrings("mcp-hello-world", server.command.?);
        try std.testing.expectEqualStrings("/opt/mcp", server.cwd.?);
        try std.testing.expectEqual(@as(usize, 2), server.args.?.len);
        try std.testing.expectEqualStrings("--port", server.args.?[0]);
        try std.testing.expectEqualStrings("3001", server.args.?[1]);
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());

        // mcpServers_parsed rebuilt — fetchable via mcpServers() accessor.
        try std.testing.expect(cfg.mcpServers() != null);
        const mcp_val = cfg.mcpServers().?;
        const obj = mcp_val.object;
        try std.testing.expect(obj.get("hello") != null);
        const hello_obj = obj.get("hello").?.object;
        try std.testing.expectEqualStrings("mcp-hello-world", hello_obj.get("command").?.string);
        try std.testing.expectEqualStrings("/opt/mcp", hello_obj.get("cwd").?.string);
    }

    test "addMcpServerStdio: minimal stdio entry (command only, no args/cwd)" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "bare",
            .command = "mcp-server",
        });

        const server = cfg.mcpServerConfig("bare").?;
        try std.testing.expectEqualStrings("mcp-server", server.command.?);
        try std.testing.expect(server.args == null);
        try std.testing.expect(server.cwd == null);
        // Transport discriminator returns stdio when `command` is set.
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());
    }

    test "addMcpServerStdio: empty name returns InvalidName" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        const result = cfg.addMcpServerStdio(.{
            .name = "",
            .command = "x",
        });
        try std.testing.expectError(error.InvalidName, result);
        try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
    }

    test "addMcpServerStdio: empty command returns InvalidCommand" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        const result = cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "",
        });
        try std.testing.expectError(error.InvalidCommand, result);
        try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
    }

    test "addMcpServerStdio: duplicate name returns DuplicateServer and preserves prior entry" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "first-cmd",
            .args = &.{"a"},
        });
        // Second insert with the same name MUST fail — the typed map and
        // mcpServers_parsed are unchanged.
        const result = cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "second-cmd",
            .args = &.{"b"},
        });
        try std.testing.expectError(error.DuplicateServer, result);
        try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.count());
        const server = cfg.mcpServerConfig("ctx").?;
        try std.testing.expectEqualStrings("first-cmd", server.command.?);
        try std.testing.expectEqualStrings("a", server.args.?[0]);
    }

    test "addMcpServerStdio: preserves existing servers after a second add" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{ .name = "alpha", .command = "cmd-a" });
        try cfg.addMcpServerStdio(.{ .name = "beta", .command = "cmd-b" });
        try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.count());

        const alpha = cfg.mcpServerConfig("alpha").?;
        try std.testing.expectEqualStrings("cmd-a", alpha.command.?);
        const beta = cfg.mcpServerConfig("beta").?;
        try std.testing.expectEqualStrings("cmd-b", beta.command.?);

        // mcpServers_parsed has BOTH entries.
        const obj = cfg.mcpServers().?.object;
        try std.testing.expect(obj.get("alpha") != null);
        try std.testing.expect(obj.get("beta") != null);
    }

    test "addMcpServerStdio: rebuilds mcpServers_parsed from scratch when previously null" {
        // Guards the "first MCP server ever" path — mcpServers_parsed was
        // never populated, so rebuildMcpServersParsed must create a fresh
        // ObjectMap rather than dereferencing the null one.
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try std.testing.expect(cfg.mcpServers_parsed == null);
        try cfg.addMcpServerStdio(.{ .name = "first", .command = "cmd-1" });

        try std.testing.expect(cfg.mcpServers_parsed != null);
        try std.testing.expect(cfg.mcpServers() != null);
        try std.testing.expectEqualStrings("cmd-1", cfg.mcpServers().?.object.get("first").?.object.get("command").?.string);
    }

    test "addMcpServerStdio: cloned strings are independent (mutating input doesn't leak)" {
        // The primitive deep-copies every string. We mutate the source
        // slices after the call and assert the typed map's values are
        // unchanged — guards against accidental shallow-copy regression.
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        var cmd_buf: [16]u8 = undefined;
        const cmd_src = std.fmt.bufPrint(&cmd_buf, "initial", .{}) catch @panic("bufPrint failed formatting the addMcpServerStdio command fixture");
        var cwd_buf: [16]u8 = undefined;
        const cwd_src = std.fmt.bufPrint(&cwd_buf, "/initial", .{}) catch @panic("bufPrint failed formatting the addMcpServerStdio cwd fixture");

        try cfg.addMcpServerStdio(.{
            .name = "leak-guard",
            .command = cmd_src,
            .cwd = cwd_src,
        });

        // Mutate the source buffers in-place — the typed map must still
        // hold the original bytes (deep copy semantics).
        @memcpy(cmd_buf[0.."MUTATED-MUT".len], "MUTATED-MUT");
        @memcpy(cwd_buf[0.."/MUTATED-MU".len], "/MUTATED-MU");

        const server = cfg.mcpServerConfig("leak-guard").?;
        try std.testing.expectEqualStrings("initial", server.command.?);
        try std.testing.expectEqualStrings("/initial", server.cwd.?);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Inline tests for addMcpServerHttp / editMcpServer / removeMcpServer
    // ─────────────────────────────────────────────────────────────────────

    test "addMcpServerHttp: valid entry persists url + headers" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerHttp(.{
            .name = "ctx7",
            .url = "https://mcp.context7.com/mcp",
            .headers = &.{
                .{ .name = "Authorization", .value = "Bearer tok" },
            },
        });

        try std.testing.expect(cfg.hasMcpServer("ctx7"));
        const server = cfg.mcpServerConfig("ctx7").?;
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.http, server.transport());
        try std.testing.expect(server.isValid());
        try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", server.url.?);
        try std.testing.expectEqual(@as(usize, 1), server.headers.count());
        try std.testing.expectEqualStrings("Bearer tok", server.headers.get("Authorization").?);
        // The JSON mirror carries the same shape the parser accepts.
        const mirror = cfg.mcpServers().?.object.get("ctx7").?.object;
        try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", mirror.get("url").?.string);
        try std.testing.expectEqualStrings("Bearer tok", mirror.get("headers").?.object.get("Authorization").?.string);
    }

    test "addMcpServerHttp: minimal entry (url only, no headers)" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerHttp(.{ .name = "bare", .url = "https://x.test/mcp" });

        const server = cfg.mcpServerConfig("bare").?;
        try std.testing.expectEqual(@as(usize, 0), server.headers.count());
        // Empty headers are omitted from the mirror (parse convention).
        try std.testing.expect(cfg.mcpServers().?.object.get("bare").?.object.get("headers") == null);
    }

    test "addMcpServerHttp: empty name / empty url / duplicate are rejected" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try std.testing.expectError(error.InvalidName, cfg.addMcpServerHttp(.{ .name = "", .url = "https://x" }));
        try std.testing.expectError(error.InvalidUrl, cfg.addMcpServerHttp(.{ .name = "a", .url = "" }));

        try cfg.addMcpServerHttp(.{ .name = "dup", .url = "https://x.test/mcp" });
        try std.testing.expectError(error.DuplicateServer, cfg.addMcpServerHttp(.{ .name = "dup", .url = "https://y.test/mcp" }));
        // The first entry survives the rejected second add.
        try std.testing.expectEqualStrings("https://x.test/mcp", cfg.mcpServerConfig("dup").?.url.?);
    }

    test "addMcpServerHttp: coexists with a stdio server" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{ .name = "local", .command = "mcp-hello-world" });
        try cfg.addMcpServerHttp(.{ .name = "remote", .url = "https://x.test/mcp" });

        try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.count());
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, cfg.mcpServerConfig("local").?.transport());
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.http, cfg.mcpServerConfig("remote").?.transport());
    }

    test "editMcpServer: stdio command + args update in place" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "s", .command = "old", .args = &.{"--a"} });

        try cfg.editMcpServer(.{ .name = "s", .command = "new", .args = &.{ "--b", "--c" } });

        const server = cfg.mcpServerConfig("s").?;
        try std.testing.expectEqualStrings("new", server.command.?);
        try std.testing.expectEqual(@as(usize, 2), server.args.?.len);
        try std.testing.expectEqualStrings("--b", server.args.?[0]);
        try std.testing.expectEqualStrings("--c", server.args.?[1]);
        // Mirror agrees.
        const mirror = cfg.mcpServers().?.object.get("s").?.object;
        try std.testing.expectEqualStrings("new", mirror.get("command").?.string);
    }

    test "editMcpServer: http url + headers update in place" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerHttp(.{ .name = "h", .url = "https://old.test/mcp" });

        try cfg.editMcpServer(.{
            .name = "h",
            .url = "https://new.test/mcp",
            .headers = &.{.{ .name = "Authorization", .value = "Bearer new" }},
        });

        const server = cfg.mcpServerConfig("h").?;
        try std.testing.expectEqualStrings("https://new.test/mcp", server.url.?);
        try std.testing.expectEqualStrings("Bearer new", server.headers.get("Authorization").?);
    }

    test "editMcpServer: omitted fields keep their stored values" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "s", .command = "keep", .args = &.{"--keep"} });

        // Only flip `enabled` — command + args must survive untouched.
        try cfg.editMcpServer(.{ .name = "s", .enabled = false });

        const server = cfg.mcpServerConfig("s").?;
        try std.testing.expect(!server.enabled);
        try std.testing.expectEqualStrings("keep", server.command.?);
        try std.testing.expectEqualStrings("--keep", server.args.?[0]);
    }

    test "editMcpServer: stdio to http switch drops the stdio fields" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd", .args = &.{"--a"} });

        try cfg.editMcpServer(.{ .name = "s", .transport = "http", .url = "https://x.test/mcp" });

        const server = cfg.mcpServerConfig("s").?;
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.http, server.transport());
        try std.testing.expect(server.isValid());
        try std.testing.expect(server.command == null);
        try std.testing.expect(server.args == null);
        try std.testing.expectEqualStrings("https://x.test/mcp", server.url.?);
    }

    test "editMcpServer: http to stdio switch drops the http fields" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerHttp(.{
            .name = "h",
            .url = "https://x.test/mcp",
            .headers = &.{.{ .name = "Authorization", .value = "Bearer t" }},
        });

        try cfg.editMcpServer(.{ .name = "h", .transport = "stdio", .command = "mcp-hello-world" });

        const server = cfg.mcpServerConfig("h").?;
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());
        try std.testing.expect(server.isValid());
        try std.testing.expect(server.url == null);
        try std.testing.expectEqual(@as(usize, 0), server.headers.count());
        try std.testing.expectEqualStrings("mcp-hello-world", server.command.?);
    }

    test "editMcpServer: unknown name / bad transport / missing field are rejected" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd" });

        try std.testing.expectError(error.ServerNotFound, cfg.editMcpServer(.{ .name = "nope", .command = "x" }));
        try std.testing.expectError(error.InvalidTransport, cfg.editMcpServer(.{ .name = "s", .transport = "sse" }));
        // Switching to http without a url leaves the stored entry intact.
        try std.testing.expectError(error.InvalidUrl, cfg.editMcpServer(.{ .name = "s", .transport = "http" }));
        try std.testing.expectEqualStrings("cmd", cfg.mcpServerConfig("s").?.command.?);
        // Switching to stdio with an empty command is refused too.
        try std.testing.expectError(error.InvalidCommand, cfg.editMcpServer(.{ .name = "s", .transport = "stdio", .command = "" }));
        try std.testing.expectEqualStrings("cmd", cfg.mcpServerConfig("s").?.command.?);
    }

    test "editMcpServer: empty args slice clears the stored argv" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd", .args = &.{"--a", "--b"} });

        try cfg.editMcpServer(.{ .name = "s", .args = &.{} });

        const server = cfg.mcpServerConfig("s").?;
        try std.testing.expect(server.args == null);
        try std.testing.expect(cfg.mcpServers().?.object.get("s").?.object.get("args") == null);
    }

    test "removeMcpServer: drops the entry and rebuilds the mirror" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "a", .command = "cmd-a" });
        try cfg.addMcpServerHttp(.{ .name = "b", .url = "https://x.test/mcp" });

        try cfg.removeMcpServer("a");

        try std.testing.expect(!cfg.hasMcpServer("a"));
        try std.testing.expect(cfg.hasMcpServer("b"));
        try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.count());
        // The JSON mirror no longer carries the removed key.
        try std.testing.expect(cfg.mcpServers().?.object.get("a") == null);
        try std.testing.expect(cfg.mcpServers().?.object.get("b") != null);
    }

    test "removeMcpServer: removing the last server leaves an empty mirror" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "only", .command = "cmd" });

        try cfg.removeMcpServer("only");

        try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
        try std.testing.expect(!cfg.hasMcpServers());
        // An empty object, not null — `mcpServers()` stays well-formed.
        try std.testing.expect(cfg.mcpServers().? == .object);
        try std.testing.expectEqual(@as(usize, 0), cfg.mcpServers().?.object.count());
    }

    test "removeMcpServer: unknown name / empty name are rejected" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();
        try cfg.addMcpServerStdio(.{ .name = "keep", .command = "cmd" });

        try std.testing.expectError(error.ServerNotFound, cfg.removeMcpServer("nope"));
        try std.testing.expectError(error.InvalidName, cfg.removeMcpServer(""));
        try std.testing.expect(cfg.hasMcpServer("keep"));
    }

    /// Look up a profile by name (the key in `profiles_models`). Returns null when
    /// not configured. The returned `LlmProfile` borrows from `self` — the lifetime
    /// is tied to this `LlmConfig` (do not outlive the config).
    pub fn getProfile(self: *const LlmConfig, name: []const u8) ?LlmProfile {
        const entry = self.profiles_models.getEntry(name) orelse return null;
        return entry.value_ptr.*;
    }

    /// Returns true if a profile with the given name exists and has a non-empty
    /// `model` field. Use this before calling `getProfile` if you need to know
    /// whether resolution will succeed.
    pub fn hasProfile(self: *const LlmConfig, name: []const u8) bool {
        if (self.profiles_models.getEntry(name)) |entry| {
            return entry.value_ptr.model.len > 0;
        }
        return false;
    }

    /// Fully-resolved effective settings for one LLM call, produced by
    /// walking the canonical profile cascade (see `resolveEffectiveProfile`).
    pub const EffectiveProfile = struct {
        model: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        url_style: []const u8,
        /// Which transport runs this call: `"http"` | `"claude-code"`. Never
        /// empty.
        backend: []const u8,
        /// Claude Code only: `CLAUDE_CONFIG_DIR` for this call. `null` = the
        /// CLI's own default (`~/.claude`).
        config_dir: ?[]const u8,
        /// Claude Code only: `--max-turns` for this call. `null` = CLI
        /// default.
        max_turns: ?u32,
        /// OpenCode only: `--agent` for this call. `null` = CLI default.
        opencode_agent: ?[]const u8,
        /// OpenCode only: `--auto` for this call. `null` = CLI default (on).
        opencode_auto: ?bool,
        /// Raw resolved `thinking` string ("auto" when nothing set).
        thinking_str: []const u8,
        /// Derived: parseThinkingString(thinking_str) catch null.
        /// "auto"/"" → null, "on"/"true" → true, "off"/"false" → false.
        is_thinking: ?bool,
        /// Derived: std.mem.eql(u8, thinking_str, "auto").
        thinking_adaptive: bool,
        /// Anthropic extended-thinking budget override (null = heuristic/adaptive).
        thinking_budget_tokens: ?u32,
        /// OpenAI reasoning effort ("low"/"medium"/"high"/"auto"; null = omit).
        reasoning_effort: ?[]const u8,
    };

    /// Internal: getProfile that treats an empty name as a miss so the
    /// cascade can pass `active_profile orelse ""` without branching.
    fn getProfileIfSet(self: *const LlmConfig, name: []const u8) ?LlmProfile {
        if (name.len == 0) return null;
        return self.getProfile(name);
    }

    /// THE canonical profile cascade — ONE implementation for the whole
    /// codebase. Walks: 1.
    pub fn resolveEffectiveProfile(
        self: *const LlmConfig,
        selected_profile_model: []const u8,
    ) EffectiveProfile {
        const sel = self.getProfileIfSet(selected_profile_model);
        const act = if (sel == null)
            self.getProfileIfSet(self.active_profile orelse "")
        else
            null;

        // String fields: first non-empty value down the cascade.
        const model: []const u8 = blk: {
            if (sel) |p| if (p.model.len > 0) break :blk p.model;
            if (act) |p| if (p.model.len > 0) break :blk p.model;
            break :blk self.model;
        };
        const base_url: []const u8 = blk: {
            if (sel) |p| if (p.base_url.len > 0) break :blk p.base_url;
            if (act) |p| if (p.base_url.len > 0) break :blk p.base_url;
            break :blk self.base_url;
        };
        const api_key: []const u8 = blk: {
            if (sel) |p| if (p.api_key.len > 0) break :blk p.api_key;
            if (act) |p| if (p.api_key.len > 0) break :blk p.api_key;
            break :blk self.api_key;
        };
        const url_style: []const u8 = blk: {
            if (sel) |p| if (p.url_style.len > 0) break :blk p.url_style;
            if (act) |p| if (p.url_style.len > 0) break :blk p.url_style;
            break :blk self.url_style;
        };
        // thinking: empty on a profile → default "auto" (NOT top-level
        // self.thinking — the top-level LlmConfig has no `thinking`
        // field; workflow.zig's old block defaulted to "auto").
        const thinking_str: []const u8 = blk: {
            if (sel) |p| if (p.thinking.len > 0) break :blk p.thinking;
            if (act) |p| if (p.thinking.len > 0) break :blk p.thinking;
            break :blk "auto";
        };
        const thinking_budget_tokens: ?u32 = blk: {
            if (sel) |p| if (p.thinking_budget_tokens) |t| break :blk t;
            if (act) |p| if (p.thinking_budget_tokens) |t| break :blk t;
            break :blk null;
        };
        const reasoning_effort: ?[]const u8 = blk: {
            if (sel) |p| {
                if (p.reasoning_effort) |re| {
                    if (re.len > 0) break :blk re;
                }
            }
            if (act) |p| {
                if (p.reasoning_effort) |re| {
                    if (re.len > 0) break :blk re;
                }
            }
            break :blk null;
        };
        // Transport. Empty on a profile means "not set" (same fall-through
        // rule as the string fields above); nothing set anywhere → "http",
        // which is what makes an absent `backend` key a no-op.
        const backend: []const u8 = blk: {
            if (sel) |p| if (p.backend.len > 0) break :blk p.backend;
            if (act) |p| if (p.backend.len > 0) break :blk p.backend;
            break :blk "http";
        };
        const config_dir: ?[]const u8 = blk: {
            if (sel) |p| if (p.config_dir) |d| break :blk d;
            if (act) |p| if (p.config_dir) |d| break :blk d;
            break :blk null;
        };
        const max_turns: ?u32 = blk: {
            if (sel) |p| if (p.max_turns) |n| break :blk n;
            if (act) |p| if (p.max_turns) |n| break :blk n;
            break :blk null;
        };
        const opencode_agent: ?[]const u8 = blk: {
            if (sel) |p| if (p.opencode_agent) |a| break :blk a;
            if (act) |p| if (p.opencode_agent) |a| break :blk a;
            break :blk null;
        };
        const opencode_auto: ?bool = blk: {
            if (sel) |p| if (p.opencode_auto) |b| break :blk b;
            if (act) |p| if (p.opencode_auto) |b| break :blk b;
            break :blk null;
        };

        // Derived ONCE from the final string (pre-refactor:
        // workflow.zig:471 parseThinkingString catch null; :477 eql "auto").
        return .{
            .model = model,
            .base_url = base_url,
            .api_key = api_key,
            .url_style = url_style,
            .backend = backend,
            .config_dir = config_dir,
            .max_turns = max_turns,
            .opencode_agent = opencode_agent,
            .opencode_auto = opencode_auto,
            .thinking_str = thinking_str,
            .is_thinking = parse_thinking.parseThinkingString(thinking_str) catch null,
            .thinking_adaptive = std.mem.eql(u8, thinking_str, "auto"),
            .thinking_budget_tokens = thinking_budget_tokens,
            .reasoning_effort = reasoning_effort,
        };
    }

    /// Whole-profile variant of the cascade: returns the winning `LlmProfile`
    /// (selected → active → null), NOT per-field merged.
    pub fn resolveSessionProfileCompat(
        self: *const LlmConfig,
        selected_profile_model: []const u8,
    ) ?LlmProfile {
        if (self.getProfileIfSet(selected_profile_model)) |p| return p;
        if (self.active_profile) |ap| {
            if (ap.len > 0) {
                if (self.getProfile(ap)) |p| return p;
            }
        }
        return null;
    }

    /// Look up a top-level sub-agent by name. Returns null when not configured.
    /// The returned `SubAgentConfig` borrows from `self` — its lifetime is
    /// tied to this `LlmConfig` (do not outlive the config).
    pub fn getSubAgent(self: *const LlmConfig, name: []const u8) ?SubAgentConfig {
        for (self.sub_agents) |sa| {
            if (std.mem.eql(u8, sa.name, name)) return sa;
        }
        return null;
    }

    /// Returns true if a top-level sub-agent with the given name is configured.
    pub fn hasSubAgent(self: *const LlmConfig, name: []const u8) bool {
        return self.getSubAgent(name) != null;
    }

    /// Returns the number of top-level sub-agents.
    pub fn subAgentCount(self: *const LlmConfig) u32 {
        return @intCast(self.sub_agents.len);
    }

    /// Resolve a sub-agent by name, applying the v1 lookup rules: 1. If
    /// `profile_name` is non-empty AND a profile with that name exists,
    /// search `profile.sub_agents` first. 2.
    pub fn resolveSubAgent(
        self: *LlmConfig,
        profile_name: []const u8,
        agent_name: []const u8,
    ) ResolvedSubAgent {
        // 1. Per-profile lookup ONLY (plan 2026-09-04-subagents-per-profile).
        // Each profile owns its subagents; there is no global fallback.
        // A miss here goes straight to the random fallback below.
        if (profile_name.len > 0) {
            if (self.getProfile(profile_name)) |profile| {
                if (profile.sub_agents.len > 0) {
                    for (profile.sub_agents) |sa| {
                        if (std.mem.eql(u8, sa.name, agent_name)) {
                            return self.buildResolvedFromConfig(sa, agent_name, profile_name);
                        }
                    }
                }
            }
            // Profile not found OR no match: fall through to the
            // random fallback. (We deliberately do NOT warn here —
            // an empty per-profile list is a normal configuration.)
        }

        // 2. Not found — random fallback.
        const random_name = generateRandomAgentName(self.allocator) catch blk: {
            // Last-ditch fallback: empty string.
            break :blk "";
        };
        // Track the name for cleanup in deinit (no-op for empty string
        // fallback).
        if (random_name.len > 0) {
            const new_len = self.random_names.len + 1;
            var grown: [][]u8 = self.allocator.realloc(self.random_names, new_len) catch blk: {
                // realloc failed — try a fresh allocation and copy.
                const fresh = self.allocator.alloc([]u8, new_len) catch break :blk &.{};
                if (fresh.len == new_len and self.random_names.len > 0) {
                    @memcpy(fresh[0..self.random_names.len], self.random_names);
                }
                break :blk fresh;
            };
            if (grown.len == new_len) {
                grown[self.random_names.len] = @constCast(random_name);
                self.random_names = grown;
            }
        }
        // Transport for the random fallback: whatever the orchestrator
        // resolves to.
        const act_profile = self.resolveSessionProfileCompat("");
        return ResolvedSubAgent{
            .name = random_name,
            .is_random_fallback = true,
            .requested_name = agent_name,
            .model = self.model,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .url_style = self.url_style,
            .backend = self.effectiveBackend(),
            .config_dir = if (act_profile) |p| p.config_dir else null,
            .max_turns = if (act_profile) |p| p.max_turns else null,
            .opencode_agent = if (act_profile) |p| p.opencode_agent else null,
            .opencode_auto = if (act_profile) |p| p.opencode_auto else null,
            .is_thinking = null,
            .temperature = null,
            .thinking_budget_tokens = null,
            .reasoning_effort = null,
            .system_prompt = "",
            .source = "",
        };
    }

    /// Internal helper — convert a matched `SubAgentConfig` into a
    /// `ResolvedSubAgent` with string→bool/f32 parsing for `thinking` /
    /// `temperature`.
    fn buildResolvedFromConfig(
        self: *const LlmConfig,
        sa: SubAgentConfig,
        requested_name: []const u8,
        source: []const u8,
    ) ResolvedSubAgent {
        // thinking: route through the pure parse_thinking helper. The helper
        // accepts "auto" / "on" / "off" / "true" / "false" / "" and surfaces
        // `error.InvalidThinkingMode` on garbage.
        const resolved_thinking: ?bool = parse_thinking.parseThinkingString(sa.thinking) catch null;

        // temperature: "auto" → null. Numeric → parseFloat. Anything
        // else → null.
        const resolved_temperature: ?f32 = blk: {
            if (std.mem.eql(u8, sa.temperature, "auto")) break :blk null;
            break :blk std.fmt.parseFloat(f32, sa.temperature) catch null;
        };

        // thinking_budget_tokens: pass through. HTTP layer enforces the (0,
        // 2_000_000] range, so by the time we see this value it's guaranteed
        // non-zero.
        const resolved_budget: ?u32 = sa.thinking_budget_tokens;

        // reasoning_effort: pass through.
        const resolved_effort: ?[]const u8 = blk: {
            const e = sa.reasoning_effort orelse break :blk null;
            if (e.len == 0) break :blk null;
            break :blk e;
        };

        return ResolvedSubAgent{
            .name = sa.name,
            .is_random_fallback = false,
            .requested_name = requested_name,
            // Overlay: empty field in SubAgentConfig → orchestrator default.
            // NOTE (plan 2026-08-23-refactor-profile-resolution): this is
            // deliberately NOT `resolveEffectiveProfile`.
            .model = if (sa.model.len > 0) sa.model else self.model,
            .base_url = if (sa.base_url.len > 0) sa.base_url else self.base_url,
            .api_key = if (sa.api_key.len > 0) sa.api_key else self.api_key,
            .url_style = if (sa.url_style.len > 0) sa.url_style else self.url_style,
            // Transport follows the same overlay rule as the fields above:
            // a sub-agent that names no backend runs on the orchestrator's.
            .backend = if (sa.backend.len > 0) sa.backend else self.effectiveBackend(),
            .config_dir = if (sa.config_dir) |d| d else blk: {
                const p = self.resolveSessionProfileCompat("") orelse break :blk null;
                break :blk p.config_dir;
            },
            .max_turns = if (sa.max_turns) |n| n else blk: {
                const p = self.resolveSessionProfileCompat("") orelse break :blk null;
                break :blk p.max_turns;
            },
            .opencode_agent = if (sa.opencode_agent) |a| a else blk: {
                const p = self.resolveSessionProfileCompat("") orelse break :blk null;
                break :blk p.opencode_agent;
            },
            .opencode_auto = if (sa.opencode_auto) |b| b else blk: {
                const p = self.resolveSessionProfileCompat("") orelse break :blk null;
                break :blk p.opencode_auto;
            },
            .is_thinking = resolved_thinking,
            .temperature = resolved_temperature,
            .thinking_budget_tokens = resolved_budget,
            .reasoning_effort = resolved_effort,
            .system_prompt = sa.system_prompt,
            .source = source,
        };
    }

    /// Resolve the effective max-context-window in tokens for a given model
    /// under the optional profile + sub-agent scope. Cascade order: 1.
    pub fn maxCapacityForModel(
        self: *const LlmConfig,
        profile: ?*const LlmProfile,
        sub_agent: ?*const SubAgentConfig,
        defaults: ?*const LlmConfig,
        model_name: []const u8,
    ) u32 {
        // No catalog: the pre-models.dev cascade, byte for byte. Kept as its
        // own entry point because callers that genuinely have no catalog (and
        // every existing test) must not accidentally start consulting one.
        return self.maxCapacityForModelWith(profile, sub_agent, defaults, model_name, null);
    }

    /// The cascade, with an explicit catalog in step 4: 1.
    /// `sub_agent.max_capacity_tokens` 2. `profile.max_capacity_tokens` 3.
    pub fn maxCapacityForModelWith(
        self: *const LlmConfig,
        profile: ?*const LlmProfile,
        sub_agent: ?*const SubAgentConfig,
        defaults: ?*const LlmConfig,
        model_name: []const u8,
        cat: ?*const model_catalog.Catalog,
    ) u32 {
        _ = self;
        if (sub_agent) |sa| if (sa.max_capacity_tokens) |override| return override;
        if (profile) |p| if (p.max_capacity_tokens) |override| return override;
        if (defaults) |d| if (d.max_capacity_token_model) |override| return override;
        if (cat) |c| {
            if (c.lookup(null, model_name)) |facts| {
                if (facts.context_window) |window| return window;
            }
        }
        return LLMModels.getModelTokenCount(model_name);
    }

    /// Resolve the compaction threshold as a percentage (0-100). Cascade
    /// order (same shape as `maxCapacityForModel`): 1.
    /// `sub_agent.compaction_threshold_percent` (if non-null and set) 2.
    pub fn compactionThresholdPercent(
        self: *const LlmConfig,
        profile: ?*const LlmProfile,
        sub_agent: ?*const SubAgentConfig,
        defaults: ?*const LlmConfig,
    ) u8 {
        _ = self;
        if (sub_agent) |sa| if (sa.compaction_threshold_percent) |override| return override;
        if (profile) |p| if (p.compaction_threshold_percent) |override| return override;
        if (defaults) |d| if (d.compaction_threshold_percent) |override| return override;
        return 80;
    }

    /// The default `config.json` content written on first run (when no config
    /// file exists at the platform-default path).
    pub const defaultConfigJson: []const u8 =
        \\{
        \\  "profiles_models": {},
        \\  "active_profile": null,
        \\  "model_compaction_size_kb": 100,
        \\  "notify_on_complete": false,
        \\  "web_launch_enabled": false,
        \\  "retry_delay_ms": 0,
        \\  "skill_evals": {
        \\    "enabled": false,
        \\    "max_skills_per_run": 8,
        \\    "max_evals_per_day": 10,
        \\    "fact_lease_seconds": 300,
        \\    "apply_mode": "propose",
        \\    "include_listed_without_loading": true
        \\  },
        \\  "max_capacity_token_model": null,
        \\  "compaction_threshold_percent": null
        \\}
    ;

    /// Write `defaultConfigJson` to `path`, creating any missing parent
    /// directories (mkdir -p semantics).
    pub fn writeDefaultConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!void {
        _ = allocator; // unused in current implementation, kept for future use

        // Ensure the parent directory exists (mkdir -p semantics).
        // std.Io.Dir.cwd().createDirPath is the project-wide pattern for
        // "create nested dirs relative to cwd" (see Logger.zig:136,
        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
                std.log.warn("Failed to create config dir {s}: {s}", .{ parent, @errorName(err) });
                return error.ConfigDirNotFound;
            };
        }

        // Write the default config. .truncate = true means any stale file at
        // `path` is replaced atomically by the kernel.
        if (!std.fs.path.isAbsolute(path)) {
            std.log.warn("Refusing to write the default config to a relative path: {s}", .{path});
            return error.ConfigFileReadError;
        }
        const file = Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch |err| {
            std.log.warn("Failed to create config file {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
        defer file.close(io);

        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        writer.interface.writeAll(defaultConfigJson) catch |err| {
            std.log.warn("Failed to write default config to {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
        writer.interface.flush() catch |err| {
            std.log.warn("Failed to flush default config to {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
    }
};

/// Generate a random sub-agent name of the form `"agent-{randomhex}"` for the
/// random-fallback case when a requested `agent_name` is not found in any
/// sub_agents list.
fn generateRandomAgentName(allocator: std.mem.Allocator) ![]u8 {
    // 8 bytes of pseudo-random entropy → 16 hex chars.
    var entropy_bytes: [8]u8 = undefined;
    const pid: u64 = switch (builtin.os.tag) {
        .linux, .macos => @intCast(std.c.getpid()),
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => 0,
    };
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy_bytes));
    const alloc_addr: u64 = @intCast(@intFromPtr(allocator.ptr));
    const entropy: u64 = pid ^ (stack_addr << 17) ^ (alloc_addr << 33);
    @as(*u64, @ptrCast(@alignCast(&entropy_bytes))).* = entropy;

    var out_buf: [22]u8 = undefined;
    @memcpy(out_buf[0..6], "agent-");
    const hex_chars = "0123456789abcdef";
    for (entropy_bytes, 0..) |b, i| {
        out_buf[6 + i * 2] = hex_chars[b >> 4];
        out_buf[6 + i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return allocator.dupe(u8, &out_buf);
}

pub fn getDefaultConfigDir(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const app_name = "pabrik";

    switch (builtin.os.tag) {
        .windows => {
            const appdata = environment.get("APPDATA") orelse {
                std.log.warn("APPDATA environment variable not set", .{});
                return error.ConfigDirNotFound;
            };
            if (!std.fs.path.isAbsolute(appdata)) {
                std.log.warn("APPDATA is not an absolute path: {s}", .{appdata});
                return error.ConfigDirNotFound;
            }
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, app_name });
        },
        .macos => {
            const home = environment.get("HOME") orelse {
                std.log.warn("HOME environment variable not set", .{});
                return error.HomeNotFound;
            };
            if (!std.fs.path.isAbsolute(home)) {
                std.log.warn("HOME is not an absolute path: {s}", .{home});
                return error.HomeNotFound;
            }
            return std.fs.path.join(allocator, &[_][]const u8{
                home, "Library", "Application Support", app_name,
            });
        },
        else => {
            if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
                if (!std.fs.path.isAbsolute(xdg_config)) {
                    std.log.warn("XDG_CONFIG_HOME is not an absolute path: {s}", .{xdg_config});
                    return error.ConfigDirNotFound;
                }
                return std.fs.path.join(allocator, &[_][]const u8{ xdg_config, app_name });
            }
            const home = environment.get("HOME") orelse {
                std.log.warn("HOME environment variable not set", .{});
                return error.MissingRequiredField;
            };
            if (!std.fs.path.isAbsolute(home)) {
                std.log.warn("HOME is not an absolute path: {s}", .{home});
                return error.MissingRequiredField;
            }
            return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", app_name });
        },
    }
}

pub fn getDefaultConfigPath(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const config_dir = try getDefaultConfigDir(allocator, environment);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
}

pub fn loadDefault(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError!LlmConfig {
    return LlmConfig.init(allocator, null, environment);
}

// ---------------------------------------------------------------------------
// resolveEffectiveProfile — THE canonical profile cascade (plan
// 2026-08-23-refactor-profile-resolution).

/// Shared fixture: top-level defaults + two profiles ("alpha" fully
/// populated, "partial" with only model set). Built directly (no disk
/// round-trip).
fn cascadeFixture(allocator: std.mem.Allocator) !LlmConfig {
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
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    try cfg.profiles_models.put(try allocator.dupe(u8, "alpha"), .{
        .model = try allocator.dupe(u8, "alpha-model"),
        .base_url = try allocator.dupe(u8, "https://alpha"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "alpha-key"),
        .url_style = try allocator.dupe(u8, "anthropic"),
        .sub_agents = &.{},
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = 4096,
        .reasoning_effort = try allocator.dupe(u8, "high"),
    });
    try cfg.profiles_models.put(try allocator.dupe(u8, "partial"), .{
        .model = try allocator.dupe(u8, "partial-model"),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .sub_agents = &.{},
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

test "resolveEffectiveProfile: selected profile wins over top-level for every field" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("alpha");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("https://alpha", e.base_url);
    try std.testing.expectEqualStrings("alpha-key", e.api_key);
    try std.testing.expectEqualStrings("anthropic", e.url_style);
    try std.testing.expectEqualStrings("on", e.thinking_str);
    // Derived from thinking_str="on":
    try std.testing.expect(e.is_thinking == true);
    try std.testing.expectEqual(false, e.thinking_adaptive);
    try std.testing.expectEqual(@as(?u32, 4096), e.thinking_budget_tokens);
    try std.testing.expectEqualStrings("high", e.reasoning_effort.?);
}

test "resolveEffectiveProfile: no selection + no active → pure top-level defaults" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("");
    try std.testing.expectEqualStrings("top-model", e.model);
    try std.testing.expectEqualStrings("https://top", e.base_url);
    try std.testing.expectEqualStrings("top-key", e.api_key);
    try std.testing.expectEqualStrings("openai", e.url_style);
    try std.testing.expectEqualStrings("auto", e.thinking_str);
    // Derived from thinking_str="auto":
    try std.testing.expect(e.is_thinking == null);
    try std.testing.expectEqual(true, e.thinking_adaptive);
    try std.testing.expectEqual(@as(?u32, null), e.thinking_budget_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), e.reasoning_effort);
}

test "resolveEffectiveProfile: missing selected name falls through to top-level" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("does_not_exist");
    try std.testing.expectEqualStrings("top-model", e.model);
}

test "resolveEffectiveProfile: partial profile falls through for THAT field only" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("partial");
    // Set on the profile:
    try std.testing.expectEqualStrings("partial-model", e.model);
    // Empty on the profile → top-level fallback:
    try std.testing.expectEqualStrings("https://top", e.base_url);
    try std.testing.expectEqualStrings("top-key", e.api_key);
    try std.testing.expectEqualStrings("openai", e.url_style);
    // Empty thinking on the profile → default "auto".
    try std.testing.expectEqualStrings("auto", e.thinking_str);
}

test "resolveEffectiveProfile: active_profile wins when selection empty" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");

    const e = cfg.resolveEffectiveProfile("");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("anthropic", e.url_style);
    try std.testing.expectEqual(@as(?u32, 4096), e.thinking_budget_tokens);
}

test "resolveEffectiveProfile: selected wins over active_profile" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "partial");

    const e = cfg.resolveEffectiveProfile("alpha");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("alpha-key", e.api_key);
}

test "resolveEffectiveProfile: missing selected falls to active_profile" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");

    const e = cfg.resolveEffectiveProfile("does_not_exist");
    try std.testing.expectEqualStrings("alpha-model", e.model);
}

test "resolveEffectiveProfile: derived fields for off / garbage thinking strings" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "partial");
    // Mutate the stored profile's thinking directly.
    const pptr = cfg.profiles_models.getPtr("partial").?;
    cfg.allocator.free(pptr.thinking);
    pptr.thinking = try cfg.allocator.dupe(u8, "off");

    const e_off = cfg.resolveEffectiveProfile("");
    try std.testing.expect(e_off.is_thinking == false);
    try std.testing.expectEqual(false, e_off.thinking_adaptive);

    cfg.allocator.free(pptr.thinking);
    pptr.thinking = try cfg.allocator.dupe(u8, "total-garbage");
    const e_bad = cfg.resolveEffectiveProfile("");
    // Garbage ≠ "auto" → adaptive=false; parse fails → is_thinking=null.
    try std.testing.expect(e_bad.is_thinking == null);
    try std.testing.expectEqual(false, e_bad.thinking_adaptive);
}

test "resolveSessionProfileCompat: mirrors old resolveSessionProfile semantics" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    // Selected hit.
    try std.testing.expect(cfg.resolveSessionProfileCompat("alpha") != null);
    try std.testing.expectEqualStrings("alpha-model", cfg.resolveSessionProfileCompat("alpha").?.model);
    // Miss → null (no active set in fixture).
    try std.testing.expect(cfg.resolveSessionProfileCompat("") == null);
    try std.testing.expect(cfg.resolveSessionProfileCompat("nope") == null);

    // Active hit.
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");
    const p = cfg.resolveSessionProfileCompat("").?;
    try std.testing.expectEqualStrings("alpha-model", p.model);
}

test {
    // config_test.zig's tests are inline at the bottom of this file
    // (2026-09-29 flatten); parse_thinking_test.zig's landed in
    // parse_thinking.zig, which still needs a discovery edge.
    _ = @import("parse_thinking.zig");
}

// ===== Tests merged from config_test.zig (2026-09-29 flatten) =====
test "config module imports" {
    // Sanity check: the module is importable.
    try std.testing.expect(@hasDecl(LlmConfig, "McpServerConfig"));
    try std.testing.expect(@hasDecl(LlmConfig, "McpServersMap"));
    try std.testing.expect(@hasDecl(LlmConfig, "McpHeadersMap"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerConfig"));
    try std.testing.expect(@hasDecl(LlmConfig, "hasMcpServer"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerUrl"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerCount"));
    try std.testing.expect(@hasDecl(LlmConfig, "hasMcpServers"));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write `json` to a temp `config.json` and load it with `LlmConfig.init`.
/// Caller owns the returned `LlmConfig` and must call `deinit` on it.
fn writeAndRead(allocator: std.mem.Allocator, io: std.Io, json_body: []const u8) !LlmConfig {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data = json_body,
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(config_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");

    return LlmConfig.init(allocator, io, config_path, &env_map);
}

// ---------------------------------------------------------------------------
// Parsing: snake_case `mcp_servers` field (the canonical form)
// ---------------------------------------------------------------------------

test "mcp_servers: parses snake_case field with one server" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "base_url": "https://example.com",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": {
        \\        "CONTEXT7_API_KEY": "YOUR_API_KEY"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasMcpServers());
    try std.testing.expectEqual(@as(u32, 1), cfg.mcpServerCount());
    try std.testing.expect(cfg.hasMcpServer("context7"));
    try std.testing.expect(!cfg.hasMcpServer("nope"));

    const ctx = cfg.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx.url.?);
    try std.testing.expect(ctx.isValid());
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(ctx.headers.count())));
    try std.testing.expectEqualStrings("YOUR_API_KEY", ctx.headers.get("CONTEXT7_API_KEY").?);
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", cfg.mcpServerUrl("context7").?);
}

test "mcp_servers: parses multiple servers" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": { "CONTEXT7_API_KEY": "ctx-key" }
        \\    },
        \\    "github": {
        \\      "url": "https://mcp.github.com/mcp",
        \\      "headers": { "GITHUB_TOKEN": "gh-token" }
        \\    },
        \\    "plain": {
        \\      "url": "https://mcp.plain.com/mcp"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 3), cfg.mcpServerCount());
    try std.testing.expect(cfg.hasMcpServer("context7"));
    try std.testing.expect(cfg.hasMcpServer("github"));
    try std.testing.expect(cfg.hasMcpServer("plain"));

    const ctx = cfg.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("ctx-key", ctx.headers.get("CONTEXT7_API_KEY").?);

    const gh = cfg.mcpServerConfig("github").?;
    try std.testing.expectEqualStrings("gh-token", gh.headers.get("GITHUB_TOKEN").?);

    const plain = cfg.mcpServerConfig("plain").?;
    try std.testing.expectEqualStrings("https://mcp.plain.com/mcp", plain.url.?);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(plain.headers.count())));
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Robustness

test "mcp_servers: empty config yields empty map" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServers());
    try std.testing.expectEqual(@as(u32, 0), cfg.mcpServerCount());
    try std.testing.expect(!cfg.hasMcpServer("anything"));
    try std.testing.expect(cfg.mcpServerConfig("anything") == null);
    try std.testing.expect(cfg.mcpServerUrl("anything") == null);
}

test "mcp_servers: skips server entries missing url" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "bad": { "headers": { "X": "y" } },
        \\    "good": { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("bad"));
    try std.testing.expect(cfg.hasMcpServer("good"));
    try std.testing.expectEqual(@as(u32, 1), cfg.mcpServerCount());
}

test "mcp_servers: skips server entries with non-string url" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "numeric": { "url": 42 },
        \\    "good":   { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("numeric"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: empty url is skipped" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "empty":   { "url": "" },
        \\    "good":    { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("empty"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: non-object server entry is skipped" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "string": "not-an-object",
        \\    "array":  [1, 2, 3],
        \\    "good":   { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("string"));
    try std.testing.expect(!cfg.hasMcpServer("array"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: skips non-string header values" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "mix": {
        \\      "url": "https://mix.example.com",
        \\      "headers": {
        \\        "OK": "good",
        \\        "BAD": 42,
        \\        "ALSO_OK": "fine"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const mix = cfg.mcpServerConfig("mix").?;
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(mix.headers.count())));
    try std.testing.expectEqualStrings("good", mix.headers.get("OK").?);
    try std.testing.expectEqualStrings("fine", mix.headers.get("ALSO_OK").?);
    try std.testing.expect(mix.headers.get("BAD") == null);
}

test "mcp_servers: parses stdio server with command+args" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": {
        \\      "command": "mcp-hello-world",
        \\      "args": ["--port", "3001"]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasMcpServer("hello"));
    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expectEqualStrings("mcp-hello-world", server.command.?);
    try std.testing.expectEqual(@as(usize, 2), server.args.?.len);
    try std.testing.expectEqualStrings("--port", server.args.?[0]);
    try std.testing.expectEqualStrings("3001", server.args.?[1]);
    try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());
}

test "mcp_servers: parses stdio server with command+args+cwd" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": {
        \\      "command": "mcp-hello-world",
        \\      "args": ["server.js"],
        \\      "cwd": "/opt/mcp"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expectEqualStrings("/opt/mcp", server.cwd.?);
    try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());
}

test "mcp_servers: stdio server with empty args array works" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expectEqualStrings("mcp-hello-world", server.command.?);
    try std.testing.expect(server.args == null);
}

test "mcp_servers: skips server with neither url nor command" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "bad":  { "headers": { "X": "y" } },
        \\    "good": { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("bad"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: skips server with empty command" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "empty_cmd": { "command": "" },
        \\    "good":      { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("empty_cmd"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: skips server with non-string command" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "numeric_cmd": { "command": 42 },
        \\    "good":        { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("numeric_cmd"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: http transport discriminator returns http for url entries" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "http": { "url": "https://x.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const server = cfg.mcpServerConfig("http").?;
    try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.http, server.transport());
    try std.testing.expectEqualStrings("https://x.example.com", server.url.?);
}

test "mcp_servers: non-object headers field is treated as empty" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "weird": {
        \\      "url": "https://weird.example.com",
        \\      "headers": "not-an-object"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const weird = cfg.mcpServerConfig("weird").?;
    try std.testing.expectEqualStrings("https://weird.example.com", weird.url.?);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(weird.headers.count())));
}

test "mcp_servers: missing headers field is treated as empty" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "noheaders": { "url": "https://nh.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const nh = cfg.mcpServerConfig("noheaders").?;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(nh.headers.count())));
}

// ---------------------------------------------------------------------------
// Backward compat: the existing `mcpServers()` json.Value accessor still works
// ---------------------------------------------------------------------------

test "mcp_servers: legacy mcpServers() json.Value accessor still returns data" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": { "url": "https://mcp.context7.com/mcp" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const raw = cfg.mcpServers().?;
    const obj = raw.object;
    try std.testing.expect(obj.get("context7") != null);
    const ctx_value = obj.get("context7").?;
    const ctx_obj = ctx_value.object;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx_obj.get("url").?.string);
}

// ---------------------------------------------------------------------------
// Lifecycle: clone produces a deep, independent copy
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// notify_on_complete: opt-in OS notification flag
// ---------------------------------------------------------------------------

test "notify_on_complete: defaults to false when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_complete);
}

test "notify_on_complete: reads true from JSON when present" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": true
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.notify_on_complete);
}

test "notify_on_complete: reads false from JSON when explicitly false" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": false
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_complete);
}

// ---------------------------------------------------------------------------
// notify_on_error: opt-in OS notification flag for the error path (transport
// failure, TooManyRetries, outer catch).

test "notify_on_error: defaults to false when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_error);
}

test "notify_on_error: reads true from JSON when present" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_error": true
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.notify_on_error);
}

test "notify_on_error: reads false from JSON when explicitly false" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_error": false
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_error);
}

test "notify_on_error: round-trips independently of notify_on_complete" {
    // The two flags are independent toggles — enabling one MUST NOT
    // flip the other. Lock the contract so a future refactor doesn't
    // accidentally collapse them into a single `notify: bool`.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": true,
        \\  "notify_on_error": false
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.notify_on_complete);
    try std.testing.expectEqual(false, cfg.notify_on_error);
}

// ---------------------------------------------------------------------------
// web_launch_enabled: opt-in browser-launch flag.

test "web_launch_enabled: defaults to false when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.web_launch_enabled);
}

test "web_launch_enabled: reads true from JSON when present" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "web_launch_enabled": true
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.web_launch_enabled);
}

test "web_launch_enabled: round-trips independently of notify_on_complete" {
    // The two flags are independent toggles — enabling one MUST NOT
    // flip the other.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": true,
        \\  "web_launch_enabled": false
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.notify_on_complete);
    try std.testing.expectEqual(false, cfg.web_launch_enabled);
}

// ---------------------------------------------------------------------------
// url_style: top-level OpenAI vs Anthropic selector (regression for
// `PabrikSettings.vue` URL Style dropdown — see plan

test "LlmConfig: url_style field round-trips through disk JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "url_style": "anthropic"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("anthropic", cfg.url_style);
}

test "LlmConfig: url_style defaults to openai when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("openai", cfg.url_style);
}

// ---------------------------------------------------------------------------
// retry_delay_ms: workflow retry backoff in milliseconds. 0 = no delay
// (current behavior).

test "LlmConfig: retry_delay_ms defaults to 0 when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 0), cfg.retry_delay_ms);
}

test "LlmConfig: retry_delay_ms reads from JSON when present" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "retry_delay_ms": 5000
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 5000), cfg.retry_delay_ms);
}

// ---------------------------------------------------------------------------
// model_compaction_size_kb: session-compactor threshold (consumed by
// `session_compact.zig:57`).

test "LlmConfig: model_compaction_size_kb reads value from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "model_compaction_size_kb": 250
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 250), cfg.model_compaction_size_kb);
}

test "LlmConfig: model_compaction_size_kb defaults to 100 when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 100), cfg.model_compaction_size_kb);
}

test "mcp_servers: clone produces independent deep copy" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": { "CONTEXT7_API_KEY": "YOUR_API_KEY" }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    // Both should have the same data.
    try std.testing.expect(cloned.hasMcpServer("context7"));
    const ctx = cloned.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx.url.?);
    try std.testing.expectEqualStrings("YOUR_API_KEY", ctx.headers.get("CONTEXT7_API_KEY").?);

    // The strings should be at different addresses — independent allocations.
    const orig_url = cfg.mcpServerUrl("context7").?;
    try std.testing.expect(orig_url.ptr != ctx.url.?.ptr);

    const orig_key = cfg.mcpServerConfig("context7").?.headers.get("CONTEXT7_API_KEY").?;
    try std.testing.expect(orig_key.ptr != ctx.headers.get("CONTEXT7_API_KEY").?.ptr);
}

// ---------------------------------------------------------------------------
// sub_agents: top-level typed array
// ---------------------------------------------------------------------------

test "sub_agents: top-level field is parsed into SubAgentsList" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "sub_agents": [
        \\    {
        \\      "name": "SubAgent1",
        \\      "model": "MiniMax-M3",
        \\      "base_url": "https://api.minimax.io/v1",
        \\      "thinking": "false",
        \\      "temperature": "auto",
        \\      "url_style": "openai",
        \\      "api_key": "",
        \\      "system_prompt": ""
        \\    }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.sub_agents.len);
    const sa = cfg.sub_agents[0];
    try std.testing.expectEqualStrings("SubAgent1", sa.name);
    try std.testing.expectEqualStrings("MiniMax-M3", sa.model);
    try std.testing.expectEqualStrings("https://api.minimax.io/v1", sa.base_url);
    try std.testing.expectEqualStrings("false", sa.thinking);
    try std.testing.expectEqualStrings("auto", sa.temperature);
    try std.testing.expectEqualStrings("openai", sa.url_style);
    try std.testing.expectEqualStrings("", sa.api_key);
    try std.testing.expectEqualStrings("", sa.system_prompt);
}

test "sub_agents: hasSubAgent / getSubAgent accessors" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "you are alpha" },
        \\    { "name": "beta",  "model": "M2", "base_url": "https://b",
        \\      "thinking": "off", "temperature": "auto", "url_style": "anthropic",
        \\      "api_key": "ak2", "system_prompt": "" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasSubAgent("alpha"));
    try std.testing.expect(cfg.hasSubAgent("beta"));
    try std.testing.expect(!cfg.hasSubAgent("nope"));

    const a = cfg.getSubAgent("alpha").?;
    try std.testing.expectEqualStrings("M1", a.model);
    try std.testing.expectEqualStrings("https://a", a.base_url);
    try std.testing.expectEqualStrings("on", a.thinking);
    try std.testing.expectEqualStrings("0.5", a.temperature);
    try std.testing.expectEqualStrings("you are alpha", a.system_prompt);

    try std.testing.expect(cfg.getSubAgent("nope") == null);
}

test "model-thinking knobs: profile thinking_budget_tokens + reasoning_effort round-trip" {
    // Verify the new per-profile fields round-trip through the JSON parser
    // without being silently dropped.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "m", "base_url": "https://a", "api_key": "k",
        \\      "thinking": "on", "temperature": "auto", "url_style": "anthropic",
        \\      "thinking_budget_tokens": 4096,
        \\      "reasoning_effort": "high"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const p = cfg.getProfile("alpha").?;
    try std.testing.expectEqual(@as(?u32, 4096), p.thinking_budget_tokens);
    try std.testing.expectEqualStrings("high", p.reasoning_effort.?);
}

test "opencode knobs: profile opencode_agent + opencode_auto round-trip" {
    // The OpenCode CLI knobs must survive the JSON parser rather than being
    // silently dropped — the same storage-path guarantee the model-thinking
    // knobs get above.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "opencode-go/deepseek-flash", "base_url": "", "api_key": "",
        \\      "thinking": "auto", "temperature": "auto", "url_style": "openai",
        \\      "backend": "opencode",
        \\      "opencode_agent": "build",
        \\      "opencode_auto": false
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const p = cfg.getProfile("alpha").?;
    try std.testing.expectEqualStrings("opencode", p.backend);
    try std.testing.expectEqualStrings("build", p.opencode_agent.?);
    try std.testing.expectEqual(@as(?bool, false), p.opencode_auto);
}

test "opencode knobs: profile fields default to null when omitted" {
    // Backward compatibility — a config.json written before these fields
    // existed must parse cleanly with both as null.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "m", "base_url": "https://a", "api_key": "k",
        \\      "thinking": "auto", "temperature": "auto", "url_style": "openai"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const p = cfg.getProfile("alpha").?;
    try std.testing.expectEqual(@as(?[]const u8, null), p.opencode_agent);
    try std.testing.expectEqual(@as(?bool, null), p.opencode_auto);
}

test "model-thinking knobs: profile fields default to null when omitted" {
    // Backward compatibility — old config.json files without the new
    // fields must parse cleanly with the new fields as null.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "m", "base_url": "https://a", "api_key": "k",
        \\      "thinking": "auto", "temperature": "auto", "url_style": "openai"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const p = cfg.getProfile("alpha").?;
    try std.testing.expectEqual(@as(?u32, null), p.thinking_budget_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), p.reasoning_effort);
}

test "model-thinking knobs: sub_agent thinking_budget_tokens + reasoning_effort round-trip" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "anthropic",
        \\      "api_key": "ak1", "system_prompt": "sp",
        \\      "thinking_budget_tokens": 8192,
        \\      "reasoning_effort": "medium" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const sa = cfg.getSubAgent("alpha").?;
    try std.testing.expectEqual(@as(?u32, 8192), sa.thinking_budget_tokens);
    try std.testing.expectEqualStrings("medium", sa.reasoning_effort.?);
}

test "sub_agents: clone produces independent deep copy" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "sp" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), cloned.sub_agents.len);
    const orig = cfg.sub_agents[0];
    const copy = cloned.sub_agents[0];
    try std.testing.expect(orig.name.ptr != copy.name.ptr);
    try std.testing.expect(orig.model.ptr != copy.model.ptr);
    try std.testing.expectEqualStrings("alpha", copy.name);
    try std.testing.expectEqualStrings("sp", copy.system_prompt);
}

test "sub_agents: per-profile sub_agents are parsed" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "p1sa", "model": "M1", "base_url": "https://a",
        \\          "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\          "api_key": "ak1", "system_prompt": "sp1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const p1 = cfg.getProfile("profile1").?;
    try std.testing.expectEqual(@as(usize, 1), p1.sub_agents.len);
    try std.testing.expectEqualStrings("p1sa", p1.sub_agents[0].name);
    try std.testing.expectEqualStrings("M1", p1.sub_agents[0].model);
    try std.testing.expectEqualStrings("sp1", p1.sub_agents[0].system_prompt);
}

test "sub_agents: top-level list migrates into profiles with empty lists" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "shared", "model": "M", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak", "system_prompt": "sp" }
        \\  ],
        \\  "profiles_models": {
        \\    "empty1": {
        \\      "model": "M-e1", "base_url": "https://e1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "ke1"
        \\    },
        \\    "empty2": {
        \\      "model": "M-e2", "base_url": "https://e2",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "ke2"
        \\    },
        \\    "owns": {
        \\      "model": "M-o", "base_url": "https://o",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "ko",
        \\      "sub_agents": [
        \\        { "name": "mine", "model": "MO", "base_url": "https://mo",
        \\          "thinking": "off", "temperature": "auto", "url_style": "openai",
        \\          "api_key": "ako", "system_prompt": "spo" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // Empty profiles inherit the migrated entry (deep copy).
    const e1 = cfg.getProfile("empty1").?;
    try std.testing.expectEqual(@as(usize, 1), e1.sub_agents.len);
    try std.testing.expectEqualStrings("shared", e1.sub_agents[0].name);
    try std.testing.expectEqualStrings("sp", e1.sub_agents[0].system_prompt);
    const e2 = cfg.getProfile("empty2").?;
    try std.testing.expectEqual(@as(usize, 1), e2.sub_agents.len);
    try std.testing.expectEqualStrings("shared", e2.sub_agents[0].name);
    // Independent copies, not shared pointers.
    try std.testing.expect(e1.sub_agents[0].name.ptr != e2.sub_agents[0].name.ptr);
    // Non-empty profile keeps its own list (no merge).
    const owns = cfg.getProfile("owns").?;
    try std.testing.expectEqual(@as(usize, 1), owns.sub_agents.len);
    try std.testing.expectEqualStrings("mine", owns.sub_agents[0].name);
}

test "sub_agents: clone preserves per-profile sub_agents" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "p1sa", "model": "M1", "base_url": "https://a",
        \\          "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\          "api_key": "ak1", "system_prompt": "sp1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();
    var cloned = try cfg.clone();
    defer cloned.deinit();

    const p1 = cloned.getProfile("profile1").?;
    try std.testing.expectEqual(@as(usize, 1), p1.sub_agents.len);
    try std.testing.expectEqualStrings("p1sa", p1.sub_agents[0].name);
    try std.testing.expectEqualStrings("sp1", p1.sub_agents[0].system_prompt);
    // Deep copy, not aliased.
    const orig = cfg.getProfile("profile1").?;
    try std.testing.expect(orig.sub_agents[0].name.ptr != p1.sub_agents[0].name.ptr);
}

// ---------------------------------------------------------------------------
// resolveSubAgent — config-driven sub-agent selection
// ---------------------------------------------------------------------------

const resolve_alloc = std.testing.allocator;
const resolve_io = std.testing.io;

/// Pair of (cfg, resolved) so the test can keep cfg alive while inspecting
/// the resolved struct.
const ResolvedPair = struct {
    cfg: LlmConfig,
    resolved: LlmConfig.ResolvedSubAgent,
};

/// Helper: build a config JSON with the given top-level sub_agents array (and
/// no profiles) and resolve `agent_name` against it. Caller owns the returned
/// `cfg` and must call `deinit` on it AFTER they're done with `resolved`.
fn resolveFromTopLevel(json_body: []const u8, agent_name: []const u8) !ResolvedPair {
    var cfg = try writeAndRead(resolve_alloc, resolve_io, json_body);
    const resolved = cfg.resolveSubAgent("", agent_name);
    return ResolvedPair{ .cfg = cfg, .resolved = resolved };
}

/// Helper: same as `resolveFromTopLevel` but passes `profile_name`
/// so the per-profile sub_agents lookup is exercised.
fn resolveFromProfile(
    json_body: []const u8,
    profile_name: []const u8,
    agent_name: []const u8,
) !ResolvedPair {
    var cfg = try writeAndRead(resolve_alloc, resolve_io, json_body);
    const resolved = cfg.resolveSubAgent(profile_name, agent_name);
    return ResolvedPair{ .cfg = cfg, .resolved = resolved };
}

test "resolveSubAgent: per-profile hit returns the matched sub-agent's fields" {
    const json_body =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "gpt-4o",
        \\          "base_url": "https://api.openai.com/v1",
        \\          "thinking": "true", "temperature": "0.3",
        \\          "url_style": "openai", "api_key": "reviewer-key",
        \\          "system_prompt": "You are a strict code reviewer." }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json_body, "profile1", "reviewer");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expectEqualStrings("reviewer", r.name);
    try std.testing.expect(!r.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", r.requested_name);
    try std.testing.expectEqualStrings("gpt-4o", r.model);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", r.base_url);
    try std.testing.expectEqualStrings("reviewer-key", r.api_key);
    try std.testing.expectEqualStrings("openai", r.url_style);
    try std.testing.expectEqualStrings("You are a strict code reviewer.", r.system_prompt);
    try std.testing.expectEqual(@as(?bool, true), r.is_thinking);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), r.temperature.?, 0.0001);
    // Per-profile lookup: source is the profile name.
    try std.testing.expectEqualStrings("profile1", r.source);
}

test "resolveSubAgent: miss returns random fallback with orchestrator defaults" {
    const json_body =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "url_style": "anthropic"
        \\}
    ;
    var pair = try resolveFromTopLevel(json_body, "unknown");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expect(r.is_random_fallback);
    try std.testing.expectEqualStrings("unknown", r.requested_name);
    // Random name format: "agent-" + 16 hex chars.
    try std.testing.expect(r.name.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, r.name, "agent-"));
    try std.testing.expectEqual(@as(usize, "agent-".len + 16), r.name.len);
    // All hex chars in the suffix.
    for (r.name["agent-".len..]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Orchestrator defaults preserved.
    try std.testing.expectEqualStrings("default-model", r.model);
    try std.testing.expectEqualStrings("https://default.example.com", r.base_url);
    try std.testing.expectEqualStrings("default-key", r.api_key);
    try std.testing.expectEqualStrings("anthropic", r.url_style);
    // No specialized system_prompt.
    try std.testing.expectEqualStrings("", r.system_prompt);
    try std.testing.expectEqual(@as(?bool, null), r.is_thinking);
    try std.testing.expectEqual(@as(?f32, null), r.temperature);
    try std.testing.expectEqualStrings("", r.source);
}

test "resolveSubAgent: overlay — empty SubAgentConfig field falls through to orchestrator" {
    // Sub-agent has `model` but no `api_key` / `base_url`. Resolve
    // and verify the orchestrator's values are used for the empty
    // fields (NOT the empty string from the SubAgentConfig).
    const json_body =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "url_style": "openai",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "minimal", "model": "gpt-4o",
        \\          "base_url": "", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "", "api_key": "", "system_prompt": "" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json_body, "profile1", "minimal");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expect(!r.is_random_fallback);
    try std.testing.expectEqualStrings("gpt-4o", r.model); // from SubAgentConfig
    try std.testing.expectEqualStrings("https://default.example.com", r.base_url); // orchestrator
    try std.testing.expectEqualStrings("default-key", r.api_key); // orchestrator
    try std.testing.expectEqualStrings("openai", r.url_style); // orchestrator
    try std.testing.expectEqual(@as(?bool, null), r.is_thinking); // "auto" -> inherit
    try std.testing.expectEqual(@as(?f32, null), r.temperature); // "auto" -> inherit
}

test "resolveSubAgent: thinking \"true\" -> Some(true), \"false\" -> Some(false)" {
    const json_true =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "profiles_models": { "p1": {
        \\    "model": "m", "base_url": "u", "thinking": "auto",
        \\    "temperature": "auto", "url_style": "openai", "api_key": "k",
        \\    "sub_agents": [{ "name": "sa", "model": "m",
        \\      "base_url": "u", "thinking": "true", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "p" }] } } }
    ;
    var pair_true = try resolveFromProfile(json_true, "p1", "sa");
    defer pair_true.cfg.deinit();
    try std.testing.expectEqual(@as(?bool, true), pair_true.resolved.is_thinking);

    const json_false =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "profiles_models": { "p1": {
        \\    "model": "m", "base_url": "u", "thinking": "auto",
        \\    "temperature": "auto", "url_style": "openai", "api_key": "k",
        \\    "sub_agents": [{ "name": "sa", "model": "m",
        \\      "base_url": "u", "thinking": "false", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "p" }] } } }
    ;
    var pair_false = try resolveFromProfile(json_false, "p1", "sa");
    defer pair_false.cfg.deinit();
    try std.testing.expectEqual(@as(?bool, false), pair_false.resolved.is_thinking);
}

test "resolveSubAgent: temperature \"0.7\" parses to Some(0.7)" {
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "profiles_models": { "p1": {
        \\    "model": "m", "base_url": "u", "thinking": "auto",
        \\    "temperature": "auto", "url_style": "openai", "api_key": "k",
        \\    "sub_agents": [{ "name": "sa", "model": "m",
        \\      "base_url": "u", "thinking": "auto", "temperature": "0.7",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "p" }] } } }
    ;
    var pair = try resolveFromProfile(json_body, "p1", "sa");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expect(r.temperature != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), r.temperature.?, 0.0001);
}

test "resolveSubAgent: temperature garbage -> null (treat as auto)" {
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "sa", "model": "m",
        \\    "base_url": "u", "thinking": "auto", "temperature": "garbage",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair = try resolveFromTopLevel(json_body, "sa");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expectEqual(@as(?f32, null), r.temperature);
}

test "resolveSubAgent: top-level sub_agents list is empty -> miss fallback" {
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [] }
    ;
    var pair = try resolveFromTopLevel(json_body, "anything");
    defer pair.cfg.deinit();
    const r = pair.resolved;
    try std.testing.expect(r.is_random_fallback);
    try std.testing.expectEqualStrings("anything", r.requested_name);
    try std.testing.expectEqualStrings("m", r.model);
}

test "resolveSubAgent: two per-profile sub_agents, the second one matches" {
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "profiles_models": { "p1": {
        \\    "model": "m", "base_url": "u", "thinking": "auto",
        \\    "temperature": "auto", "url_style": "openai", "api_key": "k",
        \\    "sub_agents": [
        \\      { "name": "first", "model": "M1", "base_url": "u",
        \\        "thinking": "auto", "temperature": "auto",
        \\        "url_style": "openai", "api_key": "k", "system_prompt": "sp1" },
        \\      { "name": "second", "model": "M2", "base_url": "u",
        \\        "thinking": "auto", "temperature": "auto",
        \\        "url_style": "openai", "api_key": "k", "system_prompt": "sp2" }
        \\    ] } } }
    ;
    var pair1 = try resolveFromProfile(json_body, "p1", "first");
    defer pair1.cfg.deinit();
    try std.testing.expect(!pair1.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("M1", pair1.resolved.model);
    try std.testing.expectEqualStrings("sp1", pair1.resolved.system_prompt);
    var pair2 = try resolveFromProfile(json_body, "p1", "second");
    defer pair2.cfg.deinit();
    try std.testing.expect(!pair2.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("M2", pair2.resolved.model);
    try std.testing.expectEqualStrings("sp2", pair2.resolved.system_prompt);
}

test "resolveSubAgent: name match is exact (case-sensitive)" {
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "profiles_models": { "p1": {
        \\    "model": "m", "base_url": "u", "thinking": "auto",
        \\    "temperature": "auto", "url_style": "openai", "api_key": "k",
        \\    "sub_agents": [{ "name": "Reviewer", "model": "M1",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "p" }] } } }
    ;
    var pair_match = try resolveFromProfile(json_body, "p1", "Reviewer");
    defer pair_match.cfg.deinit();
    try std.testing.expect(!pair_match.resolved.is_random_fallback);
    var pair_miss = try resolveFromProfile(json_body, "p1", "reviewer");
    defer pair_miss.cfg.deinit();
    try std.testing.expect(pair_miss.resolved.is_random_fallback);
}

// ---------------------------------------------------------------------------
// resolveSubAgent — per-profile sub_agents lookup (decision #1)
// ---------------------------------------------------------------------------

test "resolveSubAgent: per-profile sub_agent is preferred over top-level" {
    // profile1 has its own "reviewer" with a specialized model;
    // the top-level "reviewer" uses a different model. The
    // per-profile hit must win.
    const json_body =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level reviewer" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1_MODEL", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "PROFILE1_MODEL",
        \\          "base_url": "u", "thinking": "true", "temperature": "0.5",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "profile1 reviewer" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json_body, "profile1", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.name);
    // Per-profile hit: PROFILE1_MODEL wins, not TOP_MODEL.
    try std.testing.expectEqualStrings("PROFILE1_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("profile1 reviewer", pair.resolved.system_prompt);
    try std.testing.expectEqualStrings("profile1", pair.resolved.source);
}

test "resolveSubAgent: empty profile inherits top-level via load migration" {
    // profile1 has no sub_agents of its own; the load migration (plan
    // 2026-09-04-subagents-per-profile) copies the top-level "reviewer" into
    // it.
    const json_body =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": { "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k" }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json_body, "profile1", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    // Migrated entry: TOP_MODEL wins, source is the profile.
    try std.testing.expectEqualStrings("TOP_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("profile1", pair.resolved.source);
}

test "resolveSubAgent: empty profile_name -> random fallback (no global list)" {
    // The call passes `""` for `profile_name` (e.g. the parent session has no
    // profile selected). Per-profile-only means there is nothing to consult —
    // random fallback, even though profile1 owns a matching "reviewer".
    const json_body =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "P1_MODEL",
        \\          "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "profile1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    // Note: resolveFromTopLevel passes "" as profile_name, so no
    // profile list is consulted — random fallback.
    var pair = try resolveFromTopLevel(json_body, "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.requested_name);
}

test "resolveSubAgent: profile_name not in profiles_models -> random fallback" {
    // The user requested a profile that doesn't exist; with no
    // global list there is nothing to fall back to.
    const json_body =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "profiles_models": {
        \\    "profile1": { "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "P1_MODEL",
        \\          "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "profile1" }
        \\      ] }
        \\  }
        \\}
    ;
    // profile_name "profile_unknown" is not in profiles_models;
    // random fallback (the unknown profile owns nothing).
    var pair = try resolveFromProfile(json_body, "profile_unknown", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.requested_name);
}

test "resolveSubAgent: per-profile miss AND top-level miss -> random fallback" {
    const json_body =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "other", "model": "M", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "p" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "diff_name", "model": "M",
        \\          "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "p" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json_body, "profile1", "reviewer");
    defer pair.cfg.deinit();
    // Neither profile1.sub_agents (has "diff_name") nor top-level
    // (has "other") contains "reviewer" -> random fallback.
    try std.testing.expect(pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.requested_name);
    try std.testing.expectEqualStrings("default", pair.resolved.model);
    try std.testing.expectEqualStrings("", pair.resolved.source);
}

// ---------------------------------------------------------------------------
// Auto-init: writeDefaultConfig() bootstrap helper (Chunk 1)
// ---------------------------------------------------------------------------

test "writeDefaultConfig creates a valid JSON config file at the given path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    // Build an absolute path inside the tmp dir; the file does not exist yet.
    const full_path = try std.fs.path.join(allocator, &.{ base_path, "config.json" });
    defer allocator.free(full_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, full_path);

    // Read it back and verify the JSON shape.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, full_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
    // defaults are GONE from the default file. Profiles + operational
    // settings only.
    try std.testing.expect(obj.get("api_key") == null);
    try std.testing.expect(obj.get("model") == null);
    try std.testing.expect(obj.get("base_url") == null);
    try std.testing.expect(obj.get("url_style") == null);
    try std.testing.expect(obj.get("profiles_models") != null);
    try std.testing.expectEqual(@as(i64, 100), obj.get("model_compaction_size_kb").?.integer);
    try std.testing.expectEqual(@as(bool, false), obj.get("notify_on_complete").?.bool);
    // Plan 2026-07-07-compaction-inline: the top-level
    // `max_capacity_token_model` and `compaction_threshold_percent` fields
    // are RESTORED.
    try std.testing.expect(obj.get("max_capacity_token_model").? == .null);
    try std.testing.expect(obj.get("compaction_threshold_percent").? == .null);
}

test "writeDefaultConfig creates parent directories that do not exist" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    // Path includes a 2-level deep parent that does NOT exist yet.
    const nested_path = try std.fs.path.join(allocator, &.{ base_path, "deep", "nested", "config.json" });
    defer allocator.free(nested_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, nested_path);

    // Verify the file was written and is readable.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, nested_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    // Plan 2026-08-24-config-simplify-remove-defaults: no top-level
    // api_key in the default file anymore.
    try std.testing.expect(std.mem.indexOf(u8, content, "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"profiles_models\"") != null);
}

// ---------------------------------------------------------------------------
// Auto-init: LlmConfig.init() creates default config on first run (Chunk 2)
// ---------------------------------------------------------------------------

test "init auto-creates config.json when default path does not exist (path=null)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir — this becomes our fake
    // $HOME / $XDG_CONFIG_HOME / %APPDATA% depending on platform.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base_path);
    try env_map.put("XDG_CONFIG_HOME", base_path);
    try env_map.put("APPDATA", base_path);

    // Call init() with path = null. The default config path resolves via
    // getDefaultConfigPath to a platform-appropriate location (e.g.
    var cfg = try LlmConfig.init(allocator, std.testing.io, null, &env_map);
    defer cfg.deinit();

    // Post-condition: the file now exists on disk and contains the default
    // template.
    const expected_path = try getDefaultConfigPath(allocator, &env_map);
    defer allocator.free(expected_path);

    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"profiles_models\": {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"model_compaction_size_kb\": 100") != null);
    // Plan 2026-07-15-retry-delay: top-level `retry_delay_ms` is
    // auto-created as 0 (the documented default = no delay).
    try std.testing.expect(std.mem.indexOf(u8, content, "\"retry_delay_ms\": 0") != null);
    // Plan 2026-07-07-compaction-inline: top-level `max_capacity_token_model`
    // and `compaction_threshold_percent` are RESTORED as null defaults in the
    // auto-created file. The loader sees them as the cascade wildcard.
    try std.testing.expect(std.mem.indexOf(u8, content, "max_capacity_token_model") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "compaction_threshold_percent") != null);
}

test "init does NOT auto-create when explicit path is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];
    const missing_path = try std.fs.path.join(allocator, &.{ base_path, "nope.json" });
    defer allocator.free(missing_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base_path);
    try env_map.put("XDG_CONFIG_HOME", base_path);
    try env_map.put("APPDATA", base_path);

    // Explicit path arg (non-null) — must surface ConfigFileNotFound, NOT
    // silently auto-create.
    const result = LlmConfig.init(allocator, std.testing.io, missing_path, &env_map);
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

test "init does NOT auto-create when file exists with parse error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write invalid JSON to the existing file FIRST (realPathFileAlloc
    // requires the file to exist; mirrors the order used by the
    // existing writeAndRead helper above).
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "not json{",
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(config_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");

    // File exists → auto-init must NOT run; the parse error surfaces. Note:
    // `LlmConfig.init` logs via std.log.err on this path for production
    // observability.
    const result = LlmConfig.init(allocator, std.testing.io, config_path, &env_map);
    try std.testing.expectError(error.InvalidJson, result);

    // The original file content must be unchanged (no auto-create ran).
    var read_buf: [4096]u8 = undefined;
    const content_slice = try tmp.dir.readFile(std.testing.io, "config.json", &read_buf);
    try std.testing.expectEqualStrings("not json{", content_slice);
}

// ---------------------------------------------------------------------------
// Compaction overrides: max_capacity_token_model +
// compaction_threshold_percent (configurable compaction settings — see

test "LlmConfig: LlmProfile.max_capacity_tokens reads value from JSON" {
    const allocator = std.testing.allocator;

    // NOTE: `profiles_models` is a real JSON map (matches the shape the UI
    // sends). The legacy `profile1..profile4` keys are convenience shorthands
    // for tests; both shapes parse to the same internal `ProfilesMap`.
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "max_capacity_tokens": 128000 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u32, 128000), profile.max_capacity_tokens);
}

test "LlmConfig: LlmProfile.max_capacity_tokens defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u32, null), profile.max_capacity_tokens);
}

test "LlmConfig: LlmProfile.compaction_threshold_percent reads value from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "compaction_threshold_percent": 70 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u8, 70), profile.compaction_threshold_percent);
}

test "LlmConfig: LlmProfile.compaction_threshold_percent defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u8, null), profile.compaction_threshold_percent);
}

test "LlmConfig: maxCapacityForModel returns profile override when set" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3", "max_capacity_tokens": 1000000 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile override wins over the LLMModels built-in.
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel(&profile, null, null, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel(&profile, null, null, "SomeOtherModel"));
}

test "LlmConfig: maxCapacityForModel falls back to LLMModels default when profile has null" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // MiniMax-M3 default is 500_000 (see LLMModels.zig:18).
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(&profile, null, null, "MiniMax-M3"));
    // Unknown model falls back to 200_000 (LLMModels.zig:31).
    try std.testing.expectEqual(@as(u32, 200000), cfg.maxCapacityForModel(&profile, null, null, "Unknown"));
    // No profile at all: same default applies.
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(null, null, null, "MiniMax-M3"));
}

test "LlmConfig: compactionThresholdPercent returns profile override when set" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "compaction_threshold_percent": 50 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(&profile, null, null));
}

test "LlmConfig: compactionThresholdPercent returns 80 when no profile / null profile" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile has null threshold — falls back to built-in 80.
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(&profile, null, null));
    // No profile at all — same default.
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

// ============================================================ Top-level
// defaults round-trip + cascade tests (restored in plan
// 2026-07-07-compaction-inline)

test "LlmConfig: top-level max_capacity_token_model reads from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "max_capacity_token_model": 250000 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 250000), cfg.max_capacity_token_model);
}

test "LlmConfig: top-level max_capacity_token_model defaults to null when missing" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, null), cfg.max_capacity_token_model);
}

test "LlmConfig: top-level compaction_threshold_percent reads from JSON" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "compaction_threshold_percent": 70 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, 70), cfg.compaction_threshold_percent);
}

test "LlmConfig: top-level compaction_threshold_percent defaults to null when missing" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, null), cfg.compaction_threshold_percent);
}

test "LlmConfig: top-level defaults cascade — profile override wins" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 200000,
        \\  "compaction_threshold_percent": 70,
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3",
        \\      "max_capacity_tokens": 600000,
        \\      "compaction_threshold_percent": 90 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile override (600_000) wins over top-level defaults (200_000).
    try std.testing.expectEqual(@as(u32, 600000), cfg.maxCapacityForModel(&profile, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 90), cfg.compactionThresholdPercent(&profile, null, &cfg));
    // Without profile, top-level defaults apply.
    try std.testing.expectEqual(@as(u32, 200000), cfg.maxCapacityForModel(null, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 70), cfg.compactionThresholdPercent(null, null, &cfg));
}

test "LlmConfig: top-level defaults apply when profile is null (passes through)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 350000,
        \\  "compaction_threshold_percent": 65 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // No profile → top-level defaults apply (no LLMModels fallback).
    try std.testing.expectEqual(@as(u32, 350000), cfg.maxCapacityForModel(null, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 65), cfg.compactionThresholdPercent(null, null, &cfg));
}

test "LlmConfig: top-level defaults are skipped when defaults=null passed" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 200000,
        \\  "compaction_threshold_percent": 70 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // defaults=null skips step 3 → built-in LLMModels default applies.
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(null, null, null, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

// ---------------------------------------------------------------------------
// `active_profile` round-trip (plan 2026-08-06-set-active-profile-default)
// ---------------------------------------------------------------------------

test "active_profile: parses top-level 'active_profile' string from JSON" {
    // Regression for "set_active_profile not work too" — the field was
    // persisted by the PUT handler but dropped on load, so the workflow could
    // never see it.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "active_profile": "alpha"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.active_profile != null);
    try std.testing.expectEqualStrings("alpha", cfg.active_profile.?);
}

test "active_profile: missing key → null (back-compat with legacy configs)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.active_profile == null);
}

test "active_profile: empty string normalises to null" {
    // Defends against manual `""` JSON edits (matches the
    // `pabrik_config_put.zig` PUT coercion: empty string → null).
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "active_profile": ""
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.active_profile == null);
}

// ---------------------------------------------------------------------------
// profiles_models: arbitrary key names (not just profile1..profile4)
// Regression for "profile not selected as effective on demand"

test "profiles_models: arbitrary name 'alpha' is loaded" {
    // Pre-fix: ProfilesModelsJson hardcodes profile1..profile4 keys;
    //           `alpha` is silently dropped → cfg.profiles_models is empty.
    // Post-fix: `alpha` appears in cfg.profiles_models with its fields intact.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "alpha-model",
        \\      "base_url": "https://alpha.example.com",
        \\      "api_key": "alpha-key",
        \\      "thinking": "auto",
        \\      "temperature": "auto",
        \\      "url_style": "anthropic"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // The profile name must be preserved verbatim (no renaming to
    // profile1..profile4).
    const entry = cfg.profiles_models.getEntry("alpha");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("alpha-model", entry.?.value_ptr.model);
    try std.testing.expectEqualStrings("https://alpha.example.com", entry.?.value_ptr.base_url);
    try std.testing.expectEqualStrings("alpha-key", entry.?.value_ptr.api_key);
    try std.testing.expectEqualStrings("anthropic", entry.?.value_ptr.url_style);
}

test "profiles_models: numeric prefix name '900ribu' is loaded" {
    // The user's actual profile name (per /home/ginwa/.config/pabrik/config.json
    // at the time of the bug report). Pre-fix this returned null and
    // the workflow fell back to top-level config silently.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "default-key",
        \\  "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "profiles_models": {
        \\    "900ribu": {
        \\      "model": "MiniMax-M3",
        \\      "base_url": "https://api.example.com/v1",
        \\      "api_key": "user-key-900ribu",
        \\      "thinking": "auto",
        \\      "temperature": "auto",
        \\      "url_style": "openai"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const entry = cfg.profiles_models.getEntry("900ribu");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("MiniMax-M3", entry.?.value_ptr.model);
    try std.testing.expectEqualStrings("user-key-900ribu", entry.?.value_ptr.api_key);
}

test "profiles_models: multiple arbitrary names all loaded" {
    // Defends against the pre-fix schema only loading the first 4
    // named slots. Three user-named profiles must all be present.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "profiles_models": {
        \\    "alpha": { "model": "alpha-model", "api_key": "a-key" },
        \\    "beta": { "model": "beta-model", "api_key": "b-key" },
        \\    "gamma": { "model": "gamma-model", "api_key": "g-key" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 3), cfg.profiles_models.count());

    const a = cfg.profiles_models.getEntry("alpha");
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("alpha-model", a.?.value_ptr.model);

    const b = cfg.profiles_models.getEntry("beta");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("beta-model", b.?.value_ptr.model);

    const g = cfg.profiles_models.getEntry("gamma");
    try std.testing.expect(g != null);
    try std.testing.expectEqualStrings("gamma-model", g.?.value_ptr.model);
}

test "profiles_models: empty {} → cfg.profiles_models.count is 0" {
    // Pre-fix this passed (the schema decoded {} as 4 nulls which produced no
    // entries), but it's still worth pinning so the post-fix json.Value
    // iteration doesn't accidentally crash on an empty object.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "profiles_models": {}
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 0), cfg.profiles_models.count());
}

test "profiles_models: missing key → cfg.profiles_models.count is 0 (back-compat)" {
    // Legacy configs that never declared profiles_models must still
    // load cleanly. The post-fix `if (config_json.profiles_models) |…|`
    // short-circuits when the key is absent.
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 0), cfg.profiles_models.count());
}

// ---------------------------------------------------------------------------
// Top-level defaults backfill (plan
// 2026-08-24-config-simplify-remove-defaults) config.json no longer carries

test "backfill: missing top-level keys derived from active_profile" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "alpha-model",
        \\      "base_url": "https://alpha.example.com",
        \\      "api_key": "alpha-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "alpha"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("alpha-model", cfg.model);
    try std.testing.expectEqualStrings("https://alpha.example.com", cfg.base_url);
    try std.testing.expectEqualStrings("alpha-key", cfg.api_key);
    try std.testing.expectEqualStrings("anthropic", cfg.url_style);
}

test "backfill: present top-level keys win over profile values" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "top-key",
        \\  "model": "top-model",
        \\  "base_url": "https://top.example.com",
        \\  "url_style": "openai",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "alpha-model",
        \\      "base_url": "https://alpha.example.com",
        \\      "api_key": "alpha-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "alpha"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("top-model", cfg.model);
    try std.testing.expectEqualStrings("https://top.example.com", cfg.base_url);
    try std.testing.expectEqualStrings("top-key", cfg.api_key);
    try std.testing.expectEqualStrings("openai", cfg.url_style);
}

test "backfill: partial top-level keys — only empty fields are filled" {
    const allocator = std.testing.allocator;

    // model present, api_key absent → api_key backfilled, model untouched.
    const json_body =
        \\{
        \\  "model": "top-model",
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "alpha-model",
        \\      "base_url": "https://alpha.example.com",
        \\      "api_key": "alpha-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "alpha"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("top-model", cfg.model);
    try std.testing.expectEqualStrings("https://alpha.example.com", cfg.base_url);
    try std.testing.expectEqualStrings("alpha-key", cfg.api_key);
}

test "backfill: no active_profile and single profile → falls back to that profile" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "profiles_models": {
        \\    "solo": {
        \\      "model": "solo-model",
        \\      "base_url": "https://solo.example.com",
        \\      "api_key": "solo-key",
        \\      "url_style": "openai"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("solo-model", cfg.model);
    try std.testing.expectEqualStrings("https://solo.example.com", cfg.base_url);
    try std.testing.expectEqualStrings("solo-key", cfg.api_key);
}

test "backfill: no profiles at all → fields stay empty (first-run shape)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "model_compaction_size_kb": 100 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("", cfg.model);
    try std.testing.expectEqualStrings("", cfg.base_url);
    try std.testing.expectEqualStrings("", cfg.api_key);
}

test "backfill: active_profile names a missing profile → falls back to first entry" {
    const allocator = std.testing.allocator;

    // Single-profile fixture keeps the fallback deterministic (HashMap
    // iteration order is unspecified for multi-profile maps).
    const json_body =
        \\{
        \\  "profiles_models": {
        \\    "real": {
        \\      "model": "real-model",
        \\      "base_url": "https://real.example.com",
        \\      "api_key": "real-key",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "does_not_exist"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("real-model", cfg.model);
    try std.testing.expectEqualStrings("real-key", cfg.api_key);
}

test "backfill: url_style copied from profile even when default openai present" {
    const allocator = std.testing.allocator;

    // url_style key ABSENT from the file → parse default "openai".
    const json_body =
        \\{
        \\  "profiles_models": {
        \\    "anthropic-p": {
        \\      "model": "claude-x",
        \\      "base_url": "https://a.example.com",
        \\      "api_key": "a-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "anthropic-p"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("anthropic", cfg.url_style);
}

test "mcp_servers: enabled:false parses to disabled server" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world", "enabled": false }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expect(!server.enabled);
}

test "mcp_servers: missing enabled defaults to true" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expect(server.enabled);
}

test "mcp_servers: non-bool enabled is ignored (defaults true)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world", "enabled": "yes" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // Non-bool is ignored, not fatal — server still parses, enabled stays true.
    try std.testing.expect(cfg.hasMcpServer("hello"));
    const server = cfg.mcpServerConfig("hello").?;
    try std.testing.expect(server.enabled);
}

test "rebuildMcpServersParsed: disabled server round-trips enabled:false" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world", "enabled": false },
        \\    "world": { "command": "other-cmd" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // Sanity: typed map parsed the flag.
    try std.testing.expect(!cfg.mcpServerConfig("hello").?.enabled);
    try std.testing.expect(cfg.mcpServerConfig("world").?.enabled);

    // Trigger rebuild via a public mutator.
    try cfg.addMcpServerStdio(.{ .name = "newbie", .command = "cmd-new" });

    const mcp_val = cfg.mcpServers().?;
    const hello_obj = mcp_val.object.get("hello").?.object;
    const enabled_val = hello_obj.get("enabled") orelse return error.TestExpectedEqual;
    try std.testing.expect(enabled_val == .bool);
    try std.testing.expect(!enabled_val.bool);

    // New servers default enabled → omit-when-true.
    const newbie_obj = mcp_val.object.get("newbie").?.object;
    try std.testing.expect(newbie_obj.get("enabled") == null);
    try std.testing.expect(cfg.mcpServerConfig("newbie").?.enabled);
}

test "rebuildMcpServersParsed: enabled server omits enabled key" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "hello": { "command": "mcp-hello-world" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try cfg.addMcpServerStdio(.{ .name = "second", .command = "cmd-2" });

    const mcp_val = cfg.mcpServers().?;
    try std.testing.expect(mcp_val.object.get("hello").?.object.get("enabled") == null);
    try std.testing.expect(mcp_val.object.get("second").?.object.get("enabled") == null);
}

// ---------------------------------------------------------------------------
// tools: top-level default tool checklist (Tools tab, plan
// 2026-09-22-tools-menu-config-default-tools).

test "tools: missing key → null (legacy defaults, D2 absent)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.tools == null);
}

test "tools: explicit null → null (same as absent after parse)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b", "tools": null }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    try std.testing.expect(cfg.tools == null);
}

test "tools: present list parses into an owned slice and survives clone" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "tools": ["command", "read_file", "glob"] }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    try std.testing.expect(cfg.tools != null);
    try std.testing.expectEqual(@as(usize, 3), cfg.tools.?.len);
    try std.testing.expectEqualStrings("command", cfg.tools.?[0]);
    try std.testing.expectEqualStrings("read_file", cfg.tools.?[1]);
    try std.testing.expectEqualStrings("glob", cfg.tools.?[2]);

    // Clone deep-copies (owned by the clone's allocator, independent
    // pointers) — `parsed.deinit()` in init must not have left aliases.
    try std.testing.expect(cloned.tools != null);
    try std.testing.expectEqual(@as(usize, 3), cloned.tools.?.len);
    try std.testing.expect(cfg.tools.?[0].ptr != cloned.tools.?[0].ptr);
}

test "tools: empty array stays non-null with len 0 (D2 [] ≠ absent)" {
    const allocator = std.testing.allocator;

    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b", "tools": [] }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json_body);
    defer cfg.deinit();

    // The D2 distinction: `[]` must NOT collapse to null, or an
    // all-unchecked checklist would silently snap back to legacy defaults.
    try std.testing.expect(cfg.tools != null);
    try std.testing.expectEqual(@as(usize, 0), cfg.tools.?.len);
}

test "tools: wrong type (string) fails whole-config parse with InvalidJson" {
    const allocator = std.testing.allocator;

    // Typed field: a hand-edited non-array value is a hard parse error
    // (same failure mode as the other typed fields — plan §8).
    const json_body =
        \\{ "api_key": "k", "model": "m", "base_url": "b", "tools": "bash" }
    ;

    try std.testing.expectError(error.InvalidJson, writeAndRead(allocator, std.testing.io, json_body));
}

// ─── Skill Evals — the config toggle (default OFF) ───────────────────────
// These live inline rather than in config_test.zig because they exercise
// `LlmConfig.LlmConfigJson` and `parseApplyMode`, both of which are private

test "skill_evals defaults to disabled" {
    const cfg: SkillEvalsConfig = .{};
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, cfg.apply_mode);
    try std.testing.expectEqual(@as(u32, 8), cfg.max_skills_per_run);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_evals_per_day);
    try std.testing.expectEqual(@as(u32, 300), cfg.fact_lease_seconds);
    try std.testing.expect(cfg.include_listed_without_loading);
}

test "skill_evals is disabled when config.json omits the key entirely" {
    const allocator = std.testing.allocator;

    // The guarantee that matters for an existing install: a config written
    // before this feature existed must parse to exactly the old behaviour.
    const parsed = try std.json.parseFromSlice(LlmConfig.LlmConfigJson, allocator,
        \\{"model":"m","provider":"p"}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.skill_evals.enabled);
    try std.testing.expect(parsed.value.skill_evals.apply_mode == null);
}

test "skill_evals defaults to disabled when the block is present but empty" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(LlmConfig.LlmConfigJson, allocator,
        \\{"skill_evals":{}}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.skill_evals.enabled);
    // The non-switch knobs still get their documented defaults, so turning the
    // switch on alone is enough to get a safe, bounded configuration.
    try std.testing.expectEqual(@as(u32, 8), parsed.value.skill_evals.max_skills_per_run);
    try std.testing.expectEqual(@as(u32, 300), parsed.value.skill_evals.fact_lease_seconds);
}

test "skill_evals honours an explicit opt-in" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(LlmConfig.LlmConfigJson, allocator,
        \\{"skill_evals":{"enabled":true,"max_skills_per_run":3,"apply_mode":"off"}}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.skill_evals.enabled);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.skill_evals.max_skills_per_run);
    try std.testing.expectEqualStrings("off", parsed.value.skill_evals.apply_mode.?);
}

test "defaultConfigJson ships the feature off and still parses" {
    const allocator = std.testing.allocator;

    // The file `Config.init` writes for a brand-new install. Parsing it back
    // must succeed (a template that does not round-trip would break startup)
    // and must leave the feature off.
    const parsed = try std.json.parseFromSlice(
        LlmConfig.LlmConfigJson,
        allocator,
        LlmConfig.defaultConfigJson,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.skill_evals.enabled);
    try std.testing.expectEqual(@as(u32, 8), parsed.value.skill_evals.max_skills_per_run);
    try std.testing.expectEqual(@as(u32, 10), parsed.value.skill_evals.max_evals_per_day);
    try std.testing.expectEqual(@as(u32, 300), parsed.value.skill_evals.fact_lease_seconds);
    try std.testing.expect(parsed.value.skill_evals.include_listed_without_loading);
    try std.testing.expectEqualStrings("propose", parsed.value.skill_evals.apply_mode.?);
}

test "an unrecognised apply_mode degrades to propose instead of failing the parse" {
    const allocator = std.testing.allocator;

    // `apply_mode` is a nullable string on the JSON side precisely so a typo
    // here cannot make the user's whole config.json unloadable. This test
    // pins both halves of that: the parse succeeds, and the mapping is safe.
    const parsed = try std.json.parseFromSlice(LlmConfig.LlmConfigJson, allocator,
        \\{"skill_evals":{"enabled":true,"apply_mode":"proposal"}}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.skill_evals.enabled);
    try std.testing.expectEqualStrings("proposal", parsed.value.skill_evals.apply_mode.?);
    try std.testing.expectEqual(
        SkillEvalsConfig.ApplyMode.propose,
        parseApplyMode(parsed.value.skill_evals.apply_mode),
    );
}

test "parseApplyMode maps the known values and is safe on absent input" {
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, parseApplyMode(null));
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.off, parseApplyMode("off"));
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.auto_low_risk, parseApplyMode("auto_low_risk"));
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, parseApplyMode("propose"));
    // Unknown, empty and wrong-case all land on the safe default.
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, parseApplyMode("PROPOSE"));
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, parseApplyMode(""));
    try std.testing.expectEqual(SkillEvalsConfig.ApplyMode.propose, parseApplyMode("nonsense"));
}

// ───────────────────── tests: web_search provider config (Task 1) ──────────

/// Parse a `web_search` body the way `init` does, then free it. Returns an
/// owned map the caller must release with `freeTestProviders`.
fn parseTestProviders(
    allocator: std.mem.Allocator,
    body: []const u8,
) !LlmConfig.WebSearchProvidersMap {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    return LlmConfig.parseWebSearchProvidersMap(allocator, parsed.value);
}

fn freeTestProviders(m: *LlmConfig.WebSearchProvidersMap, allocator: std.mem.Allocator) void {
    LlmConfig.freeWebSearchProvidersMap(m, allocator);
}

test "web_search: a two-provider map round-trips every string field" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"tinyfish":{"url":"https://api.search.tinyfish.ai","key":"skkkk",
        \\  "curl":"https://api.search.tinyfish.ai?query=X -H \"X-API-Key: {key}\"",
        \\  "description":"Best for news"},
        \\ "brave":{"url":"https://api.search.brave.com","key":"sk-brave",
        \\  "curl":"https://api.search.brave.com/res/v1/web/search?q=X","enabled":false}}
    );
    defer freeTestProviders(&providers, alloc);

    try std.testing.expectEqual(@as(usize, 2), providers.count());

    const tf = providers.get("tinyfish").?;
    try std.testing.expectEqualStrings("https://api.search.tinyfish.ai", tf.url);
    try std.testing.expectEqualStrings("skkkk", tf.key.?);
    try std.testing.expectEqualStrings("Best for news", tf.description.?);
    try std.testing.expect(tf.enabled);
    try std.testing.expect(tf.isUsable());

    const bv = providers.get("brave").?;
    try std.testing.expect(!bv.enabled);
    try std.testing.expect(!bv.isUsable());
}

test "web_search: `key` is optional — a self-hosted provider has none" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"searxng":{"url":"https://search.example.net",
        \\  "curl":"https://search.example.net/search?q=X&format=json"}}
    );
    defer freeTestProviders(&providers, alloc);

    const sx = providers.get("searxng").?;
    try std.testing.expectEqual(@as(?[]const u8, null), sx.key);
    try std.testing.expectEqual(@as(?[]const u8, null), sx.description);
    // No credential is fine — the provider is still usable.
    try std.testing.expect(sx.isUsable());
}

test "web_search: an empty-string key is normalised to absent, never stored" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"x":{"url":"https://e.com","key":"","curl":"https://e.com?q=X"}}
    );
    defer freeTestProviders(&providers, alloc);

    // `SqliteBackend.exec` binds "" as SQL NULL, so a blank credential is
    // the exact shape that survives a JSON round-trip while meaning unset.
    // Normalising it here keeps `isUsable` a single rule.
    try std.testing.expectEqual(@as(?[]const u8, null), providers.get("x").?.key);
}

test "web_search: an entry missing `url` or `curl` is skipped, siblings survive" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"no_url":{"key":"k","curl":"https://a.com?q=X"},
        \\ "no_curl":{"url":"https://b.com","key":"k"},
        \\ "numeric":{"url":123,"curl":"https://c.com?q=X"},
        \\ "good":{"url":"https://good.com","key":"k","curl":"https://good.com?q=X"}}
    );
    defer freeTestProviders(&providers, alloc);

    // One bad paste must not take every other provider down with it.
    try std.testing.expectEqual(@as(usize, 1), providers.count());
    try std.testing.expect(providers.get("good") != null);
    try std.testing.expect(providers.get("no_url") == null);
    try std.testing.expect(providers.get("no_curl") == null);
    try std.testing.expect(providers.get("numeric") == null);
}

test "web_search: non-string `key`/`description`/`enabled` degrade, not crash" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"p":{"url":"https://e.com","key":42,
        \\  "curl":"https://e.com?q=X","description":["a"],"enabled":"yes"}}
    );
    defer freeTestProviders(&providers, alloc);

    const p = providers.get("p").?;
    try std.testing.expectEqual(@as(?[]const u8, null), p.key);
    try std.testing.expectEqual(@as(?[]const u8, null), p.description);
    // A non-bool `enabled` means true, mirroring McpServerConfig.
    try std.testing.expect(p.enabled);
}

test "web_search: a non-object body yields an empty map, not an error" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc, "[1,2,3]");
    defer freeTestProviders(&providers, alloc);
    try std.testing.expectEqual(@as(usize, 0), providers.count());

    var empty = try parseTestProviders(alloc, "{}");
    defer freeTestProviders(&empty, alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.count());
}

test "web_search: the config `curl` keeps the literal {key} and never the secret" {
    const alloc = std.testing.allocator;
    var providers = try parseTestProviders(alloc,
        \\{"p":{"url":"https://e.com","key":"SENTINEL_SECRET_DO_NOT_LEAK",
        \\  "curl":"https://e.com?q=X -H \"X-API-Key: {key}\""}}
    );
    defer freeTestProviders(&providers, alloc);

    const p = providers.get("p").?;
    // The template carries the placeholder...
    try std.testing.expect(std.mem.indexOf(u8, p.curl, "{key}") != null);
    // ...and never the credential. This is the property that makes
    // `list_web_search_providers` safe to hand to the model with no
    // redaction logic at all.
    try std.testing.expect(std.mem.indexOf(u8, p.curl, "SENTINEL_SECRET_DO_NOT_LEAK") == null);
}

test "web_search: `isUsable` rejects an entry the dispatcher cannot run" {
    const base = LlmConfig.WebSearchProviderEntry{
        .url = "https://e.com",
        .curl = "https://e.com?q=X",
        .key = "k",
    };
    try std.testing.expect(base.isUsable());

    try std.testing.expect(!(LlmConfig.WebSearchProviderEntry{ .url = "", .curl = base.curl, .key = "k" }).isUsable());
    try std.testing.expect(!(LlmConfig.WebSearchProviderEntry{ .url = base.url, .curl = "", .key = "k" }).isUsable());
    try std.testing.expect(!(LlmConfig.WebSearchProviderEntry{ .url = base.url, .curl = base.curl, .key = "" }).isUsable());
    try std.testing.expect(!(LlmConfig.WebSearchProviderEntry{ .url = base.url, .curl = base.curl, .key = "k", .enabled = false }).isUsable());
}
