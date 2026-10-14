// Re-export all public tool definitions for convenience
pub const memories = @import("memories.zig");
pub const list_memory = @import("list_memory.zig");
pub const memory = @import("memory.zig");
pub const save_memory = memory;
pub const load_memory = memory;
pub const web_search = @import("web_search.zig");
pub const skill_tools = @import("skill_tools.zig");
pub const add_skill = skill_tools;
pub const pwsh = @import("pwsh.zig");
pub const edit_skill = skill_tools;
pub const semantic_search = @import("semantic_search.zig");
pub const set_git_worktree = @import("set_git_worktree.zig");
pub const set_pull_request = @import("set_pull_request.zig");
pub const status_pull_request = @import("status_pull_request.zig");
pub const pr_provider = @import("pr_provider.zig");

pub const list_memory_tool = list_memory.list_memory_tool;
pub const web_search_tool = web_search.web_search_tool;
pub const add_skill_tool = skill_tools.add_skill_tool;
pub const edit_skill_tool = skill_tools.edit_skill_tool;
pub const semantic_search_tool = semantic_search.semantic_search_tool;
pub const index_codebase_tool = semantic_search.index_codebase_tool;
pub const set_git_worktree_tool = set_git_worktree.set_git_worktree_tool;
pub const set_pull_request_tool = set_pull_request.set_pull_request_tool;
pub const status_pull_request_tool = status_pull_request.status_pull_request_tool;

// Path validation: `helpers.path_validate.invalidPathReason` is the single
// implementation, and every path-taking agent tool calls it before its first
// `std.fs` call. That guard is load-bearing on Windows, where a malformed NT
// name (`C:\foo*.txt`, `C:foo\bar`, a reserved device name) makes std's Io
// backend call `ntstatusBug()` and panic, taking the process with it — which is
// exactly why it cannot be observed from a Linux test.
//
// The validator's own case table (Windows-only names, NUL and control bytes,
// empty) lives in the tests beside it, in `remove_file.zig`. A new
// path-taking tool has to call the helper before its first `std.fs` call
// because nothing else will notice when it does not.
