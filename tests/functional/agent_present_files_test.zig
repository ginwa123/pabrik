// Functional tests for the `present_files` download endpoint. Zig port of
// `tests/functional/agent_present_files_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const TXT_BODY = "hello present files\nsecond line\n";
// Minimal JPEG: SOI + JFIF-ish payload. Magic bytes only matter for
// mime-sniffing tools; here the handler maps by extension.
const JPG_BODY = "\xFF\xD8\xFF\xE0\x00\x10fake-jpeg-payload-1234";
const SPACED_BODY = "a file whose name has a space in it\n";
const SECRET_BODY = "a sibling directory must never be served\n";

// ============================================================================
// sqlite3 CLI helper
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB assertions\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The agent DB inside the isolated tmpdir HOME (Linux layout).
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// `UPDATE sessions SET cwd = <lit> WHERE id = <lit>` — the sandbox-root
/// pin. `.timeout 5000` is the busy_timeout the server's WAL connection
/// needs; a bare CLI invocation would otherwise fail with SQLITE_BUSY.
fn setSessionCwd(temp_dir: []const u8, session_id: []const u8, cwd: []const u8) !void {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);

    const cwd_lit = try sqlLit(cwd);
    defer gpa.free(cwd_lit);
    const sid_lit = try sqlLit(session_id);
    defer gpa.free(sid_lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "UPDATE sessions SET cwd = {s} WHERE id = {s}",
        .{ cwd_lit, sid_lit },
    );
    defer gpa.free(sql);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", db, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term) orelse return error.TestUnexpectedResult;
    if (code != 0) {
        std.debug.print("UPDATE sessions failed ({d}): {s}\n", .{ code, res.stderr });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Fixture + request helpers
// ============================================================================

/// Write `contents` to `<temp_dir>/<rel>`, creating parents. `rel` is a
/// slash-separated path RELATIVE to the harness tempdir — never an
/// absolute literal, for the `isAbsolute` reason in the file header.
fn writeFixture(temp_dir: []const u8, rel: []const u8, contents: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try parts.append(gpa, seg);
    }

    const full = try harness.harnessPath(gpa, temp_dir, parts.items);
    defer gpa.free(full);

    // Create the parent directory chain. `harnessPath` returns an
    // absolute path; walk back to its parent with `dirname` and make
    // that path, then write the leaf.
    const parent = std.fs.path.dirname(full) orelse return error.TestUnexpectedResult;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    var f = try std.Io.Dir.cwd().createFile(io, full, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// `PUT /api/llm/session/<id> {"name": ...}` — PUT auto-creates the
/// sessions row (`ensureSessionExists`); no LLM profile needed.
fn createSession(h: *Harness, session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"present-files-{s}\"}}", .{session_id});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// Create session + sandbox, pin cwd. Returns the sandbox ROOT as owned
/// bytes — `<temp_dir>/present-files-ws`, with `notes.txt` and
/// `photo.jpg` in it.
fn setupSandbox(h: *Harness, session_id: []const u8) ![]u8 {
    try createSession(h, session_id);

    const root = try harness.harnessPath(gpa, h.temp_dir, &.{"present-files-ws"});
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try writeFixture(h.temp_dir, "present-files-ws/notes.txt", TXT_BODY);
    try writeFixture(h.temp_dir, "present-files-ws/photo.jpg", JPG_BODY);

    try setSessionCwd(h.temp_dir, session_id, root);
    return gpa.dupe(u8, root);
}

/// `GET /api/files/download` with the card's query shape. `disposition`
/// is null to omit the parameter entirely (the Python `disposition:
/// str | None` case).
fn download(
    h: *Harness,
    session_id: []const u8,
    path: []const u8,
    disposition: ?[]const u8,
    expect: []const u16,
) !harness.Response {
    var params: [3]harness.Harness.Param = undefined;
    var n: usize = 0;
    params[n] = .{ .name = "session_id", .value = session_id };
    n += 1;
    params[n] = .{ .name = "path", .value = path };
    n += 1;
    if (disposition) |d| {
        params[n] = .{ .name = "disposition", .value = d };
        n += 1;
    }
    return h.http(io, .GET, "/api/files/download", .{
        .params = params[0..n],
        .expect = expect,
    });
}

/// Percent-encode `s` the way the Android client does: RFC 3986 unreserved
/// set only, so a space is `%20` and `+` is `%2B`.
fn androidEncode(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.writer.writeByte(c),
            else => try out.writer.print("%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice();
}

/// Python `_header(resp, name)` — case-insensitive, `""` when absent.
fn header(resp: *const harness.Response, name: []const u8) []const u8 {
    return resp.header(name) orelse "";
}

/// Assert `needle` is present in `hay`, printing both on failure.
fn expectContains(hay: []const u8, needle: []const u8, ctx: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        if (harness.debugString(gpa, hay)) |shown| {
            defer gpa.free(shown);
            std.debug.print("{s}: want \"{s}\", got \"{s}\"\n", .{ ctx, needle, shown });
        } else |_| {
            std.debug.print("{s}: want \"{s}\" (haystack is {d} bytes)\n", .{ ctx, needle, hay.len });
        }
        return error.TestUnexpectedResult;
    }
}

/// Assert `needle` is ABSENT from `hay`.
fn expectAbsent(hay: []const u8, needle: []const u8, ctx: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) != null) {
        std.debug.print("{s}: must not contain \"{s}\"\n", .{ ctx, needle });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// The tool must be wired into UNIFIED_TOOL_REGISTRY (else enable fails).
test "present_files_in_registry" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // Python: `r.json().get("tools", r.json())` — a list of dicts with a
    // `name`, or a list of bare strings.
    const tools_v = doc.get("tools") orelse doc.value().*;
    const tools = switch (tools_v) {
        .array => |a| a,
        else => {
            std.debug.print("registry is not a list: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };

    var found = false;
    for (tools.items) |t| {
        const name: ?[]const u8 = switch (t) {
            .string => |x| x,
            .object => |o| switch (o.get("name") orelse continue) {
                .string => |x| x,
                else => continue,
            },
            else => continue,
        };
        if (name) |n| {
            if (std.mem.eql(u8, n, "present_files")) found = true;
        }
    }
    if (!found) {
        std.debug.print("present_files missing from registry: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// The card's download click: disposition=attachment -> save dialog bytes.
test "txt_download_attachment_is_byte_identical" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);
    const notes = try std.fs.path.join(gpa, &.{ root, "notes.txt" });
    defer gpa.free(notes);

    var r = try download(&h, "sess_present_1", notes, "attachment", &.{200});
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, TXT_BODY)) {
        std.debug.print("body mismatch, got {d} bytes: {s}\n", .{ r.body.len, r.body });
        return error.TestUnexpectedResult;
    }
    const disp = header(&r, "Content-Disposition");
    try expectContains(disp, "attachment", "Content-Disposition");
    try expectContains(disp, "filename=\"notes.txt\"", "Content-Disposition");
    const ctype = header(&r, "Content-Type");
    try expectContains(ctype, "text/plain", "Content-Type");
}

// The card's <img> path: disposition=inline -> browser renders.
test "jpg_inline_preview_is_byte_identical" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);
    const photo = try std.fs.path.join(gpa, &.{ root, "photo.jpg" });
    defer gpa.free(photo);

    var r = try download(&h, "sess_present_1", photo, "inline", &.{200});
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, JPG_BODY)) {
        std.debug.print("inline body must equal the on-disk bytes, got {d} bytes\n", .{r.body.len});
        return error.TestUnexpectedResult;
    }
    const disp = header(&r, "Content-Disposition");
    if (!std.mem.startsWith(u8, disp, "inline")) {
        std.debug.print("want inline disposition, got \"{s}\"\n", .{disp});
        return error.TestUnexpectedResult;
    }
    try expectContains(disp, "filename=\"photo.jpg\"", "Content-Disposition");
    const ctype = header(&r, "Content-Type");
    try expectContains(ctype, "image/jpeg", "Content-Type");
}

