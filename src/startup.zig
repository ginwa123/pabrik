const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const logger_mod = pabrikcore.loggermod;
const config_mod = pabrikcore.config;
const ai_workflow = pabrikcore.ai_mod;

/// Startup handler - queries worker table and starts a thread for each worker Called once during app initialization to bootstrap workers from database
pub fn startup(
    allocator: std.mem.Allocator,
    ctxTui: *pabrikcore.App,
) !void {
    const sqlite_db = ctxTui.db;
    const logger = ctxTui.logger;

    // delete all workers this is temporrary
    ai_workflow.llm_history.deleteAllWorkers(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to delete all workers: {s}", .{@errorName(err)});
        return err;
    };

    ai_workflow.llm_history.deleteAllQueuedMessages(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to delete all queued messages: {s}", .{@errorName(err)});
        return err;
    };

    // Query all workers from the database
    const workers = ai_workflow.llm_history.getActiveWorker(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to query workers: {s}", .{@errorName(err)});
        return err;
    };
    defer {
        for (workers) |w| w.deinit(allocator);
        allocator.free(workers);
    }
}
