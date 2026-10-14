// src/service/crash_handler.zig Crash signal/exception handler — the missing
// sibling to root.zig's `panicHandler`.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Module-level panic log path
// =============================================================================

/// Path to the panic log file. Set by `setCrashLogPath(path)` BEFORE
/// `installCrashHandlers()` is called. Mirrors `root.zig::panic_log_path`
/// but kept separate to avoid a circular import.
var crash_log_path: ?[]const u8 = null;

pub fn setCrashLogPath(path: []const u8) void {
    crash_log_path = path;
}

pub fn getCrashLogPath() ?[]const u8 {
    return crash_log_path;
}

// =============================================================================
// Public entry point
// =============================================================================

/// Install crash signal/exception handlers.
pub fn installCrashHandlers() void {
    switch (builtin.os.tag) {
        .linux, .macos => installCrashHandlersPosix(),
        .windows => installCrashHandlersWindows(),
        else => {}, // unsupported — silently no-op
    }
}

// =============================================================================
// Shared helpers (pure, testable outside signal context)
// =============================================================================

/// Human-readable one-liner for each crash signal — the "why did my
/// process die" line. Shown directly under the `=== CRASH ===` header so
/// the most likely cause is visible without decoding anything else.
pub fn signalDescription(sig: std.c.SIG) []const u8 {
    if (sig == std.c.SIG.SEGV) return "invalid memory reference (null deref, use-after-free, bad pointer, stack overflow)";
    // SIGBUS is POSIX-only — std.c.SIG has no BUS member on Windows,
    // so the reference must live behind a comptime gate (untaken
    // branches of `if (comptime ...)` are never analyzed).
    if (comptime builtin.os.tag != .windows) {
        if (sig == std.c.SIG.BUS) return "bus error (misaligned access, truncated mmap'd file, hardware fault)";
    }
    if (sig == std.c.SIG.ABRT) return "abort (explicit abort(), failed assertion, debug-allocator error such as Invalid free)";
    if (sig == std.c.SIG.ILL) return "illegal instruction (corrupt code, bad JIT emit, wrong-arch binary)";
    if (sig == std.c.SIG.FPE) return "arithmetic exception (divide by zero, integer overflow trap)";
    return "unknown crash signal";
}

/// Decode `si_code` (the kernel's sub-reason) for the given signal into a
/// human-readable string.
pub fn siCodeMeaning(sig: std.c.SIG, code: i32) []const u8 {
    // Non-positive codes are sender identities (SI_USER=0, SI_QUEUE=-1,
    // SI_TIMER=-2, SI_MESGQ=-3, SI_ASYNCIO=-4, SI_SIGIO=-5, SI_TKILL=-6), not
    // hardware sub-reasons — typical when the signal was sent via
    if (code <= 0) {
        if (sig == std.c.SIG.ABRT) return "sender code (abort() / raise() — no fault address by design)";
        return "sender code (sent via kill()/raise() — no hardware fault; the address above is the sender, not a fault address)";
    }
    if (sig == std.c.SIG.SEGV) {
        return switch (code) {
            1 => "SEGV_MAPERR (address not mapped to any object)",
            2 => "SEGV_ACCERR (invalid permissions for mapped object)",
            3 => "SEGV_BNDERR (failed address bounds check)",
            4 => "SEGV_PKUERR (protection-key violation)",
            else => "unknown SEGV code",
        };
    }
    // Same POSIX-only gate as signalDescription above.
    if (comptime builtin.os.tag != .windows) {
        if (sig == std.c.SIG.BUS) {
            return switch (code) {
                1 => "BUS_ADRALN (invalid address alignment)",
                2 => "BUS_ADRERR (nonexistent physical address)",
                3 => "BUS_OBJERR (object-specific hardware error)",
                else => "unknown BUS code",
            };
        }
    }
    if (sig == std.c.SIG.ILL) {
        return switch (code) {
            1 => "ILL_ILLOPC (illegal opcode)",
            2 => "ILL_ILLOPN (illegal operand)",
            3 => "ILL_ILLADR (illegal addressing mode)",
            4 => "ILL_ILLTRP (illegal trap)",
            5 => "ILL_PRVOPC (privileged opcode)",
            6 => "ILL_PRVREG (privileged register)",
            7 => "ILL_COPROC (coprocessor error)",
            8 => "ILL_BADSTK (internal stack error)",
            else => "unknown ILL code",
        };
    }
    if (sig == std.c.SIG.FPE) {
        return switch (code) {
            1 => "FPE_INTDIV (integer divide by zero)",
            2 => "FPE_INTOVF (integer overflow)",
            3 => "FPE_FLTDIV (floating-point divide by zero)",
            4 => "FPE_FLTOVF (floating-point overflow)",
            5 => "FPE_FLTUND (floating-point underflow)",
            6 => "FPE_FLTRES (floating-point inexact result)",
            7 => "FPE_FLTINV (invalid floating-point operation)",
            8 => "FPE_FLTSUB (subscript out of range)",
            else => "unknown FPE code",
        };
    }
    // SIGABRT and friends: si_code is typically SI_USER/SI_TKILL (the
    // sender's identity), not a crash sub-reason — just label it.
    return "sender code (not a crash sub-reason)";
}

