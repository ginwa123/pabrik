const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration097CreateSkillEvalTables = struct {
    pub const version: u32 = 97;
    pub const name = "create_skill_eval_tables";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // ── the shared intrinsic-facts cache ──────────────────────────────
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_facts (
            \\    id TEXT PRIMARY KEY,
            \\    skill_key TEXT NOT NULL,
            \\    content_hash TEXT NOT NULL,
            \\    context_key TEXT NOT NULL,
            \\    verdict_intrinsic TEXT NOT NULL DEFAULT 'computing',
            \\    freshness INTEGER NOT NULL DEFAULT 0,
            \\    accuracy INTEGER NOT NULL DEFAULT 0,
            \\    duplication INTEGER NOT NULL DEFAULT 0,
            \\    findings_json TEXT NOT NULL DEFAULT '',
            \\    evidence_json TEXT NOT NULL DEFAULT '',
            \\    proposed_content TEXT NOT NULL DEFAULT '',
            \\    missing_paths_json TEXT NOT NULL DEFAULT '',
            \\    drift_commits_json TEXT NOT NULL DEFAULT '',
            \\    computed_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // The unique key IS the claim mechanism: a second writer for the same
        // (skill, content, context) cannot insert, so it reuses instead.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_facts ON skill_eval_facts(skill_key, content_hash, context_key)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_facts_skill ON skill_eval_facts(skill_key, computed_at DESC)",
            &[_][]const u8{});

        // ── one row per eval invocation ───────────────────────────────────
        // `sub_session_ids_json` exists so the run's token cost can be summed
        // exactly over the sub-agent session ids the spawn envelope returns,
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_runs (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL DEFAULT '',
            \\    skill_name TEXT NOT NULL DEFAULT '',
            \\    scope TEXT NOT NULL DEFAULT 'session',
            \\    trigger TEXT NOT NULL DEFAULT 'self_prompt',
            \\    status TEXT NOT NULL DEFAULT 'running',
            \\    profile TEXT NOT NULL DEFAULT '',
            \\    model TEXT NOT NULL DEFAULT '',
            \\    cwd TEXT NOT NULL DEFAULT '',
            \\    context_key TEXT NOT NULL DEFAULT '',
            \\    evidence_json TEXT NOT NULL DEFAULT '',
            \\    sub_session_ids_json TEXT NOT NULL DEFAULT '',
            \\    report_json TEXT NOT NULL DEFAULT '',
            \\    total_tokens INTEGER NOT NULL DEFAULT 0,
            \\    error TEXT NOT NULL DEFAULT '',
            \\    started_at DATETIME,
            \\    finished_at DATETIME,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    user_id TEXT
            \\)
        , &[_][]const u8{});

        // "At most one self-prompted run per session" is enforced by the
        // DATABASE, not by a convention, because the agent can emit two
        // `run_skill_eval` tool calls in a single turn and both would
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS uq_skill_eval_runs_self_prompt
            \\ON skill_eval_runs(session_id, trigger) WHERE trigger = 'self_prompt'
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_session ON skill_eval_runs(session_id, created_at DESC)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_runs_status ON skill_eval_runs(status, created_at DESC)",
            &[_][]const u8{});

        // ── per-(run, skill) session-relative half ────────────────────────
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_eval_results (
            \\    id TEXT PRIMARY KEY,
            \\    run_id TEXT NOT NULL,
            \\    skill_key TEXT NOT NULL,
            \\    skill_name TEXT NOT NULL,
            \\    session_id TEXT NOT NULL DEFAULT '',
            \\    status TEXT NOT NULL DEFAULT 'pending',
            \\    verdict TEXT NOT NULL DEFAULT 'needs_human',
            \\    relevance INTEGER NOT NULL DEFAULT 0,
            \\    used INTEGER NOT NULL DEFAULT 0,
            \\    helpfulness INTEGER NOT NULL DEFAULT 0,
            \\    confidence REAL NOT NULL DEFAULT 0,
            \\    intrinsic_fact_id TEXT NOT NULL DEFAULT '',
            \\    base_content_hash TEXT NOT NULL DEFAULT '',
            \\    content_at_use TEXT NOT NULL DEFAULT '',
            \\    proposed_diff TEXT NOT NULL DEFAULT '',
            \\    rationale TEXT NOT NULL DEFAULT '',
            \\    sub_session_id TEXT NOT NULL DEFAULT '',
            \\    applied_at DATETIME,
            \\    apply_action TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    user_id TEXT
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_run ON skill_eval_results(run_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_skill ON skill_eval_results(skill_key, created_at DESC)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_skill_eval_results_session ON skill_eval_results(session_id, created_at DESC)",
            &[_][]const u8{});
    }
};
