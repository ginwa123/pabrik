const std = @import("std");
const builtin = @import("builtin");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const pabrik = @import("pabrikcore");
const sqlite = pabrik.sqlite;
const git_hardening = @import("helpers").git_hardening;

/// Input structure for set_git_worktree tool
pub const SetGitWorktreeInput = struct {
    /// Absolute path to the worktree directory. The directory must NOT
    /// already exist (git worktree add will create it).
    path: []const u8 = "",
    /// REQUIRED. Absolute path to the REPOSITORY the worktree is created from
    /// — the directory `git worktree add` runs in.
    cwd: []const u8 = "",
    /// Optional branch name override. Defaults to `worktree/<basename(path)>`.
    /// Rarely needed — the default is consistent and predictable.
    branch: []const u8 = "",
    /// Optional base ref the new branch is created FROM, e.g. `origin/main`.
    base: []const u8 = "",
    /// When true, remove the existing worktree binding for this session
    /// AND delete the worktree directory. `path` is ignored when true.
    clear: bool = false,
    /// The session_id this worktree is bound to. The LLM does NOT
    /// supply this — the tool_registry execX wrapper injects
    /// `ctx.session_id` at call time.
    session_id: []const u8 = "",
};

/// Tool definition for set_git_worktree
pub const set_git_worktree_tool_system_prompt =
    \\## Set Git Worktree Tool — Behavior (MANDATORY when applicable)
    \\If you are creating a worktree, or the human requests a git worktree,
    \\you MUST call `set_git_worktree` before any `command`/`read_file`/`write_file`
    \\operation touches repo files. Never operate on the original repo path.
    \\
    \\- Canonical root (Option A): `$HOME/.config/pabrik/.worktrees/<task-slug>`.
    \\  Example: `/home/you/.config/pabrik/.worktrees/fix-login`.
    \\  The kanban dialog prefills this absolute path as the `Path:` line after
    \\  `#Notes UseGitWorktree`. Prefer it when given; when the note has no
    \\  `Path:` line, create the worktree under the same root derived from the
    \\  task name.
    \\- If a `Path:` value starts with `~/`, expand `~` to `$HOME` first —
    \\  `validatePath` rejects non-absolute paths.
    \\- The note may also carry a `Base: <ref>` line (e.g. `Base: origin/main`).
    \\  Pass that value as the `base` argument so the worktree branches FROM
    \\  that ref instead of the repo's current HEAD. Omit `base` when the note
    \\  has no `Base:` line.
    \\- `path` MUST NOT contain `..`.
    \\- The parent directory MUST exist.
    \\- Once set, all subsequent `command`/`read_file`/`write_file` operations run
    \\  inside that worktree.
    \\- Pass `clear=true` to remove the binding before switching or finishing.
    \\
;
pub const set_git_worktree_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_git_worktree",
        .description =
        \\Create a git worktree at an absolute path and bind it as this session's working directory — command/read_file/write_file/text_replace/glob/search then run inside it instead of the session's original cwd. The kanban dialog prefills the path under `$HOME/.config/pabrik/.worktrees/<task-slug>` after `#Notes UseGitWorktree`. Calling again with a different path switches the binding.
        \\
        \\On error: (1) "path already exists" means an existing worktree occupies the path — pass `branch=<existing-branch>` to auto-bind, or pick a different path; (2) on a branch conflict pass `branch=''` for the auto-derived name; (3) NEVER `rm -rf` a conflicting path — it may hold uncommitted work; inspect with `git -C <repo> worktree list --porcelain`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the worktree directory; its parent directory must already exist. Must be absolute, contain no '..' or null bytes, be ≤ 4096 chars, and have a basename matching [A-Za-z0-9._-]{1,100}. Expand a leading `~/` to `$HOME` before calling. Canonical root: `$HOME/.config/pabrik/.worktrees/<task-slug>`, e.g. '/home/you/.config/pabrik/.worktrees/fix-login'.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the repository the worktree is created from — where `git worktree add` runs. Ignored when clear=true.",
                },
                .{
                    .name = "branch",
                    .type = "string",
                    .description = "Optional branch name override. Defaults to 'worktree/<basename(path)>'. Rarely needed.",
                },
                .{
                    .name = "base",
                    .type = "string",
                    .description = "Optional ref the new branch is created FROM, e.g. 'origin/main'. Take it verbatim from the task note's `Base:` line; omit when there is none (the branch then starts at the repo's current HEAD).",
                },
                .{
                    .name = "clear",
                    .type = "boolean",
                    .description = "If true, remove the worktree directory and clear the binding. 'path' is ignored when clear=true. Default: false.",
                },
            },
            .required = &.{"cwd"},
        },
        .system_prompt = set_git_worktree_tool_system_prompt,
    },
};

/// Validate an absolute worktree path. Returns null on success, or an
/// error message on failure. Pure function — no IO. Also validates
/// the basename (which becomes the auto-derived branch name).
pub fn validatePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 4096) return "path exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return "path contains null byte";
    if (!std.fs.path.isAbsolute(path)) return "path must be absolute";
    if (std.mem.indexOf(u8, path, "..") != null) return "path must not contain '..' segments";

    // Basename must be a legal branch name fragment.
    const basename = std.fs.path.basename(path);
    if (validateBasename(basename)) |err_msg| return err_msg;
    return null;
}

/// Validate a basename (used both by `validatePath` and as a stand-alone
/// check for the auto-derived branch name). Returns null on success.
pub fn validateBasename(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "basename cannot be empty";
    if (name.len > 100) return "basename exceeds 100 characters";
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return "basename contains invalid character (allowed: A-Za-z0-9._-)";
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return "basename cannot be '.' or '..'";
    }
    return null;
}

/// Validate an optional `base` ref (e.g. `origin/main`). Empty is valid and
/// means "branch from the repo's current HEAD".
pub fn validateBaseRef(base: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    if (base.len > 255) return "base exceeds 255 characters";
    if (base[0] == '-') return "base must not start with '-'";
    if (base[0] == '/') return "base must not start with '/'";
    if (base[base.len - 1] == '/') return "base must not end with '/'";
    if (std.mem.indexOf(u8, base, "..") != null) return "base must not contain '..'";
    if (std.mem.indexOf(u8, base, "//") != null) return "base must not contain '//'";
    if (std.mem.indexOf(u8, base, "@{") != null) return "base must not contain '@{'";
    if (std.mem.endsWith(u8, base, ".lock")) return "base must not end with '.lock'";
    if (std.mem.eql(u8, base, "@")) return "base must not be '@'";
    for (base) |c| {
        const bad = c <= 0x20 or c == 0x7f or c == '~' or c == '^' or
            c == ':' or c == '?' or c == '*' or c == '[' or c == '\\';
        if (bad) return "base contains an invalid character (no spaces, '~', '^', ':', '?', '*', '[', '\\')";
    }
    return null;
}

/// Build the argv for `git worktree add`.
pub fn buildWorktreeAddArgv(
    allocator: std.mem.Allocator,
    branch: []const u8,
    worktree_path: []const u8,
    base: []const u8,
) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try git_hardening.appendGit(&argv, allocator);
    try argv.appendSlice(allocator, &.{ "worktree", "add", "-b", branch, worktree_path });
    if (base.len > 0) try argv.append(allocator, base);
    return argv.toOwnedSlice(allocator);
}

/// Pure helper: derive the default branch name from an absolute worktree
/// path. Returns `worktree/<basename>`. Caller frees the result.
pub fn deriveBranchFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const basename = std.fs.path.basename(path);
    return try std.fmt.allocPrint(allocator, "worktree/{s}", .{basename});
}

/// Classified state of a candidate worktree path. Returned by `classifyPath`.
pub const PathState = union(enum) {
    /// Path does not exist on disk. Git worktree add will create it.
    not_found,
    /// Path exists but has no `.git` file — a plain leftover directory.
    plain_directory: []const u8,
    /// Path exists, has a worktree-shaped `.git` file, and the admin
    /// directory that file points at is GONE — so git positively cannot know
    /// about it.
    orphaned_worktree: []const u8,
    /// Path exists AND is a registered worktree. All strings are owned
    /// by this struct.
    registered_worktree: RegisteredWorktree,
    /// Path exists and has a `.git` file, but neither registration nor
    /// orphanhood could be established.
    unverified_worktree: UnverifiedWorktree,

    pub const RegisteredWorktree = struct {
        /// Branch reference as reported by git, e.g. `refs/heads/refactor/x`.
        /// Empty string when the worktree is in detached HEAD state.
        branch_ref: []const u8,
        /// Short branch name (branch_ref minus the `refs/heads/` prefix),
        /// or empty string when detached.
        branch: []const u8,
        /// HEAD commit SHA (40 hex chars).
        commit: []const u8,
        /// Absolute path of the worktree.
        path: []const u8,
    };

    pub const UnverifiedWorktree = struct {
        /// The admin directory the `.git` file points at (trimmed).
        gitdir: []const u8,
        /// Why the verdict could not be reached, e.g. "git worktree list
        /// could not be run". Shown to the model verbatim.
        reason: []const u8,
    };
};