/// Classify a fault address into the bucket that matters for debugging:
/// NULL, near-NULL (null struct-field access), low (null-derived), or a
/// wild/unmapped pointer. Pure function — unit-testable.
pub fn classifyFaultAddr(addr: usize) []const u8 {
    if (addr == 0) return "NULL dereference";
    if (addr < 0x1000) return "near-NULL (null pointer + small offset — likely a null struct-field access)";
    if (addr < 0x10000) return "low address (likely a null-derived pointer)";
    return "wild/unmapped pointer (use-after-free, buffer overflow, bad cast?)";
}

/// Extract the faulting address from a POSIX `siginfo_t` in a portable way.
/// Linux fills `fields.sigfault.addr`; Darwin/libc exposes a top-level
/// `si_addr`; other libcs vary.
pub fn faultAddrFromSiginfo(info: *const std.posix.siginfo_t) usize {
    const Info = @TypeOf(info.*);
    // Darwin/libc shape: top-level si_addr.
    if (@hasField(Info, "si_addr")) {
        const p = info.si_addr;
        switch (@typeInfo(@TypeOf(p))) {
            .pointer => return @intFromPtr(p),
            .optional => {
                if (p) |nonnull| return @intFromPtr(nonnull);
                return 0;
            },
            .int => return @as(usize, @intCast(p)),
            else => return 0,
        }
    }
    // Linux shape: fields.sigfault.addr (*allowzero anyopaque).
    if (@hasField(Info, "fields")) {
        const Fields = @TypeOf(info.fields);
        if (@hasField(Fields, "sigfault")) {
            const sf = info.fields.sigfault;
            if (@hasField(@TypeOf(sf), "addr")) {
                return @intFromPtr(sf.addr);
            }
        }
        if (@hasField(Fields, "addr")) {
            return @intFromPtr(info.fields.addr);
        }
    }
    return 0;
}

/// Extract `si_code` portably (Linux: `.code`, Darwin/libc: `.si_code`).
pub fn siCodeFromSiginfo(info: *const std.posix.siginfo_t) i32 {
    const Info = @TypeOf(info.*);
    if (@hasField(Info, "code")) return info.code;
    if (@hasField(Info, "si_code")) return info.si_code;
    return 0;
}

/// Symbolicate a captured stack trace into `function (file:line)` form using
/// the binary's own debug info. Returns an owned slice on success.
pub fn symbolicateStack(
    allocator: std.mem.Allocator,
    stack: *const std.debug.StackTrace,
) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const term: std.Io.Terminal = .{ .writer = &aw.writer, .mode = .no_color };
    std.debug.writeStackTrace(stack, term) catch return null;
    const out = aw.writer.buffered();
    if (out.len == 0) return null;
    // writeStackTrace prints a "Cannot print stack trace: ..." notice instead
    // of frames when debug info is unavailable — treat that as "no
    // symbolication" so the caller prints the fallback line instead of a
    if (std.mem.indexOf(u8, out, "Cannot print stack trace") != null) return null;
    if (std.mem.indexOf(u8, out, "(empty stack trace)") != null) return null;
    return allocator.dupe(u8, out) catch null;
}