// Same jpg via the download button: attachment, identical bytes.
test "jpg_attachment_download" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);
    const photo = try std.fs.path.join(gpa, &.{ root, "photo.jpg" });
    defer gpa.free(photo);

    var r = try download(&h, "sess_present_1", photo, "attachment", &.{200});
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, JPG_BODY)) {
        std.debug.print("jpg attachment body mismatch, got {d} bytes\n", .{r.body.len});
        return error.TestUnexpectedResult;
    }
    try expectContains(header(&r, "Content-Disposition"), "attachment", "Content-Disposition");
}

// An absent path inside the sandbox is a 404, not a 403.
test "missing_file_404" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);
    const nope = try std.fs.path.join(gpa, &.{ root, "nope.txt" });
    defer gpa.free(nope);

    var r = try download(&h, "sess_present_1", nope, "attachment", &.{404});
    defer r.deinit();
}

// A real file that canonicalizes outside the sandbox -> 403, never bytes. The
// probe used to be the literal `/etc/passwd`.
test "traversal_outside_cwd_403" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);

    try writeFixture(h.temp_dir, "beside-the-sandbox/secret.txt", "OUTSIDE_THE_SANDBOX_MARKER");
    const secret = try harness.harnessPath(gpa, h.temp_dir, &.{ "beside-the-sandbox", "secret.txt" });
    defer gpa.free(secret);

    var r = try download(&h, "sess_present_1", secret, "attachment", &.{403});
    defer r.deinit();
    try expectAbsent(r.body, "OUTSIDE_THE_SANDBOX_MARKER", "403 must not leak file contents");
}