/// Classify the state of `target` relative to the git worktree system rooted
/// at `repo_root`. Pure (no side effects beyond the returned allocations).
pub fn classifyPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    target: []const u8,
) !PathState {
    // ── 1. Does `target` exist on disk? ──────────────────────────────
    std.Io.Dir.cwd().access(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => {
            // Permission denied, etc. — treat as "exists but unreadable".
            // We can't classify further without disk access.
            return .{
                .plain_directory = try std.fmt.allocPrint(
                    allocator,
                    "path exists but is unreadable: {s}",
                    .{@errorName(err)},
                ),
            };
        },
    };

    // ── 2. Read the `.git` file — the worktree's own claim about itself ──
    const git_path = std.fs.path.joinZ(allocator, &.{ target, ".git" }) catch {
        return .{ .plain_directory = try allocator.dupe(u8, "unclassifiable") };
    };
    defer allocator.free(git_path);

    const git_contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        git_path,
        allocator,
        .limited(std.Io.Dir.max_path_bytes),
    ) catch {
        // No .git file → plain directory.
        return .{ .plain_directory = try std.fmt.allocPrint(
            allocator,
            "plain directory at {s}",
            .{target},
        ) };
    };
    defer allocator.free(git_contents);

    const gitdir = parseGitdirPointer(git_contents) orelse {
        // .git file is malformed (e.g. raw gitdir without "gitdir: " prefix).
        return .{ .plain_directory = try std.fmt.allocPrint(
            allocator,
            "malformed .git file at {s}: {s}",
            .{ target, git_contents },
        ) };
    };

    // ── 3.
    if (worktreeAdminDir(gitdir)) |admin_dir| {
        const admin_exists = directoryExists(io, admin_dir);
        if (admin_exists == true) {
            return .{ .registered_worktree = try registeredFromAdminDir(
                allocator,
                io,
                admin_dir,
                target,
            ) };
        }
        if (admin_exists == false) {
            // The registration record is gone: git positively cannot
            // know about this directory. That is the ONLY evidence
            // that justifies the orphaned verdict.
            return .{ .orphaned_worktree = try allocator.dupe(u8, gitdir) };
        }
        // Exists-but-unreadable is not the same as gone, and must not be
        // reported as gone.
        return .{ .unverified_worktree = .{
            .gitdir = try allocator.dupe(u8, gitdir),
            .reason = try std.fmt.allocPrint(
                allocator,
                "the admin directory {s} exists but could not be read",
                .{admin_dir},
            ),
        } };
    }

    // ── 4. A `.git` file that points elsewhere (a submodule gitlink) ────
    //    Ask git — but only a COMPLETE listing can settle it.
    var list = runGitWorktreeList(allocator, io, repo_root) catch |err| {
        return .{ .unverified_worktree = .{
            .gitdir = try allocator.dupe(u8, gitdir),
            .reason = try std.fmt.allocPrint(
                allocator,
                "git worktree list could not be read ({s})",
                .{@errorName(err)},
            ),
        } };
    };
    defer list.deinit(allocator);

    if (parseWorktreeList(allocator, list.stdout, target) catch |err| return err) |rwt| {
        return .{ .registered_worktree = rwt };
    }
    if (list.health == .complete) {
        return .{ .plain_directory = try std.fmt.allocPrint(
            allocator,
            ".git file points at {s}, which is not a linked worktree",
            .{gitdir},
        ) };
    }
    return .{ .unverified_worktree = .{
        .gitdir = try allocator.dupe(u8, gitdir),
        .reason = try allocator.dupe(u8, list.reason),
    } };
}

/// Does `path` exist? `null` means "could not tell" (e.g. permission
/// denied) — deliberately NOT "does not exist", because an admin
/// directory we cannot read must not be reported as a missing one.
fn directoryExists(io: std.Io, path: []const u8) ?bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return null,
    };
    return true;
}

/// Parse the payload of a `.git` FILE (as opposed to a `.git` directory).
pub fn parseGitdirPointer(contents: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir: ")) return null;
    const path = std.mem.trim(u8, trimmed["gitdir: ".len..], " \t\r\n");
    if (path.len == 0) return null;
    return path;
}

/// When `gitdir` is the admin directory of a LINKED WORKTREE
/// (`<repo>/.git/worktrees/<name>`), return that slice. Otherwise null.
pub fn worktreeAdminDir(gitdir: []const u8) ?[]const u8 {
    // `splitBackwardsAny` yields an EMPTY leading component for a trailing
    // separator ("…/worktrees/foo/" → "", "foo", "worktrees"), so trim the
    // trailing separators first and hand back the trimmed path — that is also
    var end = gitdir.len;
    while (end > 0 and isPathSep(gitdir[end - 1])) end -= 1;
    if (end == 0) return null;

    var it = std.mem.splitBackwardsAny(u8, gitdir[0..end], "/\\");
    const name = it.next() orelse return null;
    if (name.len == 0) return null;
    const worktrees = it.next() orelse return null;
    if (!std.mem.eql(u8, worktrees, "worktrees")) return null;
    const dot_git = it.next() orelse return null;
    if (!std.mem.eql(u8, dot_git, ".git")) return null;
    return gitdir[0..end];
}

/// Build a `RegisteredWorktree` from a worktree's admin directory, reading
/// `<admin>/HEAD` for the branch.
fn registeredFromAdminDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    admin_dir: []const u8,
    worktree_path: []const u8,
) !PathState.RegisteredWorktree {
    const head_path = std.fs.path.joinZ(allocator, &.{ admin_dir, "HEAD" }) catch
        return emptyRegistered(allocator, worktree_path);
    defer allocator.free(head_path);

    const head = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch
        return emptyRegistered(allocator, worktree_path);
    defer allocator.free(head);

    const ref = std.mem.trim(u8, head, " \t\r\n");
    if (!std.mem.startsWith(u8, ref, "ref: ")) {
        // Detached HEAD: the file holds the SHA itself.
        return .{
            .branch_ref = try allocator.dupe(u8, ""),
            .branch = try allocator.dupe(u8, ""),
            .commit = try allocator.dupe(u8, ref),
            .path = try allocator.dupe(u8, worktree_path),
        };
    }
    const branch_ref = std.mem.trim(u8, ref["ref: ".len..], " \t\r\n");
    const short = if (std.mem.startsWith(u8, branch_ref, "refs/heads/"))
        branch_ref["refs/heads/".len..]
    else
        branch_ref;
    return .{
        .branch_ref = try allocator.dupe(u8, branch_ref),
        .branch = try allocator.dupe(u8, short),
        .commit = try allocator.dupe(u8, ""),
        .path = try allocator.dupe(u8, worktree_path),
    };
}

fn emptyRegistered(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
) !PathState.RegisteredWorktree {
    return .{
        .branch_ref = try allocator.dupe(u8, ""),
        .branch = try allocator.dupe(u8, ""),
        .commit = try allocator.dupe(u8, ""),
        .path = try allocator.dupe(u8, worktree_path),
    };
}

/// Scan a `git worktree list --porcelain` body for the block whose `worktree`
/// path denotes `target`. Pure — the caller owns the result.
pub fn parseWorktreeList(
    allocator: std.mem.Allocator,
    list_output: []const u8,
    target: []const u8,
) !?PathState.RegisteredWorktree {
    var line_it = std.mem.splitScalar(u8, list_output, '\n');
    var current_block: std.ArrayList(u8) = .empty;
    defer current_block.deinit(allocator);

    while (line_it.next()) |line| {
        if (line.len == 0) {
            // Blank line separates blocks. Check this block.
            if (current_block.items.len > 0) {
                if (try parseAndMatchBlock(allocator, current_block.items, target)) |rwt| {
                    return rwt;
                }
                current_block.clearRetainingCapacity();
            }
        } else {
            current_block.appendSlice(allocator, line) catch continue;
            current_block.append(allocator, '\n') catch continue;
        }
    }
    // Trailing block without final blank line (rare but possible).
    if (current_block.items.len > 0) {
        return try parseAndMatchBlock(allocator, current_block.items, target);
    }
    return null;
}