/// Format raw return addresses, one `0x…` per line — the addr2line
/// fallback. Always succeeds on a best-effort basis (empty string on
/// OOM). The caller prints the `addr2line -e <exe>` hint above it.
pub fn formatRawAddrs(
    allocator: std.mem.Allocator,
    addrs: []const usize,
) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var line: [32]u8 = undefined;
    for (addrs) |ra| {
        const s = std.fmt.bufPrint(&line, "  0x{x:0>16}\n", .{ra}) catch continue;
        buf.appendSlice(allocator, s) catch break;
    }
    // Ownership transfer: toOwnedSlice shrinks the buffer to the exact length
    // so the caller can free it with a plain allocator.free.
    const owned = buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return "";
    };
    return owned;
}

// =============================================================================
// Stack capture — every entry point must go through here
// =============================================================================

/// How to capture the stack for a crash report. `context` is the *crashing*
/// `CpuContextPtr` supplied by the OS.
pub const StackCapture = struct {
    context: ?std.debug.CpuContextPtr = null,

    pub fn options(self: StackCapture) std.debug.StackUnwindOptions {
        return .{ .context = self.context, .allow_unsafe_unwind = true };
    }
};

/// Capture a crash stack. `addr_buf` must outlive the returned trace.
pub fn captureCrashStack(capture: StackCapture, addr_buf: []usize) std.debug.StackTrace {
    return std.debug.captureCurrentStackTrace(capture.options(), addr_buf);
}

/// POSIX: build a `CpuContextPtr` from the `ucontext` the kernel handed the
/// signal handler.
pub fn posixCpuContext(ucontext: ?*anyopaque, out: *std.debug.cpu_context.Native) ?std.debug.CpuContextPtr {
    const ctx = ucontext orelse return null;
    const native = std.debug.cpu_context.fromPosixSignalContext(ctx) orelse return null;
    out.* = native;
    return out;
}

// =============================================================================
// POSIX (Linux + macOS)
// =============================================================================

fn installCrashHandlersPosix() void {
    // The set of crash signals we want to log. Order doesn't matter.
    const signals = [_]std.c.SIG{
        std.c.SIG.SEGV,
        std.c.SIG.BUS,
        std.c.SIG.ABRT,
        std.c.SIG.ILL,
        std.c.SIG.FPE,
    };

    for (signals) |sig| {
        // SA_SIGINFO: deliver siginfo_t + ucontext so the handler can log the
        // fault address and si_code — the two fields that answer "WHY did it
        // crash", not just "WHERE".
        var sa: std.c.Sigaction = .{
            .handler = .{ .sigaction = handleCrashSignalSiginfo },
            .mask = std.mem.zeroes(std.c.sigset_t),
            .flags = std.c.SA.SIGINFO | std.c.SA.RESTART,
        };
        // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try.
        // The 2nd arg is `?*const Sigaction`; we have a mutable pointer.
        std.posix.sigaction(sig, &sa, null);
    }
}