// A path with a `..` segment is refused before it canonicalizes.
test "dotdot_rejected_403" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);

    // Built with `std.fs.path.join(root, "..", "notes.txt")` so the `..`
    // survives — `join` here is string concatenation of segments and `..` is
    // a legal one.
    const dotdot = try std.fs.path.join(gpa, &.{ root, "..", "notes.txt" });
    defer gpa.free(dotdot);

    var r = try download(&h, "sess_present_1", dotdot, "attachment", &.{403});
    defer r.deinit();
}

// An unknown session id is a 404 with a non-empty body.
test "unknown_session_404" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // The sandbox is a prerequisite for the probe's SHAPE, not for the
    // assertion: the unknown session id is the only thing under test.
    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);

    // The Python probe used a literal `/tmp/x.txt`; deriving the path keeps
    // it absolute on every platform (the handler checks `isAbsolute` before
    // anything else).
    const missing = try harness.harnessPath(gpa, h.temp_dir, &.{ "present-files-ws", "x.txt" });
    defer gpa.free(missing);

    var r = try h.http(io, .GET, "/api/files/download", .{
        .params = &.{
            .{ .name = "session_id", .value = "sess_does_not_exist" },
            .{ .name = "path", .value = missing },
        },
        .expect = &.{404},
    });
    defer r.deinit();

    if (r.body.len == 0) {
        std.debug.print("error envelope should carry a body\n", .{});
        return error.TestUnexpectedResult;
    }
}

// `disposition=download` is neither `inline` nor `attachment`.
test "invalid_disposition_400" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try setupSandbox(&h, "sess_present_1");
    defer gpa.free(root);
    const notes = try std.fs.path.join(gpa, &.{ root, "notes.txt" });
    defer gpa.free(notes);

    var r = try download(&h, "sess_present_1", notes, "download", &.{400});
    defer r.deinit();
}

// The Android card's exact wire form: `my%20notes.md`, not `my+notes.md`.
test "android_percent_twenty_path_decodes_to_a_space" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createSession(&h, "sess_present_android");
    const root = try harness.harnessPath(gpa, h.temp_dir, &.{"present-files-spaced"});
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writeFixture(h.temp_dir, "present-files-spaced/my notes.md", SPACED_BODY);
    try setSessionCwd(h.temp_dir, "sess_present_android", root);

    const raw_path = try std.fs.path.join(gpa, &.{ root, "my notes.md" });
    defer gpa.free(raw_path);
    const encoded_path = try androidEncode(raw_path);
    defer gpa.free(encoded_path);

    // The Android client percent-encodes spaces as %20 …
    if (std.mem.indexOf(u8, encoded_path, "%20") == null) {
        std.debug.print("the Android client percent-encodes spaces as %20; got: {s}\n", .{encoded_path});
        return error.TestUnexpectedResult;
    }
    // … and never emits a form-style plus.
    if (std.mem.indexOf(u8, encoded_path, "+") != null) {
        std.debug.print("the Android client never emits a form-style plus; got: {s}\n", .{encoded_path});
        return error.TestUnexpectedResult;
    }

    // The query goes inline in the PATH, NOT through `params`: the point
    // is the exact bytes the client puts on the wire, so the test must
    // not hand them to an encoder.
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/files/download?session_id=sess_present_android&path={s}&disposition=inline",
        .{encoded_path},
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, SPACED_BODY)) {
        std.debug.print(
            "the server did not decode %%20 into a space, so the Android client's preview of any file with a space in its name would 404; got {d} bytes: {s}\n",
            .{ r.body.len, r.body },
        );
        return error.TestUnexpectedResult;
    }
    // The decoded name must survive into Content-Disposition so a viewer
    // app and the Open action agree on what the file is called.
    try expectContains(header(&r, "Content-Disposition"), "filename=\"my notes.md\"", "Content-Disposition");
}