/// Parse one block of `git worktree list --porcelain` output and return the
/// registered worktree if its `path` matches `target`. Returns `null` if the
/// block is for a different worktree.
pub fn pathsDenoteSameDir(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        // Skip trailing/duplicate separators on both sides.
        while (i < a.len and isPathSep(a[i])) : (i += 1) {}
        while (j < b.len and isPathSep(b[j])) : (j += 1) {}

        const a_end = i >= a.len;
        const b_end = j >= b.len;
        if (a_end or b_end) return a_end and b_end;

        if (!eqlPathChar(a[i], b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn eqlPathChar(a: u8, b: u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return a == b;
}

pub fn parseAndMatchBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    target: []const u8,
) !?PathState.RegisteredWorktree {
    var worktree_path: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var branch_ref_raw: ?[]const u8 = null;

    var line_it = std.mem.splitScalar(u8, block, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            worktree_path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            commit = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            branch_ref_raw = line["branch ".len..];
        }
        // "detached" line is present for detached HEAD; we just ignore it.
    }

    const wt_path = worktree_path orelse return null;
    // Not `std.mem.eql`: git's separator choice differs from the model's on
    // Windows, and a false negative here means advising `rm -rf` on a live
    // worktree.
    if (!pathsDenoteSameDir(wt_path, target)) return null;

    const commit_owned = try allocator.dupe(u8, commit orelse "");
    errdefer allocator.free(commit_owned);

    const branch_ref_owned = if (branch_ref_raw) |br|
        try allocator.dupe(u8, br)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(branch_ref_owned);

    // Derive short branch name from refs/heads/X.
    const short_branch: []u8 = if (branch_ref_raw) |br| brblk: {
        if (std.mem.startsWith(u8, br, "refs/heads/")) {
            break :brblk try allocator.dupe(u8, br["refs/heads/".len..]);
        }
        break :brblk try allocator.dupe(u8, br);
    } else blk: {
        break :blk try allocator.dupe(u8, "");
    };
    errdefer allocator.free(short_branch);

    return .{
        .branch_ref = branch_ref_owned,
        .branch = short_branch,
        .commit = commit_owned,
        .path = try allocator.dupe(u8, wt_path),
    };
}

/// How much of `git worktree list --porcelain` we actually obtained. This
/// type exists because "the target was not in the listing" only means "git
/// does not know about it" when the listing was COMPLETE.
pub const ListHealth = enum {
    /// The whole listing was read: absence proves non-registration.
    complete,
    /// The read cap cut the listing short: absence proves nothing.
    truncated,
    /// git could not be consulted at all: absence proves nothing.
    unavailable,
};

/// The outcome of one `git worktree list --porcelain` attempt.
pub const WorktreeList = struct {
    health: ListHealth,
    /// Owned. Raw stdout, possibly short. Empty when `.unavailable`.
    stdout: []u8,
    /// Owned. Why the listing is short or missing. Empty when `.complete`.
    reason: []u8,

    pub fn deinit(self: *WorktreeList, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

/// Read cap for `git worktree list --porcelain`. The developer's own
/// repository listed 272 worktrees / 59,257 bytes when the 2026-09-29 bug was
/// reported — 90% of the old 64 KiB cap.
pub const max_worktree_list_bytes = 4 * 1024 * 1024;

/// Run `git worktree list --porcelain` in `repo_root` and report how much of
/// the answer we actually got.
fn runGitWorktreeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !WorktreeList {
    if (repo_root.len == 0) {
        // `sessions.cwd` is legitimately "" for a kanban task that never
        // resolved a working directory. Spawning git with an empty cwd
        // fails with a bare `FileNotFound` that says nothing about why.
        return unavailable(
            allocator,
            "the session has no working directory, so `git worktree list` could not be run",
        );
    }

    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "list", "--porcelain",
        },
        .cwd = .{ .path = repo_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("git worktree list spawn failed: {s}\n", .{@errorName(err)});
        return unavailable(
            allocator,
            try std.fmt.allocPrint(
                allocator,
                "`git worktree list` could not be run from '{s}': {s}",
                .{ repo_root, @errorName(err) },
            ),
        );
    };

    const stdout_pipe = child.stdout orelse {
        const term = child.wait(io) catch {
            return unavailable(allocator, "git worktree list: wait failed (no stdout pipe)");
        };
        return switch (term) {
            .exited => |code| if (code == 0)
                .{ .health = .complete, .stdout = try allocator.dupe(u8, ""), .reason = try allocator.dupe(u8, "") }
            else
                try failed(allocator, "git worktree list exited with code {d} (no stdout captured)", .{code}),
            .signal => try failed(allocator, "git worktree list killed by signal (no stdout)", .{}),
            else => try failed(allocator, "git worktree list terminated abnormally (no stdout)", .{}),
        };
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);
    var truncated = false;

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stdout_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stdout_buf.items.len < max_worktree_list_bytes) {
            const take = @min(n, max_worktree_list_bytes - stdout_buf.items.len);
            stdout_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            if (take < n) truncated = true;
        } else {
            // Keep draining so git never blocks on a full pipe, but stop
            // accumulating — and remember that we did.
            truncated = true;
        }
    }

    const term = child.wait(io) catch {
        return try failed(allocator, "git worktree list: failed to wait for child process", .{});
    };
    const stdout = try allocator.dupe(u8, stdout_buf.items);
    errdefer allocator.free(stdout);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("git worktree list failed (exit={d})\n", .{code});
                return try failed(allocator, "git worktree list exited with code {d}", .{code});
            }
        },
        .signal => {
            return try failed(allocator, "git worktree list was killed by a signal", .{});
        },
        else => {
            return try failed(allocator, "git worktree list terminated abnormally", .{});
        },
    }

    const health: ListHealth = if (truncated) .truncated else .complete;
    const reason = if (truncated)
        try std.fmt.allocPrint(
            allocator,
            "the worktree listing exceeded the {d} byte read cap, so it is incomplete",
            .{max_worktree_list_bytes},
        )
    else
        try allocator.dupe(u8, "");
    return .{ .health = health, .stdout = stdout, .reason = reason };
}

/// A `.unavailable` result. Takes a `[]const u8` and owns a copy, so
/// call sites can pass a literal.
fn unavailable(allocator: std.mem.Allocator, reason: []const u8) !WorktreeList {
    return .{
        .health = .unavailable,
        .stdout = try allocator.dupe(u8, ""),
        .reason = try allocator.dupe(u8, reason),
    };
}

/// A `.unavailable` result whose reason is formatted. Kept separate from
/// `unavailable` so the caller owns `reason` in both paths.
fn failed(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !WorktreeList {
    const reason = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(reason);
    return .{
        .health = .unavailable,
        .stdout = try allocator.dupe(u8, ""),
        .reason = reason,
    };
}

/// "Are these two branches the same logical work?" Returns true if both
/// branches share a known project-prefix family (`refactor/`, `feature/`,
/// `fix/`, `feat/`).
pub fn isCompatibleBranchFamily(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const families = [_][]const u8{ "refactor/", "feature/", "fix/", "feat/" };
    for (families) |prefix| {
        if (std.mem.startsWith(u8, a, prefix) and
            std.mem.startsWith(u8, b, prefix)) return true;
    }
    return false;
}

/// Rewrite a raw git stderr string into a tool-friendly error message that
/// points the LLM at a recovery path.
pub fn rewriteGitStderr(
    allocator: std.mem.Allocator,
    raw_stderr: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
    base: []const u8,
) ![]u8 {
    if (raw_stderr.len == 0) return try allocator.dupe(u8, "");

    // 1. "fatal: 'X' already exists" — precheck should have caught this,
    //    but if a race or precheck failure let it through, give actionable
    //    advice here.
    if (std.mem.indexOf(u8, raw_stderr, "already exists") != null) {
        return try std.fmt.allocPrint(allocator, "the directory '{s}' already exists on disk and could not be auto-bound. " ++
            "Either pick a different path, or run `git -C <repo> worktree list --porcelain` " ++
            "to see which branch currently occupies it, then re-call set_git_worktree with " ++
            "`branch=<existing-branch>` to bind to it.", .{worktree_path});
    }
    // 2. "fatal: 'X' is already checked out at 'Y'" — branch conflict,
    //    not a path conflict. The fix is to pick a different branch
    //    name (or let it default to worktree/<basename>).
    if (std.mem.indexOf(u8, raw_stderr, "is already checked out") != null) {
        return try std.fmt.allocPrint(allocator, "branch '{s}' is already checked out by another worktree. " ++
            "Pass `branch=''` (empty) to use the auto-derived branch name " ++
            "`worktree/<basename(path)>`, or pick a different branch name.", .{branch});
    }
    // 3. "fatal: not a git repository" — the session's cwd isn't in a
    //    git repo. This usually means the session was started outside
    //    of one, or a parent process chdir'd away.
    if (std.mem.indexOf(u8, raw_stderr, "not a git repository") != null) {
        return try allocator.dupe(
            u8,
            "the current working directory is not inside a git repository. " ++
                "set_git_worktree requires being called from within a git repo " ++
                "(or a worktree of one).",
        );
    }
    // 4. "fatal: invalid reference: X" — the branch name has bad characters,
    // or the start-point (`base`) does not resolve.
    if (std.mem.indexOf(u8, raw_stderr, "invalid reference") != null) {
        if (base.len > 0) {
            return try std.fmt.allocPrint(allocator, "the base ref '{s}' could not be resolved by git. " ++
                "Run `git fetch origin` (the ref may not be fetched yet) or pick " ++
                "a different base branch, then retry. git said: {s}", .{ base, raw_stderr });
        }
        return try std.fmt.allocPrint(allocator, "the branch name '{s}' is invalid (git refused it). " ++
            "Valid branch names must not contain spaces, '..', '~', '^', ':', " ++
            "'?', '*', '[', '\\', and may not end with '.lock' or '/'.", .{branch});
    }
    // 5. Default: return the raw stderr verbatim. The user (LLM) gets
    //    exactly what git said, no more, no less.
    return try allocator.dupe(u8, raw_stderr);
}

/// Read the session's current `git_worktree_cwd` from the DB.
/// Returns empty string when not set. Used by `clear` to know which
/// directory to remove.
fn readExistingWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    const sql = "SELECT COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = ?";
    var q = try db.query(allocator, sql, &.{session_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Which repository should `git worktree add` run in?
pub fn resolveRepoRoot(
    allocator: std.mem.Allocator,
    session_cwd: []const u8,
) !?[]u8 {
    if (session_cwd.len == 0) {
        pabrik.loggermod.debugPrint("set_git_worktree: session has no cwd, using the process cwd\n", .{});
        return null;
    }
    if (!std.fs.path.isAbsolute(session_cwd)) {
        pabrik.loggermod.debugPrint("set_git_worktree: ignoring relative session cwd '{s}'\n", .{session_cwd});
        return null;
    }
    return try allocator.dupe(u8, session_cwd);
}

/// Run `git worktree add -b <branch> <worktree_path> [<base>]` in the given
/// repository root. On success, returns an empty string.
fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: ?[]const u8,
    worktree_path: []const u8,
    branch: []const u8,
    base: []const u8,
) ![]u8 {
    const argv = try buildWorktreeAddArgv(allocator, branch, worktree_path, base);
    defer allocator.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (repo_root) |r| .{ .path = r } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("git worktree add spawn failed: {s}\n", .{@errorName(err)});
        return try std.fmt.allocPrint(
            allocator,
            "failed to spawn git worktree add: {s}",
            .{@errorName(err)},
        );
    };

    // Short-lived command (worktree add is sub-second); use a bounded
    // blocking read rather than the threaded + timeout pattern that bash.zig
    // uses for arbitrary user commands.
    const stderr_pipe = child.stderr orelse {
        // No stderr pipe (shouldn't happen with .pipe above); just wait
        // and return based on exit code.
        const term = child.wait(io) catch {
            return try allocator.dupe(
                u8,
                "git worktree add: child process wait failed (no stderr pipe)",
            );
        };
        return switch (term) {
            .exited => |code| if (code == 0)
                try allocator.dupe(u8, "")
            else
                try std.fmt.allocPrint(
                    allocator,
                    "git worktree add exited with code {d} (no stderr captured)",
                    .{code},
                ),
            .signal => try allocator.dupe(u8, "git worktree add was killed by a signal (no stderr captured)"),
            else => try allocator.dupe(u8, "git worktree add terminated abnormally (no stderr captured)"),
        };
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stderr_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stderr_buf.items.len < 64 * 1024) {
            const take = @min(n, 64 * 1024 - stderr_buf.items.len);
            stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
        }
    }

    const term = child.wait(io) catch {
        return try allocator.dupe(u8, "git worktree add: failed to wait for child process");
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return try allocator.dupe(u8, "");
            const stderr_text = stderr_buf.items;
            std.debug.print("git worktree add failed (exit={d}): {s}\n", .{ code, stderr_text });
            // Surface git's own stderr to the user.
            return if (stderr_text.len == 0)
                try std.fmt.allocPrint(
                    allocator,
                    "git worktree add exited with code {d} (no stderr output)",
                    .{code},
                )
            else
                try allocator.dupe(u8, stderr_text);
        },
        .signal => {
            std.debug.print("git worktree add killed by signal\n", .{});
            return try allocator.dupe(u8, "git worktree add was killed by a signal");
        },
        else => return try allocator.dupe(u8, "git worktree add terminated abnormally"),
    }
}