/// POSIX crash handler (SA_SIGINFO 3-arg form). Runs in signal context — only
/// async-signal-safe (or best-effort) operations allowed.
fn handleCrashSignalSiginfo(
    sig: std.c.SIG,
    info: *const std.posix.siginfo_t,
    ucontext: ?*anyopaque,
) callconv(.c) void {
    // The ucontext is the register state at the instant of the fault. It
    // is the ONLY way to make frame 0 of the report the faulting
    // instruction rather than this handler — see StackCapture.
    var native_ctx: std.debug.cpu_context.Native = undefined;
    const crashing_ctx = posixCpuContext(ucontext, &native_ctx);
    // STEP 1 — restore the OS default handler BEFORE logging.
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(sig, &sa, null);

    // STEP 2 — build the report. Uses page_allocator (best-effort — OOM
    // is silently dropped, each section degrades independently).
    const alloc = std.heap.page_allocator;
    const signal_name = @tagName(sig);
    const desc = signalDescription(sig);
    const si_code = siCodeFromSiginfo(info);
    const si_meaning = siCodeMeaning(sig, si_code);
    const has_fault_addr = sig == std.c.SIG.SEGV or sig == std.c.SIG.BUS or
        sig == std.c.SIG.ILL or sig == std.c.SIG.FPE;
    const fault_addr = if (has_fault_addr) faultAddrFromSiginfo(info) else 0;

    const header = std.fmt.allocPrint(alloc,
        \\=== CRASH: received signal {s} (signal number {d}) ===
        \\Why: {s}
        \\
    , .{ signal_name, @intFromEnum(sig), desc }) catch "=== CRASH: received signal (name unavailable) ===\n";
    defer alloc.free(header);

    // Fault line: address + classification + si_code meaning. For SIGABRT
    // there is no fault address — say so explicitly instead of printing a
    // meaningless reinterpreted-union value.
    const fault_line = if (has_fault_addr)
        std.fmt.allocPrint(alloc,
            "Fault address: 0x{x} ({s})\nsi_code: {d} ({s})\nBuild: {s}, {s}-{s}\n",
            .{ fault_addr, classifyFaultAddr(fault_addr), si_code, si_meaning, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ) catch ""
    else
        std.fmt.allocPrint(alloc,
            "Fault address: n/a (abort-style signal carries sender info, not a fault address)\nsi_code: {d} ({s})\nBuild: {s}, {s}-{s}\n",
            .{ si_code, si_meaning, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ) catch "";
    defer if (fault_line.len > 0) alloc.free(fault_line);

    // STEP 3 — write the report (crash log file first, then stderr).
    emitCrashReport(alloc, header, fault_line, .{ .context = crashing_ctx });

    // STEP 5 — re-raise so the OS default action runs (terminate + core
    // dump). std.c.raise returns c_int (0 on success, -1 on failure).
    _ = std.c.raise(sig);
    // Either the signal is queued and will be delivered via SIG_DFL on
    // handler return (the normal path — produces a core dump), or raise()
    // itself failed; in that case fall through to _Exit which is
    std.c._Exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}

// =============================================================================
// Windows
// =============================================================================

/// Bind the Win32 SetUnhandledExceptionFilter API. The filter callback
/// receives a pointer to `EXCEPTION_POINTERS` (exception record +
/// context) for the crash.
const win32_apis = if (builtin.os.tag == .windows) struct {
    /// EXCEPTION_EXECUTE_HANDLER is the value the UEF returns to tell
    /// the kernel "I've handled it; unwind and terminate". NOT exposed
    /// by `std.os.windows` in Zig 0.16 — declared here per WinNT.h.
    pub const EXCEPTION_EXECUTE_HANDLER: c_long = 1;

    /// Function pointer type for SetUnhandledExceptionFilter's callback.
    /// Returns LONG (c_long); WINAPI = __stdcall on x86 = callconv(.winapi)
    /// in Zig 0.16.
    pub const UnhandledExceptionFilterFn = *const fn (
        exception_info: *std.os.windows.EXCEPTION_POINTERS,
    ) callconv(.winapi) c_long;

    extern "kernel32" fn SetUnhandledExceptionFilter(
        filter: ?UnhandledExceptionFilterFn,
    ) callconv(.winapi) ?UnhandledExceptionFilterFn;
} else struct {};

fn installCrashHandlersWindows() void {
    _ = win32_apis.SetUnhandledExceptionFilter(handleWindowsException);
}

/// Human-readable one-liner for a Win32 exception code.
pub fn windowsExceptionDescription(code: u32) []const u8 {
    return switch (code) {
        0xC0000005 => "EXCEPTION_ACCESS_VIOLATION (invalid memory reference — SIGSEGV equivalent)",
        0xC000001D => "EXCEPTION_ILLEGAL_INSTRUCTION (SIGILL equivalent)",
        // std's vectored handler intercepts this one, so the UEF never
        // sees it — but the description is still needed for the report
        // the vectored handler routes through handleSegfaultReport.
        0x80000002 => "EXCEPTION_DATATYPE_MISALIGNMENT (unaligned memory access)",
        0xC0000094 => "EXCEPTION_INT_DIVIDE_BY_ZERO (SIGFPE equivalent)",
        0xC00000FD => "EXCEPTION_STACK_OVERFLOW (exhausted stack — check for unbounded recursion)",
        0xC0000409 => "EXCEPTION_STACK_BUFFER_OVERRUN / FAIL_FAST (buffer overrun or /GS cookie check)",
        0xC0000374 => "EXCEPTION_HEAP_CORRUPTION (heap metadata damaged — use-after-free / overflow)",
        0x80000003 => "EXCEPTION_BREAKPOINT (debug breakpoint hit outside a debugger)",
        0xC000008C => "EXCEPTION_ARRAY_BOUNDS_EXCEEDED (out-of-bounds access trap)",
        0xC0000090 => "EXCEPTION_FLT_INVALID_OPERATION (invalid floating-point operation)",
        0xC0000091 => "EXCEPTION_FLT_OVERFLOW (floating-point overflow)",
        0xC0000093 => "EXCEPTION_FLT_UNDERFLOW (floating-point underflow)",
        0xC0000092 => "EXCEPTION_FLT_DIVIDE_BY_ZERO (floating-point divide by zero)",
        0xC0000096 => "EXCEPTION_INT_OVERFLOW (integer overflow trap)",
        else => "unknown Windows exception",
    };
}

/// Windows unhandled exception filter. Runs in exception-dispatch context —
/// equivalent to a signal handler for crash purposes.
fn handleWindowsException(exception_info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const alloc = std.heap.page_allocator;
    const rec = exception_info.ExceptionRecord;
    const code: u32 = @bitCast(rec.ExceptionCode);
    const addr = @intFromPtr(rec.ExceptionAddress);

    const header = std.fmt.allocPrint(alloc,
        \\=== CRASH: Windows exception 0x{x:0>8} at address 0x{x} ===
        \\Why: {s}
        \\Build: {s}, {s}-{s}
        \\
    , .{ code, addr, windowsExceptionDescription(code), @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) }) catch "=== CRASH: Windows exception (details unavailable) ===\n";
    defer alloc.free(header);

    // For ACCESS_VIOLATION the record carries 2 info words:
    //   [0] = 0 read / 1 write / 8 DEP violation, [1] = fault address.
    var access_line: []const u8 = "";
    if (code == 0xC0000005 and rec.NumberParameters >= 2) {
        const rw = rec.ExceptionInformation[0];
        const fault: usize = @intCast(rec.ExceptionInformation[1]);
        const rw_txt: []const u8 = switch (rw) {
            0 => "read",
            1 => "write",
            8 => "DEP/execute (data-execution-prevention)",
            else => "unknown access kind",
        };
        access_line = std.fmt.allocPrint(alloc,
            "Access: {s} at fault address 0x{x} ({s})\n",
            .{ rw_txt, fault, classifyFaultAddr(fault) },
        ) catch "";
    }
    defer if (access_line.len > 0) alloc.free(access_line);

    // The CONTEXT record is the register state at the instant of the fault.
    var native_ctx = std.debug.cpu_context.fromWindowsContext(exception_info.ContextRecord);

    emitCrashReport(alloc, header, access_line, .{ .context = &native_ctx });

    return win32_apis.EXCEPTION_EXECUTE_HANDLER;
}

// =============================================================================
// std.debug.handleSegfault override — the seam that actually fires on Windows
// =============================================================================

/// Zig's `std.debug` routes every hardware fault through
/// `root.debug.handleSegfault` if the root source file declares it
/// (`std/debug.zig:1633`, overridable precisely so a program can install its
pub fn handleSegfaultReport(
    addr: ?usize,
    name: []const u8,
    context: ?std.debug.CpuContextPtr,
) noreturn {
    const alloc = std.heap.page_allocator;
    const fault_addr = addr orelse 0;

    const header = std.fmt.allocPrint(alloc,
        \\=== CRASH: {s} ===
        \\Why: {s}
        \\Build: {s}, {s}-{s}
        \\
    , .{ name, segfaultWhy(name), @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) }) catch "=== CRASH: unrecoverable fault ===\n";
    defer alloc.free(header);

    const detail = std.fmt.allocPrint(alloc,
        "Fault address: 0x{x} ({s})\n",
        .{ fault_addr, if (addr == null) "no address available" else classifyFaultAddr(fault_addr) },
    ) catch "";
    defer if (detail.len > 0) alloc.free(detail);

    emitCrashReport(alloc, header, detail, .{ .context = context });

    // Match std's own contract: the faulting instruction is not safe to
    // re-execute (the memory may have been mapped since), so terminate
    // rather than return. abort() also produces the core dump on POSIX.
    std.process.abort();
}