// `present-files-ws-evil` is NOT inside `present-files-ws`.
fn sandboxWithSibling(h: *Harness) ![]u8 {
    try createSession(h, "sess_present_boundary");

    const root = try harness.harnessPath(gpa, h.temp_dir, &.{"present-files-ws"});
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writeFixture(h.temp_dir, "present-files-ws/notes.txt", "inside\n");
    try writeFixture(h.temp_dir, "present-files-ws/nested/deep.txt", "nested inside\n");

    const sibling = try std.fmt.allocPrint(gpa, "{s}-evil", .{root});
    defer gpa.free(sibling);
    std.Io.Dir.cwd().createDirPath(io, sibling) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const secret = try std.fs.path.join(gpa, &.{ sibling, "secret.txt" });
    defer gpa.free(secret);
    try writeFixture(h.temp_dir, "present-files-ws-evil/secret.txt", SECRET_BODY);

    try setSessionCwd(h.temp_dir, "sess_present_boundary", root);
    return gpa.dupe(u8, root);
}

test "sibling_dir_sharing_the_root_prefix_is_403" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try sandboxWithSibling(&h);
    defer gpa.free(root);

    const sibling_root = try std.fmt.allocPrint(gpa, "{s}-evil", .{root});
    defer gpa.free(sibling_root);
    const sibling = try std.fs.path.join(gpa, &.{ sibling_root, "secret.txt" });
    defer gpa.free(sibling);

    // The fixture must exist, else the test proves nothing.
    std.Io.Dir.cwd().access(io, sibling, .{}) catch {
        std.debug.print("fixture must exist, else the test proves nothing: {s}\n", .{sibling});
        return error.TestUnexpectedResult;
    };

    var r = try download(&h, "sess_present_boundary", sibling, null, &.{403});
    defer r.deinit();
    try expectAbsent(r.body, SECRET_BODY, "a sibling directory must never be served");
}

// The other half of the same rule — refusing the sibling must not
// refuse the sandbox's own subdirectories.
test "nested_file_inside_the_root_is_still_200" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const root = try sandboxWithSibling(&h);
    defer gpa.free(root);

    const deep = try std.fs.path.join(gpa, &.{ root, "nested", "deep.txt" });
    defer gpa.free(deep);

    var r = try download(&h, "sess_present_boundary", deep, null, &.{200});
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, "nested inside\n")) {
        std.debug.print("nested body mismatch, got {d} bytes: {s}\n", .{ r.body.len, r.body });
        return error.TestUnexpectedResult;
    }
}

// `report..html` is one filename, not a `..` segment. The endpoint and
// the `present_files` tool share one rule now, and a filename with two
// dots in it is a thing the agent presents.
test "a_dotted_filename_is_not_treated_as_traversal" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createSession(&h, "sess_present_dots");
    const root = try harness.harnessPath(gpa, h.temp_dir, &.{"present-files-dots"});
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writeFixture(h.temp_dir, "present-files-dots/IRON-11463 SB-02 .. final.html", "<h1>dots</h1>");
    try setSessionCwd(h.temp_dir, "sess_present_dots", root);

    const file = try std.fs.path.join(gpa, &.{ root, "IRON-11463 SB-02 .. final.html" });
    defer gpa.free(file);

    // Passed through `params`, so the two SPACES and the `..` are
    // percent-encoded by the harness exactly as `encodeURIComponent`
    // would.
    var r = try download(&h, "sess_present_dots", file, null, &.{200});
    defer r.deinit();

    if (!std.mem.eql(u8, r.body, "<h1>dots</h1>")) {
        std.debug.print("dotted filename body mismatch, got {d} bytes: {s}\n", .{ r.body.len, r.body });
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = sqlLit;
    _ = dbPath;
    _ = setSessionCwd;
    _ = writeFixture;
    _ = createSession;
    _ = setupSandbox;
    _ = download;
    _ = androidEncode;
    _ = header;
    _ = expectContains;
    _ = expectAbsent;
    _ = sandboxWithSibling;
}