/// Run `git worktree remove --force <worktree_path>`. The `--force`
/// flag is required because the worktree may have uncommitted changes
/// (the LLM is actively editing inside it).
fn runGitWorktreeRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    worktree_path: []const u8,
) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "remove", "--force", worktree_path,
        },
        .cwd = .inherit, // use the pabrik process's cwd (the session cwd is inside the original repo)
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;

    const stderr_pipe = child.stderr orelse {
        const term = child.wait(io) catch return error.GitWaitFailed;
        return switch (term) {
            .exited => |code| if (code == 0) return else return error.GitRemoveFailed,
            else => error.GitRemoveFailed,
        };
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stderr_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stderr_buf.items.len < 64 * 1024) {
            const take = @min(n, 64 * 1024 - stderr_buf.items.len);
            stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
        }
    }

    const term = child.wait(io) catch return error.GitWaitFailed;
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            // It's not an error if the directory was already gone (the user
            // may have `rm -rf`d it manually between sessions). git returns
            // 128 with "fatal: not a working tree" in that case — treat that
            const stderr_text = stderr_buf.items;
            if (std.mem.indexOf(u8, stderr_text, "not a working tree") != null) return;
            if (std.mem.indexOf(u8, stderr_text, "No such file or directory") != null) return;
            std.debug.print("git worktree remove failed (exit={d}): {s}\n", .{ code, stderr_text });
            return error.GitRemoveFailed;
        },
        .signal => {
            std.debug.print("git worktree remove killed by signal\n", .{});
            return error.GitRemoveFailed;
        },
        else => return error.GitRemoveFailed,
    }
}

/// Execute the set_git_worktree tool.
pub fn executeSetGitWorktreeToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    input: SetGitWorktreeInput,
) ![]const u8 {
    if (session_id.len == 0) return xmlErrorEmpty(allocator, "session_id is required");

    // CLEAR PATH — remove the currently-bound worktree, if any.
    if (input.clear) {
        const existing = try readExistingWorktreeCwd(allocator, db, session_id);
        defer allocator.free(existing);
        if (existing.len > 0) {
            runGitWorktreeRemove(allocator, io, existing) catch |err| {
                const msg = @errorName(err);
                std.debug.print("set_git_worktree clear: remove failed: {s}\n", .{msg});
                return xmlError(allocator, session_id, "failed to remove existing worktree");
            };
        }
        return successClearToXml(allocator, session_id);
    }

    // SET PATH — validate the absolute path, check parent exists, create.
    if (input.path.len == 0) {
        return xmlError(allocator, session_id, "path is required (or pass clear=true)");
    }
    if (validatePath(input.path)) |err_msg| {
        return xmlError(allocator, session_id, err_msg);
    }
    // Parent directory must exist (git won't auto-create it).
    const parent_path = std.fs.path.dirname(input.path) orelse "/";
    std.Io.Dir.cwd().access(io, parent_path, .{}) catch {
        return xmlError(allocator, session_id, "parent directory does not exist");
    };
    const worktree_path = try allocator.dupe(u8, input.path);
    defer allocator.free(worktree_path);
    const branch_owned: ?[]u8 = if (input.branch.len > 0) null else blk: {
        const default = try deriveBranchFromPath(allocator, worktree_path);
        break :blk default;
    };
    defer if (branch_owned) |b| allocator.free(b);
    const branch: []const u8 = if (input.branch.len > 0) input.branch else branch_owned.?;

    // Optional base ref the new branch is created FROM (`origin/main`,
    // …). Trim first so a padded LLM argument does not trip the
    // character check, then validate before it reaches git's argv.
    const base = std.mem.trim(u8, input.base, " \t\r\n");
    if (validateBaseRef(base)) |err_msg| {
        return xmlError(allocator, session_id, err_msg);
    }

    // ── Precheck: classify the path before invoking git ──────────────────
    // Avoids the "fatal: '...' already exists" raw stderr the LLM has to
    // guess about.
    {
        const state = classifyPath(allocator, io, cwd, worktree_path) catch |err| blk: {
            // classifyPath only fails on alloc; fall through to git and
            // let it produce a normal error.
            std.debug.print("set_git_worktree: classifyPath failed: {s}\n", .{@errorName(err)});
            break :blk PathState{ .not_found = {} };
        };
        // Free the state when we leave this scope (any variant with owned slices).
        defer freePathState(allocator, state);
        switch (state) {
            .not_found => {
                // Normal path: fall through to git worktree add.
            },
            .registered_worktree => |rwt| {
                // Path is already a worktree. Is the requested branch the same
                // (or a compatible family member)? If so, auto-bind; if not,
                // surface a structured error so the LLM can decide.
                const branch_matches = std.mem.eql(u8, rwt.branch, branch) or
                    std.mem.eql(u8, rwt.branch_ref, branch);
                const branch_compatible = isCompatibleBranchFamily(rwt.branch, branch);
                if (branch_matches or branch_compatible) {
                    std.debug.print(
                        "set_git_worktree: auto-bound session {s} to existing worktree on branch {s}\n",
                        .{ session_id, rwt.branch },
                    );
                    return successSetToXml(allocator, session_id, worktree_path, rwt.branch, "");
                }
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator, "path '{s}' is already a worktree on branch '{s}' (you requested '{s}'). " ++
                    "Either pick a different path, or pass branch='{s}' to bind to the existing worktree, " ++
                    "or ask the user how to resolve the conflict (merge, rename, or remove the existing branch).", .{ worktree_path, rwt.branch, branch, rwt.branch }));
            },
            .orphaned_worktree => |gitdir| {
                return xmlError(allocator, session_id, try orphanedWorktreeMessage(
                    allocator,
                    worktree_path,
                    gitdir,
                ));
            },
            .unverified_worktree => |uv| {
                return xmlError(allocator, session_id, try unverifiedWorktreeMessage(
                    allocator,
                    worktree_path,
                    uv.gitdir,
                    uv.reason,
                ));
            },
            .plain_directory => |desc| {
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator, "path '{s}' already exists but is not a worktree directory ({s}). " ++
                    "Remove it manually (after backing up any important content) or pick a different path.", .{ worktree_path, desc }));
            },
        }
    }

    // Which repository do we ask git to add this worktree to?
    const resolved_repo_root = try resolveRepoRoot(allocator, cwd);
    defer if (resolved_repo_root) |r| allocator.free(r);

    // runGitWorktreeAdd returns the captured git stderr on failure (or a
    // descriptive fallback including the exit code). Empty string = success.
    const git_detail = runGitWorktreeAdd(allocator, io, resolved_repo_root, worktree_path, branch, base) catch |err| {
        // Alloc failure inside runGitWorktreeAdd — extremely rare.
        std.debug.print("set_git_worktree add dispatch failed: {s}\n", .{@errorName(err)});
        return xmlError(allocator, session_id, @errorName(err));
    };
    defer allocator.free(git_detail);
    if (git_detail.len > 0) {
        // Precheck may have let git run (race or precheck failure); rewrite
        // the raw stderr to add recovery guidance for the common cases (path
        // collision, branch conflict, non-repo cwd, invalid branch name,
        const rewritten = rewriteGitStderr(allocator, git_detail, worktree_path, branch, base) catch |err| blk: {
            std.debug.print("set_git_worktree: rewriteGitStderr failed: {s}\n", .{@errorName(err)});
            break :blk git_detail;
        };
        defer if (rewritten.ptr != git_detail.ptr) allocator.free(rewritten);
        return xmlError(allocator, session_id, rewritten);
    }
    return successSetToXml(allocator, session_id, worktree_path, branch, base);
}

/// Free the owned slices inside a `PathState`. Safe to call on any
/// variant (no-op for `not_found`, frees the strings for the others).
pub fn freePathState(allocator: std.mem.Allocator, state: PathState) void {
    switch (state) {
        .not_found => {},
        .plain_directory => |s| allocator.free(s),
        .orphaned_worktree => |s| allocator.free(s),
        .registered_worktree => |rwt| {
            allocator.free(rwt.branch_ref);
            allocator.free(rwt.branch);
            allocator.free(rwt.commit);
            allocator.free(rwt.path);
        },
        .unverified_worktree => |uv| {
            allocator.free(uv.gitdir);
            allocator.free(uv.reason);
        },
    }
}

/// The advice for a directory git no longer tracks.
pub fn orphanedWorktreeMessage(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    gitdir: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "path '{s}' was an orphaned worktree directory: its .git file points at {s}, " ++
            "and that directory no longer exists, so git has no record of it. " ++
            "The directory itself still holds whatever was written into it. " ++
            "Do NOT delete it — move it aside (for example `mv {s} {s}.orphaned`) " ++
            "so the files survive, then retry set_git_worktree with that new path, " ++
            "or pick a different path.",
        .{ worktree_path, gitdir, worktree_path, worktree_path },
    );
}