/// Turn std's short fault name into the "why did this happen" sentence the
/// report leads with.
fn segfaultWhy(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Segmentation fault")) return "invalid memory reference (null deref, use-after-free, bad pointer, wild/unmapped access)";
    if (std.mem.eql(u8, name, "Illegal instruction")) return "illegal instruction (corrupt code, bad JIT emit, wrong-arch binary)";
    if (std.mem.eql(u8, name, "Stack overflow")) return "stack exhausted — check for unbounded recursion";
    if (std.mem.eql(u8, name, "Unaligned memory access")) return "misaligned memory access";
    if (std.mem.eql(u8, name, "Bus error")) return "bus error (misaligned access, truncated mmap'd file, hardware fault)";
    if (std.mem.eql(u8, name, "Arithmetic exception")) return "arithmetic exception (divide by zero, integer overflow trap)";
    return "unrecoverable hardware fault";
}

/// Capture the stack, symbolicate it, and write `header` + `detail` + both
/// stack sections to the crash log and mirror them to stderr.
fn emitCrashReport(
    allocator: std.mem.Allocator,
    header: []const u8,
    detail: []const u8,
    capture: StackCapture,
) void {
    var addr_buf: [64]usize = undefined;
    const stack = captureCrashStack(capture, &addr_buf);

    const sym = symbolicateStack(allocator, &stack);
    defer if (sym) |s| allocator.free(s);

    const sym_section = if (sym) |s|
        std.fmt.allocPrint(allocator,
            "Symbolicated stack trace ({d} frames — function + file:line):\n{s}",
            .{ stack.return_addresses.len, s },
        ) catch ""
    else
        std.fmt.allocPrint(allocator,
            "Symbolicated stack trace: UNAVAILABLE (stripped binary or no debug info — see raw addresses below)\n",
            .{},
        ) catch "";
    defer if (sym_section.len > 0) allocator.free(sym_section);

    const raw = formatRawAddrs(allocator, stack.return_addresses);
    defer allocator.free(raw);
    const raw_section = std.fmt.allocPrint(allocator,
        \\Raw addresses ({d} frames — post-mortem: addr2line -e <exe> <addr>):
        \\{s}
    , .{ stack.return_addresses.len, raw }) catch "";
    defer if (raw_section.len > 0) allocator.free(raw_section);

    const footer = "\n=============\n";
    appendToCrashLog(&.{ header, detail, sym_section, raw_section, footer });
    std.debug.print("{s}{s}{s}{s}{s}", .{ header, detail, sym_section, raw_section, footer });
}

/// Append the section slices to the configured crash log.
fn appendToCrashLog(sections: []const []const u8) void {
    const path = crash_log_path orelse return;
    var path_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const path_z_ptr: [*:0]const u8 = @ptrCast(&path_z);
    const file = std.c.fopen(path_z_ptr, "a") orelse return;
    defer _ = std.c.fclose(file);
    for (sections) |s| {
        if (s.len == 0) continue;
        _ = std.c.fwrite(s.ptr, 1, s.len, file);
    }
}

/// The `root.debug` namespace each root source file re-exports.
pub const root_debug = struct {
    pub const handleSegfault = handleSegfaultReport;
};

// ===== Tests merged from crash_handler_test.zig (2026-09-29 flatten) =====

// Tests for src/service/crash_handler.zig (crash signal/exception handler). A
// real crash handler can't be exercised in-process — SIGSEGV / SIGBUS /
// SIGABRT / SIGILL / SIGFPE / ACCESS_VIOLATION all terminate the process.

const testing = std.testing;

// ─── Contract 0: installCrashHandlers is callable cross-platform ───────

test "installCrashHandlers is callable cross-platform" {
    // Taking the address forces the comptime `switch (builtin.os.tag)`
    // to materialise a real body on every platform. If any branch
    // throws `@compileError`, this fails to compile.
    const function_pointer = &installCrashHandlers;
    _ = function_pointer;
    try testing.expect(true);
}