/// The advice when we could not prove either way. This must never
/// suggest deleting anything: the directory is exactly as likely to be
/// a healthy worktree whose listing we failed to read.
pub fn unverifiedWorktreeMessage(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    gitdir: []const u8,
    reason: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "path '{s}' has a .git file pointing at {s}, but pabrik could not determine whether git " ++
            "still tracks it: {s}. Treat it as a LIVE worktree — it may be holding another " ++
            "session's uncommitted work, so do not delete or move it. Verify with " ++
            "`git -C <repo> worktree list --porcelain`; if the path is listed, re-call " ++
            "set_git_worktree with the same path, otherwise pick a different path.",
        .{ worktree_path, gitdir, reason },
    );
}

/// JSON payload for set_git_worktree results.
pub const SetGitWorktreeJSON = struct {
    session_id: []const u8,
    created: bool = false,
    cleared: bool = false,
    path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    base: ?[]const u8 = null,
    note: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Guidance handed back after a successful worktree create.
pub const worktree_pr_note =
    "If the user asks to open a pull request or a merge request, or you want to initialize one for this branch, create it with the forge CLI for this repo — `gh pr create` on GitHub, `glab mr create` on GitLab — or use the Create-PR dialog, then call the agent tool `set_pull_request` with the PR/MR URL to bind it to this session.";

pub fn jsonSet(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8, base: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .created = true,
        .path = path,
        .branch = branch,
        .base = if (base.len > 0) base else null,
        .note = worktree_pr_note,
    }, .{}) catch "";
}

pub fn jsonClear(allocator: std.mem.Allocator, session_id: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .cleared = true,
    }, .{}) catch "";
}

/// Generate error JSON response (session_id is present).
pub fn jsonError(allocator: std.mem.Allocator, session_id: []const u8, error_msg: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .created = false,
        .@"error" = error_msg,
    }, .{}) catch "";
}

/// Generate error JSON response when session_id is unavailable.
pub fn jsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = "",
        .created = false,
        .@"error" = error_msg,
    }, .{}) catch "{\"created\":false,\"error\":\"UnknownError\"}";
}

// Legacy aliases kept so old grep-based tests and any external callers
// keep resolving; all emit JSON now.
pub const xmlError = jsonError;
pub const xmlErrorEmpty = jsonErrorEmpty;
fn successSetToXml(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8, base: []const u8) []const u8 {
    return jsonSet(allocator, session_id, path, branch, base);
}
fn successClearToXml(allocator: std.mem.Allocator, session_id: []const u8) []const u8 {
    return jsonClear(allocator, session_id);
}

// ===== Tests merged from set_git_worktree_test.zig (2026-09-29 flatten) =====
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
// ─── Behavioral tests for validatePath ────────────────────────────────────

test "validatePath accepts valid absolute paths" {
    const valid_paths = [_][]const u8{
        "/home/me/proj/.worktrees/auth-fix",
        "/tmp/experiments/rpc-rewrite",
        "/a/b/c",
        "/x",
    };
    for (valid_paths) |p| {
        try testing.expect(validatePath(p) == null);
    }
}

test "validatePath rejects empty path" {
    try testing.expect(validatePath("") != null);
}

test "validatePath rejects relative path" {
    try testing.expect(validatePath("foo/bar") != null);
}

test "validatePath rejects path with .." {
    try testing.expect(validatePath("/home/me/../etc/passwd") != null);
}

test "validatePath rejects null byte" {
    try testing.expect(validatePath("/foo\x00bar") != null);
}

test "validatePath rejects too-long path" {
    var long_path: [5000]u8 = undefined;
    @memset(long_path[0..], '/');
    long_path[0] = '/';
    for (1..5000) |i| long_path[i] = 'a';
    try testing.expect(validatePath(long_path[0..]) != null);
}

test "validatePath rejects illegal basename" {
    const bad_paths = [_][]const u8{
        "/foo/hello world",
        "/foo/bad!char",
        "/foo/.",
        "/foo/..",
    };
    for (bad_paths) |p| {
        try testing.expect(validatePath(p) != null);
    }
}

// ─── Behavioral tests for validateBasename ────────────────────────────────

test "validateBasename accepts legal names" {
    const ok = [_][]const u8{ "auth-fix", "v2", "x", "a..b" };
    for (ok) |n| {
        try testing.expect(validateBasename(n) == null);
    }
}

test "validateBasename rejects illegal names" {
    const bad = [_][]const u8{ "hello world", "a/b", ".", ".." };
    for (bad) |n| {
        try testing.expect(validateBasename(n) != null);
    }
}

// ─── Behavioral tests for deriveBranchFromPath ────────────────────────────

test "deriveBranchFromPath returns worktree/<basename>" {
    const allocator = testing.allocator;

    const b1 = try deriveBranchFromPath(allocator, "/abs/.worktrees/auth-fix");
    defer allocator.free(b1);
    try testing.expectEqualStrings("worktree/auth-fix", b1);

    const b2 = try deriveBranchFromPath(allocator, "/tmp/foo");
    defer allocator.free(b2);
    try testing.expectEqualStrings("worktree/foo", b2);

    const b3 = try deriveBranchFromPath(allocator, "/Users/me/proj/.worktrees/fix-bug-123");
    defer allocator.free(b3);
    try testing.expectEqualStrings("worktree/fix-bug-123", b3);
}

// ─── Behavioral tests for isCompatibleBranchFamily (pure) ──────────────

test "isCompatibleBranchFamily matches same-family branches" {
    // refactor/x ↔ refactor/y  →  same family
    try testing.expect(isCompatibleBranchFamily("refactor/x", "refactor/y"));
    // feature/x ↔ feature/y  →  same family
    try testing.expect(isCompatibleBranchFamily("feature/auth", "feature/routines"));
    // fix/x ↔ fix/y  →  same family
    try testing.expect(isCompatibleBranchFamily("fix/typo", "fix/bug-42"));
    // feat/x ↔ feat/y  →  same family
    try testing.expect(isCompatibleBranchFamily("feat/ui-redesign", "feat/api-rename"));
    // main ↔ main  →  no family, but the question is "compatible?" — same
    //   exact branch name is the strongest compatibility, but this helper
    //   only tests family prefixes (used as a tie-breaker, not a final answer).
    try testing.expect(!isCompatibleBranchFamily("main", "main"));
    // worktree/x ↔ refactor/x  →  different family
    try testing.expect(!isCompatibleBranchFamily("worktree/x", "refactor/x"));
    // Empty strings are never compatible.
    try testing.expect(!isCompatibleBranchFamily("", "refactor/x"));
    try testing.expect(!isCompatibleBranchFamily("refactor/x", ""));
    try testing.expect(!isCompatibleBranchFamily("", ""));
    // One branch in a known family, the other in a non-family prefix.
    try testing.expect(!isCompatibleBranchFamily("refactor/x", "main"));
    try testing.expect(!isCompatibleBranchFamily("main", "refactor/x"));
}

test "isCompatibleBranchFamily rejects cross-family combinations" {
    const cases = [_][2][]const u8{
        .{ "refactor/x", "feature/y" },
        .{ "feature/x", "fix/y" },
        .{ "fix/x", "feat/y" },
        .{ "feat/x", "refactor/y" },
    };
    for (cases) |pair| {
        try testing.expect(!isCompatibleBranchFamily(pair[0], pair[1]));
    }
}

// ─── Chunk 3: rewriteGitStderr ─────────────────────────────────────────

test "rewriteGitStderr rewrites 'already exists' to recovery advice" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: '/abs/.worktrees/foo' already exists",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    // The original "fatal: ... already exists" must be GONE (replaced),
    // and the new message must mention recovery.
    if (std.mem.indexOf(u8, out, "fatal:") != null) {
        std.debug.print("!! rewriteGitStderr left the 'fatal:' prefix in the output !!\n", .{});
        return error.RewriteKeptFatalPrefix;
    }
    if (std.mem.indexOf(u8, out, "git -C <repo> worktree list --porcelain") == null) {
        std.debug.print("!! rewriteGitStderr's 'already exists' branch does not suggest worktree list !!\n", .{});
        return error.RewriteMissingWorktreeListSuggestion;
    }
}

test "rewriteGitStderr rewrites 'is already checked out' to branch advice" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: 'worktree/foo' is already checked out at '/abs/.worktrees/foo'",
        "/abs/.worktrees/new",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "auto-derived branch name") == null) {
        std.debug.print("!! rewriteGitStderr's branch-conflict branch does not mention auto-derived branch name !!\n", .{});
        return error.RewriteMissingAutoDerivedSuggestion;
    }
}

test "rewriteGitStderr rewrites 'not a git repository'" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: not a git repository (or any parent up to mount point /)",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "set_git_worktree requires being called from within a git repo") == null) {
        std.debug.print("!! rewriteGitStderr's not-a-repo branch does not mention the git-repo requirement !!\n", .{});
        return error.RewriteMissingNotARepoExplanation;
    }
}

test "rewriteGitStderr rewrites 'invalid reference' to branch-name rules" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: invalid reference: bad..name",
        "/abs/.worktrees/foo",
        "bad..name",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "Valid branch names must not contain") == null) {
        std.debug.print("!! rewriteGitStderr's invalid-reference branch does not explain branch-name rules !!\n", .{});
        return error.RewriteMissingBranchRules;
    }
}

test "rewriteGitStderr blames the base ref when one was requested" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: invalid reference: origin/nope",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "origin/nope",
    );
    defer allocator.free(out);
    // The base ref is the likely culprit, so the message must name it and
    // point at `git fetch` rather than at the new branch name.
    if (std.mem.indexOf(u8, out, "origin/nope") == null) {
        std.debug.print("!! rewriteGitStderr does not name the unresolvable base ref !!\n", .{});
        return error.RewriteMissingBaseRefName;
    }
    if (std.mem.indexOf(u8, out, "git fetch origin") == null) {
        std.debug.print("!! rewriteGitStderr does not suggest `git fetch origin` for an unresolved base !!\n", .{});
        return error.RewriteMissingFetchSuggestion;
    }
}