// ─── Contract 8: installCrashHandlers is idempotent ────────────────────

test "installCrashHandlers is safe to call twice" {
    // The function should be a no-op on the second call (or at minimum not
    // crash).
    installCrashHandlers();
    installCrashHandlers();
    try testing.expect(true);
}

// ─── StackCapture: the crashing context must be threaded through ─────

test "StackCapture.options forwards the crashing context to the unwinder" {
    var native: std.debug.cpu_context.Native = undefined;
    // Any well-defined register snapshot is a valid context to forward;
    // what is under test is that the option is not silently dropped.
    const ctx: std.debug.CpuContextPtr = &native;
    const opts = (StackCapture{ .context = ctx }).options();
    try testing.expectEqual(@intFromPtr(ctx), @intFromPtr(opts.context.?));
}

test "StackCapture.options always allows unsafe unwind" {
    // Inside a fatal fault, a "safe-only" unwind policy trades a partial
    // report for none at all. It must never be selectable.
    var native: std.debug.cpu_context.Native = undefined;
    const with_ctx = (StackCapture{ .context = &native }).options();
    const without_ctx = (StackCapture{}).options();
    try testing.expect(with_ctx.allow_unsafe_unwind);
    try testing.expect(without_ctx.allow_unsafe_unwind);
}

test "StackCapture with a null context still captures a trace rather than failing" {
    // ReleaseFast has no vectored segfault handler, so the UEF path is the
    // only net and may have no usable context. It must degrade to a
    // context-less capture, not to a crash inside the crash handler.
    var addr_buf: [8]usize = undefined;
    const stack = captureCrashStack(.{}, &addr_buf);
    try testing.expect(stack.return_addresses.len <= addr_buf.len);
}

test "posixCpuContext returns null for a null ucontext instead of faulting" {
    var native: std.debug.cpu_context.Native = undefined;
    try testing.expect(posixCpuContext(null, &native) == null);
}

// ─── root.debug.handleSegfault: the Windows ordering contract ─────────

test "root_debug exposes the handleSegfault seam std requires" {
    // std/debug.zig dispatches on `@hasDecl(root.debug, "handleSegfault")`
    // and calls it as `fn (?usize, []const u8, ?CpuContextPtr) noreturn`.
    const f: *const fn (?usize, []const u8, ?std.debug.CpuContextPtr) noreturn = &root_debug.handleSegfault;
    _ = f;
    try testing.expect(true);
}

test "windowsExceptionDescription names every code std's vectored handler swallows" {
    // std/debug.zig `handleSegfaultWindows` intercepts exactly these four and
    // aborts without consulting us.
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC0000005), "ACCESS_VIOLATION") != null);
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC000001D), "ILLEGAL_INSTRUCTION") != null);
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC00000FD), "STACK_OVERFLOW") != null);
    // DATATYPE_MISALIGNMENT is intercepted by std but absent from the
    // switch — pin it so the gap is a test failure, not a silent shrug.
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0x80000002), "MISALIGNMENT") != null);
}

test "windowsExceptionDescription names the codes only the UEF can catch" {
    // These are NOT in std's vectored handler, so `handleWindowsException`
    // is the only thing standing between them and a silent death. They
    // must stay described.
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC0000374), "HEAP_CORRUPTION") != null);
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC0000409), "FAIL_FAST") != null);
    try testing.expect(std.mem.indexOf(u8, windowsExceptionDescription(0xC000008C), "ARRAY_BOUNDS") != null);
}

test "an unrecognised exception code says so instead of guessing" {
    try testing.expectEqualStrings("unknown Windows exception", windowsExceptionDescription(0xDEADBEEF));
}

// ─── signalDescription: one-liner per crash signal ────────────────────