test "rewriteGitStderr passes through unknown stderr verbatim" {
    const allocator = testing.allocator;
    const unknown = "fatal: some weird edge-case error we did not anticipate\n";
    const out = try rewriteGitStderr(allocator, unknown, "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings(unknown, out);
}

test "rewriteGitStderr returns empty for empty input" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(allocator, "", "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("", out);
}

// ─── Base ref (kanban `Base:` line) ────────────────────────────────────

test "validateBaseRef accepts refs the kanban dialog emits" {
    const ok = [_][]const u8{
        "",
        "origin/main",
        "origin/feat/some-branch",
        "main",
        "worktree/foo-1757792000000",
        "v1.2.3",
    };
    for (ok) |ref| {
        if (validateBaseRef(ref)) |msg| {
            std.debug.print("!! validateBaseRef rejected '{s}': {s} !!\n", .{ ref, msg });
            return error.ValidBaseRefRejected;
        }
    }
}

test "validateBaseRef rejects flag-shaped and malformed refs" {
    const bad = [_][]const u8{
        "-b",
        "--hard",
        "origin/ main",
        "origin/..main",
        "origin//main",
        "origin/main.lock",
        "origin/main@{1}",
        "origin/ma~in",
        "origin/ma^in",
        "origin/ma:in",
        "origin/ma?in",
        "origin/ma*in",
        "origin/ma[in",
        "origin/ma\\in",
        "/origin/main",
        "origin/main/",
    };
    for (bad) |ref| {
        if (validateBaseRef(ref) == null) {
            std.debug.print("!! validateBaseRef accepted invalid ref '{s}' !!\n", .{ref});
            return error.InvalidBaseRefAccepted;
        }
    }
}

test "buildWorktreeAddArgv omits the start-point when base is empty" {
    const argv = try buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "");
    defer testing.allocator.free(argv);

    const tail = [_][]const u8{ "worktree", "add", "-b", "worktree/x", "/tmp/wt/x" };
    try testing.expectEqual(git_hardening.git_prefix.len + tail.len, argv.len);
    for (tail, argv[argv.len - tail.len ..]) |want, got| try testing.expectEqualStrings(want, got);
}

test "buildWorktreeAddArgv appends the base as the start-point" {
    const argv = try buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "origin/main");
    defer testing.allocator.free(argv);

    const tail = [_][]const u8{ "worktree", "add", "-b", "worktree/x", "/tmp/wt/x", "origin/main" };
    try testing.expectEqual(git_hardening.git_prefix.len + tail.len, argv.len);
    for (tail, argv[argv.len - tail.len ..]) |want, got| try testing.expectEqualStrings(want, got);
}

test "buildWorktreeAddArgv disables repo hooks before the subcommand" {
    const argv = try buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "");
    defer testing.allocator.free(argv);

    try testing.expectEqualStrings("/dev/null", git_hardening.configValue("core.hooksPath").?);
    for (argv[git_hardening.git_prefix.len..]) |arg| try testing.expect(!std.mem.eql(u8, arg, "-c"));
}

test "jsonError carries message with special chars raw" {
    const payload = jsonError(testing.allocator, "s1", "bad <tag> & \"quote\"");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("s1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("bad <tag> & \"quote\"", obj.get("error").?.string);
    try testing.expect(!obj.get("created").?.bool);
}

test "jsonSet carries path/branch/note" {
    const payload = jsonSet(testing.allocator, "s1", "/tmp/wt", "worktree/wt", "");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("created").?.bool);
    try testing.expectEqualStrings("/tmp/wt", obj.get("path").?.string);
    try testing.expectEqualStrings("worktree/wt", obj.get("branch").?.string);
    try testing.expect(obj.get("note").?.string.len > 0);
}

test "jsonClear sets cleared flag" {
    const payload = jsonClear(testing.allocator, "s1");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("cleared").?.bool);
}

// ─── Cross-separator worktree matching (Windows) ──────────────────────────
// The bug: `parseAndMatchBlock` compared git's worktree path against the
// model's with `std.mem.eql`. git for Windows prints FORWARD slashes
test "pathsDenoteSameDir: git forward slashes match the model's backslashes" {
    try testing.expect(pathsDenoteSameDir(
        "C:/Users/ginwa/.config/pabrik/.worktrees/fix-login",
        "C:\\Users\\ginwa\\.config\\pabrik\\.worktrees\\fix-login",
    ));
}

test "pathsDenoteSameDir: trailing and duplicate separators are ignored" {
    try testing.expect(pathsDenoteSameDir("C:/a/b/", "C:\\a\\b"));
    try testing.expect(pathsDenoteSameDir("C:/a//b", "C:\\a\\b"));
    try testing.expect(pathsDenoteSameDir("/home/ginwa/wt/", "/home/ginwa/wt"));
    try testing.expect(pathsDenoteSameDir("", ""));
}

test "pathsDenoteSameDir: different directories still do not match" {
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt2"));
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\b\\wt"));
    // A prefix must not match a longer path.
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt\\sub"));
    try testing.expect(!pathsDenoteSameDir("/home/ginwa/wt", "/home/other/wt"));
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", ""));
}

// Case sensitivity is host-dependent on purpose: Windows filesystems ignore
// case, Linux ones do not. Asserting the POSIX behaviour everywhere and the
// Windows behaviour in a gated leg keeps the function honest on both.
test "pathsDenoteSameDir: case is ignored only on Windows" {
    if (@import("builtin").os.tag == .windows) {
        try testing.expect(pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    } else {
        try testing.expect(!pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    }
}

// The end-to-end leg: a real `git worktree list --porcelain` block, exactly
// as Windows git prints it, matched against the path the model would send.
test "parseAndMatchBlock: a Windows worktree listing matches the model's backslash path" {
    const block =
        \\worktree C:/Users/ginwa/.config/pabrik/.worktrees/fix-login
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/fix-login
        \\
        \\
    ;
    const matched = try parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\pabrik\\.worktrees\\fix-login",
    );
    try testing.expect(matched != null);
    defer if (matched) |m| {
        testing.allocator.free(m.branch_ref);
        testing.allocator.free(m.branch);
        testing.allocator.free(m.commit);
        testing.allocator.free(m.path);
    };
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", matched.?.commit);
    try testing.expectEqualStrings("worktree/fix-login", matched.?.branch);
}

test "parseAndMatchBlock: a genuinely different worktree is not matched" {
    const block =
        \\worktree C:/Users/ginwa/.config/pabrik/.worktrees/other
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/other
        \\
    ;
    const matched = try parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\pabrik\\.worktrees\\fix-login",
    );
    try testing.expect(matched == null);
}

// ═══════════════════════════════════════════════════════════════════════
// 2026-09-29 — the false "orphaned worktree" verdict
// ═══════════════════════════════════════════════════════════════════════

/// Spawn a git child with NO pipes and return its exit code. `null` when git
/// could not be spawned or was killed. This deliberately does not go through
/// `helpers.run_captured`.
fn spawnGit(
    io: std.Io,
    argv: []const []const u8,
    inherit_output: bool,
) !?u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = if (inherit_output) .inherit else .ignore,
        .stderr = if (inherit_output) .inherit else .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// Skip the calling test when the host has no usable `git` on PATH.
fn requireGit() !void {
    var child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    _ = child.wait(std.testing.io) catch return error.SkipZigTest;
}

/// A throwaway git repository with one commit, inside `std.testing.tmpDir`
/// (which roots under `.zig-cache/tmp/`, so it is never the developer's
/// own repository and never collides with their 272 real worktrees).
const GitFixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    repo: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !GitFixture {
        // Refuse fixture git when hook-exported GIT_DIR/GIT_WORK_TREE is set.
        try @import("helpers").git_env_guard.requireCleanGitEnv();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = try tmp.dir.realPath(std.testing.io, &buf);
        const root = try allocator.dupe(u8, buf[0..real]);
        errdefer allocator.free(root);
        const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
        errdefer allocator.free(repo);

        var fx = GitFixture{ .tmp = tmp, .root = root, .repo = repo, .allocator = allocator };
        try fx.git(&.{ "init", "-q", "--initial-branch=main", repo });
        // `git worktree add` needs a resolvable start-point, so the repo
        // needs one commit before it can hand out a branch.
        try fx.git(&.{
            "-C",     repo, "-c",            "user.email=pabrik@example.com", "-c",   "user.name=pabrik",
            "commit", "-q", "--allow-empty", "-m",                            "init",
        });
        return fx;
    }

    fn deinit(self: *GitFixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
        self.allocator.free(self.repo);
    }

    fn git(self: *GitFixture, argv: []const []const u8) !void {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(self.allocator);
        try full.append(self.allocator, "git");
        try full.appendSlice(self.allocator, argv);

        const code = try spawnGit(std.testing.io, full.items, false) orelse
            return error.SkipZigTest;
        if (code == 0) return;

        // Re-run with the child's output inherited so git's own
        // explanation reaches the CI log — the first pass discarded it
        // to stay pipe-free. Same command, so this is side-effect free.
        _ = try spawnGit(std.testing.io, full.items, true);
        std.debug.print("!! git {any} exited {d} !!\n", .{ argv, code });
        return error.GitCommandFailed;
    }

    /// Join `parts` with the platform's separator. The fixture root on
    /// Windows is a backslash path (`D:\a\...\.zig-cache\tmp\XXXX`), so
    /// hard-coding "/" would hand git a mixed-separator argument.
    fn join(self: *GitFixture, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, parts);
    }

    /// `git worktree add -b worktree/<name> <root>/<name>` — the exact
    /// shape `executeSetGitWorktreeToString` creates.
    fn addWorktree(self: *GitFixture, name: []const u8) ![]u8 {
        const path = try self.join(&.{ self.root, name });
        errdefer self.allocator.free(path);
        const branch = try std.fmt.allocPrint(self.allocator, "worktree/{s}", .{name});
        defer self.allocator.free(branch);
        try self.git(&.{ "-C", self.repo, "worktree", "add", "-b", branch, path });
        return path;
    }

    /// The admin directory git keeps for a linked worktree — the
    /// registration record. Deleting it is what makes a worktree a
    /// genuine orphan.
    fn adminDir(self: *GitFixture, name: []const u8) ![]u8 {
        return self.join(&.{ self.repo, ".git", "worktrees", name });
    }

    /// A directory that carries a worktree-shaped `.git` file pointing at an
    /// admin directory that EXISTS, with a `HEAD` inside it — the exact pair
    /// of files `git worktree add` leaves behind.
    fn makeRegisteredDirectory(self: *GitFixture, name: []const u8) ![]u8 {
        const dir = try self.join(&.{ self.root, name });
        errdefer self.allocator.free(dir);
        std.Io.Dir.cwd().createDirPath(std.testing.io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const admin = try self.join(&.{ self.repo, ".git", "worktrees", name });
        // `admin` is NOT returned — it is an intermediate — so plain
        // `defer`, not `errdefer`.
        defer self.allocator.free(admin);
        std.Io.Dir.cwd().createDirPath(std.testing.io, admin) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const head = try self.join(&.{ admin, "HEAD" });
        defer self.allocator.free(head);
        const head_contents = try std.fmt.allocPrint(
            self.allocator,
            "ref: refs/heads/worktree/{s}\n",
            .{name},
        );
        defer self.allocator.free(head_contents);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = head,
            .data = head_contents,
        });
        try self.writeGitdirPointer(dir, admin);
        return dir;
    }

    /// Write `<dir>/.git` as git does: `gitdir: <admin>\n`.
    fn writeGitdirPointer(self: *GitFixture, dir: []const u8, admin: []const u8) !void {
        const contents = try std.fmt.allocPrint(self.allocator, "gitdir: {s}\n", .{admin});
        defer self.allocator.free(contents);
        const dot_git = try self.join(&.{ dir, ".git" });
        defer self.allocator.free(dot_git);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = dot_git,
            .data = contents,
        });
    }

    /// A directory that carries a worktree-shaped `.git` file pointing at an
    /// admin directory that does not exist — the exact state `git worktree
    /// prune` leaves behind, produced without having to delete anything.
    fn makeOrphanDirectory(self: *GitFixture, name: []const u8) ![]u8 {
        // `dir` is the value handed back, so it is owned by the CALLER:
        // errdefer (not defer) frees it on the failure paths only.
        const dir = try self.join(&.{ self.root, name });
        errdefer self.allocator.free(dir);
        std.Io.Dir.cwd().createDirPath(std.testing.io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const missing_admin = try self.join(&.{ self.repo, ".git", "worktrees", "pruned-away" });
        defer self.allocator.free(missing_admin);
        try self.writeGitdirPointer(dir, missing_admin);
        return dir;
    }
};

test "classifyPath: an empty session cwd still recognises a REGISTERED worktree (2026-09-29 regression)" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();
    const wt = try fx.makeRegisteredDirectory("wt");
    defer allocator.free(wt);

    // `repo_root` is what `executeSetGitWorktreeToString` forwards as
    // `ctx.cwd`. The failing session had `sessions.cwd = ''`.
    const state = try classifyPath(allocator, std.testing.io, "", wt);
    defer freePathState(allocator, state);

    switch (state) {
        .registered_worktree => |rwt| try testing.expectEqualStrings("worktree/wt", rwt.branch),
        else => {
            std.debug.print(
                "!! an empty repo_root turned a REGISTERED worktree into '{s}' — this is the 2026-09-29 false 'orphaned' bug !!\n",
                .{@tagName(state)},
            );
            return error.RegisteredWorktreeMisclassified;
        },
    }
}

test "classifyPath: a registered worktree classifies the same with an empty repo_root as with the real one" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();
    const wt = try fx.makeRegisteredDirectory("wt");
    defer allocator.free(wt);

    const with_root = try classifyPath(allocator, std.testing.io, fx.repo, wt);
    defer freePathState(allocator, with_root);
    const without_root = try classifyPath(allocator, std.testing.io, "", wt);
    defer freePathState(allocator, without_root);

    try testing.expectEqual(@as(std.meta.Tag(PathState), .registered_worktree), @as(std.meta.Tag(PathState), std.meta.activeTag(with_root)));
    try testing.expectEqual(@as(std.meta.Tag(PathState), .registered_worktree), @as(std.meta.Tag(PathState), std.meta.activeTag(without_root)));
}

test "classifyPath: a worktree whose admin dir is gone IS an orphan (proven, not inferred)" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();

    // Stand in for `git worktree prune` (or an admin dir deleted out from
    // under a live directory): the `.git` FILE still points at an admin
    // directory that is not there.
    const wt = try fx.makeOrphanDirectory("pruned");
    defer allocator.free(wt);

    const state = try classifyPath(allocator, std.testing.io, "", wt);
    defer freePathState(allocator, state);
    switch (state) {
        .orphaned_worktree => |gitdir| {
            // Trimmed, and the admin dir named in the message is the
            // one that is missing — that is the evidence for the verdict.
            try testing.expect(std.mem.endsWith(u8, gitdir, "pruned-away"));
            try testing.expect(std.mem.indexOfScalar(u8, gitdir, '\n') == null);
        },
        else => {
            std.debug.print("!! a worktree with no admin dir classified as '{s}', expected 'orphaned_worktree' !!\n", .{@tagName(state)});
            return error.OrphanNotDetected;
        },
    }
}

test "classifyPath: a REAL git worktree registers, and deleting its admin dir orphans it" {
    // The synthetic `makeRegisteredDirectory` / `makeOrphanDirectory` cases
    // above are what the fast tests use.
    const allocator = testing.allocator;
    try requireGit();
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();
    const wt = try fx.addWorktree("wt");
    defer allocator.free(wt);

    // Freed exactly once, here. An earlier version freed inside a `defer`
    // in the switch arm AND again after the switch — a double free, which
    // segfaults (exit 139) rather than failing cleanly.
    const registered = try classifyPath(allocator, std.testing.io, "", wt);
    if (registered == .registered_worktree) {
        switch (registered) {
            .registered_worktree => |rwt| try testing.expectEqualStrings("worktree/wt", rwt.branch),
            else => unreachable,
        }
    } else {
        std.debug.print("!! a real git worktree classified as '{s}' !!\n", .{@tagName(registered)});
    }
    freePathState(allocator, registered);
    if (registered != .registered_worktree) return error.RealWorktreeNotRegistered;

    if (builtin.os.tag == .windows) return;

    const admin = try fx.adminDir("wt");
    defer allocator.free(admin);
    std.Io.Dir.cwd().deleteTree(std.testing.io, admin) catch |err| {
        std.debug.print("!! could not delete {s}: {s}\n", .{ admin, @errorName(err) });
        return error.AdminDirDeleteFailed;
    };

    const state = try classifyPath(allocator, std.testing.io, "", wt);
    defer freePathState(allocator, state);
    switch (state) {
        .orphaned_worktree => |gitdir| try testing.expectEqualStrings(admin, gitdir),
        else => {
            std.debug.print("!! deleting the admin dir did not orphan the worktree (got '{s}') !!\n", .{@tagName(state)});
            return error.OrphanNotDetected;
        },
    }
}

test "classifyPath: the orphan gitdir carries no trailing newline from the .git file" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();
    const wt = try fx.makeOrphanDirectory("pruned");
    defer allocator.free(wt);

    const state = try classifyPath(allocator, std.testing.io, "", wt);
    defer freePathState(allocator, state);
    const gitdir = switch (state) {
        .orphaned_worktree => |g| g,
        else => return error.OrphanNotDetected,
    };
    // A `.git` file is written as "gitdir: <path>\n"; the payload used
    // to keep the newline, which is how the live error read
    // "…/skill-evals-impl-1790542117855\n, but is not registered".
    try testing.expect(std.mem.indexOfScalar(u8, gitdir, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, gitdir, '\r') == null);
}

test "classifyPath: a plain directory is still a plain directory with an empty repo_root" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();

    const plain = try std.fmt.allocPrint(allocator, "{s}/not-a-worktree", .{fx.root});
    defer allocator.free(plain);
    std.Io.Dir.cwd().createDirPath(std.testing.io, plain) catch return error.MkdirFailed;

    const state = try classifyPath(allocator, std.testing.io, "", plain);
    defer freePathState(allocator, state);
    try testing.expectEqual(
        @as(std.meta.Tag(PathState), .plain_directory),
        @as(std.meta.Tag(PathState), std.meta.activeTag(state)),
    );
}

test "classifyPath: a path that does not exist is not_found regardless of repo_root" {
    const allocator = testing.allocator;
    var fx = try GitFixture.init(allocator);
    defer fx.deinit();

    const missing = try std.fmt.allocPrint(allocator, "{s}/never-created", .{fx.root});
    defer allocator.free(missing);

    for ([_][]const u8{ "", fx.repo }) |root| {
        const state = try classifyPath(allocator, std.testing.io, root, missing);
        defer freePathState(allocator, state);
        try testing.expectEqual(
            @as(std.meta.Tag(PathState), .not_found),
            @as(std.meta.Tag(PathState), std.meta.activeTag(state)),
        );
    }
}

// ─── The advice itself ──────────────────────────────────────────────── `rm
// -rf` on a directory that may hold a sibling session's uncommitted work is
// not a recovery step, it is a data-loss footgun, and pabrik — not git — is