test "signalDescription names each crash signal" {
    try testing.expect(std.mem.indexOf(u8, signalDescription(std.c.SIG.SEGV), "invalid memory reference") != null);
    // SIGBUS doesn't exist on Windows (see crash_handler.zig) — skip.
    if (comptime builtin.os.tag != .windows) {
        try testing.expect(std.mem.indexOf(u8, signalDescription(std.c.SIG.BUS), "bus error") != null);
    }
    try testing.expect(std.mem.indexOf(u8, signalDescription(std.c.SIG.ABRT), "abort") != null);
    try testing.expect(std.mem.indexOf(u8, signalDescription(std.c.SIG.ILL), "illegal instruction") != null);
    try testing.expect(std.mem.indexOf(u8, signalDescription(std.c.SIG.FPE), "arithmetic") != null);
}

// ─── siCodeMeaning: hardware sub-reason decoding ──────────────────────

test "siCodeMeaning decodes hardware sub-reasons" {
    const SEGV = std.c.SIG.SEGV;
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(SEGV, 1), "MAPERR") != null);
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(SEGV, 2), "ACCERR") != null);
    if (comptime builtin.os.tag != .windows) {
        try testing.expect(std.mem.indexOf(u8, siCodeMeaning(std.c.SIG.BUS, 1), "ADRALN") != null);
    }
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(std.c.SIG.ILL, 1), "ILLOPC") != null);
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(std.c.SIG.FPE, 1), "INTDIV") != null);
}

test "siCodeMeaning treats non-positive codes as sender codes" {
    // kill()/raise()/abort()-delivered signals carry a sender identity
    // (SI_TKILL=-6, SI_USER=0), not a hardware sub-reason. The decoder
    // must say so instead of "unknown SEGV code".
    const SEGV = std.c.SIG.SEGV;
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(SEGV, -6), "sender") != null);
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(SEGV, 0), "sender") != null);
    try testing.expect(std.mem.indexOf(u8, siCodeMeaning(std.c.SIG.ABRT, -6), "sender") != null);
}

// ─── classifyFaultAddr: address buckets ───────────────────────────────

test "classifyFaultAddr buckets fault addresses" {
    try testing.expectEqualStrings("NULL dereference", classifyFaultAddr(0));
    try testing.expect(std.mem.indexOf(u8, classifyFaultAddr(0x10), "near-NULL") != null);
    try testing.expect(std.mem.indexOf(u8, classifyFaultAddr(0x5000), "low address") != null);
    try testing.expect(std.mem.indexOf(u8, classifyFaultAddr(0xdeadbeef), "wild/unmapped") != null);
}

// ─── faultAddrFromSiginfo / siCodeFromSiginfo: siginfo extraction ─────

test "faultAddrFromSiginfo and siCodeFromSiginfo extract siginfo fields" {
    // Linux-only: the test constructs the Linux siginfo_t shape
    // (fields.sigfault.addr). Other platforms have a different layout.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var info = std.mem.zeroes(std.posix.siginfo_t);
    info.code = 1;
    info.fields = .{ .sigfault = .{
        .addr = @ptrFromInt(0xdeadbeef),
        .addr_lsb = 0,
        .first = .{ .pkey = 0 },
    } };

    try testing.expectEqual(@as(usize, 0xdeadbeef), faultAddrFromSiginfo(&info));
    try testing.expectEqual(@as(i32, 1), siCodeFromSiginfo(&info));
}

// ─── formatRawAddrs: deterministic hex formatting ─────────────────────

test "formatRawAddrs formats one hex line per address" {
    const addrs = [_]usize{ 0x1, 0xabcdef };
    const out = formatRawAddrs(testing.allocator, &addrs);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  0x0000000000000001\n  0x0000000000abcdef\n", out);
}

test "formatRawAddrs of empty trace is empty" {
    const out = formatRawAddrs(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

// ─── symbolicateStack: DWARF symbolication ────────────────────────────

test "symbolicateStack returns null for an empty trace" {
    // writeStackTrace prints "(empty stack trace)" for zero frames —
    // the helper treats that as "no symbolication", not a section.
    const empty: std.debug.StackTrace = .{ .return_addresses = &.{}, .skipped = .none };
    try testing.expect(symbolicateStack(testing.allocator, &empty) == null);
}


// ─── Behavioural coverage (out-of-process) ────────────────────────────
// scripts/crash_handler_smoke.sh It compiles a tiny `crash_trigger.zig`
// helper into a standalone binary, invokes it (which dereferences a bad