test "orphanedWorktreeMessage is non-destructive and offers a preserving recovery" {
    const allocator = testing.allocator;
    const msg = try orphanedWorktreeMessage(
        allocator,
        "/abs/.worktrees/skill-evals-impl-1790542117855",
        "/abs/repo/.git/worktrees/skill-evals-impl-1790542117855",
    );
    defer allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "rm -rf") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "move it aside") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "/abs/.worktrees/skill-evals-impl-1790542117855") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "/abs/repo/.git/worktrees/skill-evals-impl-1790542117855") != null);
    // It must not assert "git says it is not registered" any more — that
    // is the false claim the whole bug was.
    try testing.expect(std.mem.indexOf(u8, msg, "is not registered with git") == null);
}

test "unverifiedWorktreeMessage tells the model to treat the directory as live" {
    const allocator = testing.allocator;
    const msg = try unverifiedWorktreeMessage(
        allocator,
        "/abs/.worktrees/foo",
        "/abs/repo/.git/worktrees/foo",
        "the session has no working directory, so `git worktree list` could not be run",
    );
    defer allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "rm -rf") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "LIVE worktree") != null);
    // The reason the verdict was unproven must be shown, not swallowed.
    try testing.expect(std.mem.indexOf(u8, msg, "no working directory") != null);
}

// ─── Pure helpers: the gitdir pointer and the admin directory ──────────

test "parseGitdirPointer strips the newline git always writes" {
    // The 2026-09-29 tool output literally read
    // "…/skill-evals-impl-1790542117855\n, but is not registered with git".
    try testing.expectEqualStrings(
        "/abs/repo/.git/worktrees/foo",
        parseGitdirPointer("gitdir: /abs/repo/.git/worktrees/foo\n").?,
    );
    try testing.expectEqualStrings(
        "/abs/repo/.git/worktrees/foo",
        parseGitdirPointer("gitdir: /abs/repo/.git/worktrees/foo\r\n").?,
    );
    try testing.expectEqualStrings(
        "/abs/repo/.git/worktrees/foo",
        parseGitdirPointer("gitdir: /abs/repo/.git/worktrees/foo").?,
    );
    // A second space after the colon is not part of the path.
    try testing.expectEqualStrings(
        "/abs/repo/.git/worktrees/foo",
        parseGitdirPointer("gitdir:  /abs/repo/.git/worktrees/foo\n").?,
    );
}

test "parseGitdirPointer rejects anything that is not a gitdir pointer" {
    try testing.expect(parseGitdirPointer("") == null);
    try testing.expect(parseGitdirPointer("gitdir:\n") == null);
    try testing.expect(parseGitdirPointer("gitdir:   \n") == null);
    try testing.expect(parseGitdirPointer("gitdir:/abs/no-space\n") == null);
    try testing.expect(parseGitdirPointer("/abs/repo/.git/worktrees/foo\n") == null);
    try testing.expect(parseGitdirPointer("ref: refs/heads/main\n") == null);
}

test "worktreeAdminDir recognises a linked worktree's admin directory" {
    const cases = [_][]const u8{
        "/abs/repo/.git/worktrees/foo",
        "/abs/repo/.git/worktrees/foo-bar_baz.1",
        "C:/Users/me/repo/.git/worktrees/fix-login",
        "C:\\Users\\me\\repo\\.git\\worktrees\\fix-login",
        // git on Windows can leave a trailing separator behind.
        "/abs/repo/.git/worktrees/foo/",
    };
    for (cases) |gitdir| {
        const admin = worktreeAdminDir(gitdir) orelse {
            std.debug.print("!! worktreeAdminDir did not recognise '{s}' !!\n", .{gitdir});
            return error.AdminDirNotRecognised;
        };
        // A trailing separator is trimmed, because that trimmed path is
        // what gets handed to the existence check.
        try testing.expectEqualStrings(std.mem.trimEnd(u8, gitdir, "/\\"), admin);
    }
}

test "worktreeAdminDir refuses gitdir pointers that are not worktrees" {
    const not_worktrees = [_][]const u8{
        // A submodule's .git file — same `gitdir:` shape, different meaning.
        "/abs/super/.git/modules/sub",
        // The main repository has no admin directory of its own.
        "/abs/repo/.git",
        // The worktrees directory itself, with no name after it.
        "/abs/repo/.git/worktrees",
        // A name is required, not just the directory.
        "/abs/repo/.git/worktrees/",
        // `.git` must be its own component, not a prefix of something.
        "/abs/repo/.gitmodules/worktrees/foo",
        // Not a worktree: one level too shallow.
        "/abs/repo/worktrees/foo",
        "",
        "/",
    };
    for (not_worktrees) |gitdir| {
        try testing.expect(worktreeAdminDir(gitdir) == null);
    }
}

// ─── The listing is a secondary source, not the only one ────────────────

test "parseWorktreeList finds a block in a synthetic listing" {
    const listing =
        \\worktree /abs/repo
        \\HEAD 1111111111111111111111111111111111111111
        \\branch refs/heads/main
        \\
        \\worktree /abs/wt/one
        \\HEAD 2222222222222222222222222222222222222222
        \\branch refs/heads/worktree/one
        \\
        \\
    ;
    const allocator = testing.allocator;
    const hit = (try parseWorktreeList(allocator, listing, "/abs/wt/one")).?;
    defer {
        allocator.free(hit.branch_ref);
        allocator.free(hit.branch);
        allocator.free(hit.commit);
        allocator.free(hit.path);
    }
    try testing.expectEqualStrings("worktree/one", hit.branch);
    try testing.expectEqualStrings("refs/heads/worktree/one", hit.branch_ref);
    try testing.expectEqualStrings("2222222222222222222222222222222222222222", hit.commit);

    // The last block has no trailing blank line — the loop must not need one.
    const no_trailing_blank =
        \\worktree /abs/wt/two
        \\HEAD 3333333333333333333333333333333333333333
        \\branch refs/heads/worktree/two
    ;
    const hit2 = (try parseWorktreeList(allocator, no_trailing_blank, "/abs/wt/two")).?;
    defer {
        allocator.free(hit2.branch_ref);
        allocator.free(hit2.branch);
        allocator.free(hit2.commit);
        allocator.free(hit2.path);
    }
    try testing.expectEqualStrings("worktree/two", hit2.branch);
}

test "parseWorktreeList returns null for an absent or empty listing" {
    const allocator = testing.allocator;
    const listing =
        \\worktree /abs/repo
        \\HEAD 1111111111111111111111111111111111111111
        \\branch refs/heads/main
        \\
    ;
    try testing.expect((try parseWorktreeList(allocator, listing, "/abs/wt/absent")) == null);
    try testing.expect((try parseWorktreeList(allocator, "", "/abs/wt/absent")) == null);
    // A block that names no path at all must not crash or match.
    try testing.expect((try parseWorktreeList(allocator, "HEAD abc\n\n", "/abs/wt/absent")) == null);
}

test "max_worktree_list_bytes leaves headroom over a 272-worktree repository" {
    // 272 worktrees measured 59,257 bytes on the machine where the bug
    // was reported. The old 64 KiB cap was already 90% consumed; anything
    // near it meant every later worktree was silently unparseable.
    const measured = 59_257;
    try testing.expect(max_worktree_list_bytes > measured * 10);
}

// ─── resolveRepoRoot ───────────────────────────────────────────────────

test "resolveRepoRoot keeps a usable absolute session cwd" {
    const allocator = testing.allocator;
    const root = (try resolveRepoRoot(allocator, "/abs/repo")).?;
    defer allocator.free(root);
    try testing.expectEqualStrings("/abs/repo", root);
}

test "resolveRepoRoot returns null for an empty session cwd (caller inherits)" {
    // `sessions.cwd = ''` is the 2026-09-29 state. It must NOT reach
    // std.process.spawn as a cwd — `null` makes the caller use
    // `.cwd = .inherit`, i.e. the server process's own directory.
    try testing.expect((try resolveRepoRoot(testing.allocator, "")) == null);
}

test "resolveRepoRoot ignores a relative session cwd instead of guessing" {
    // "proj" is not a repository — resolving it against the process cwd
    // would silently add the worktree to the wrong repository.
    try testing.expect((try resolveRepoRoot(testing.allocator, "proj")) == null);
}

// Exec adapter — merged from `set_git_worktree.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const llm_history = exec_pabrikcore.llm_history;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;
pub fn execSetGitWorktree(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SetGitWorktreeInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED and names the REPOSITORY the worktree is created
    // from.
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // executeSetGitWorktreeToString returns JSON (![]const u8) — errors are
    // also encoded as {"created":false,"error":"..."} on success paths.
    // We must catch the error union separately.
    const inner = executeSetGitWorktreeToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value.cwd,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (extractJsonError(ctx.allocator, inner)) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the new git_worktree_cwd to the DB so the session
    // remembers it across tool calls.
    if (parsed.value.clear) {
        llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, null) catch |err| {
            ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
        };
    } else if (extractJsonPath(ctx.allocator, inner)) |worktree_path| {
        defer ctx.allocator.free(worktree_path);
        if (worktree_path.len > 0) {
            llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, worktree_path) catch |err| {
                ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
            };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Extract the "error" string from the inner JSON payload.
fn extractJsonError(allocator: std.mem.Allocator, inner: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_val = parsed.value.object.get("error") orelse return null;
    switch (err_val) {
        .null => return null,
        .string => |s| {
            if (s.len == 0) return null;
            return allocator.dupe(u8, s) catch null;
        },
        else => return null,
    }
}

/// Extract the "path" string from the inner JSON payload.
/// Returns null when absent or unparseable. Caller owns the slice.
fn extractJsonPath(allocator: std.mem.Allocator, inner: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path_val = parsed.value.object.get("path") orelse return null;
    switch (path_val) {
        .string => |s| return allocator.dupe(u8, s) catch null,
        .null => return null,
        else => return null,
    }
}

