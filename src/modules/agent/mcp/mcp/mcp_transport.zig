const std = @import("std");

/// MCP Stdio Transport - reads from stdin, writes to stdout
pub const McpTransport = struct {
    allocator: std.mem.Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .stdin = std.Io.File.stdin(),
            .stdout = std.Io.File.stdout(),
        };
    }

    /// Read a JSON-RPC request from stdin Blocks until a complete message is received
    pub fn read_message(self: *Self) ![]u8 {
        var reader = self.stdin.reader();
        var header_end_pos: usize = 0;

        // Read headers until blank line
        var content_length: usize = 0;
        var buf: [4096]u8 = undefined;

        while (true) {
            const bytes_read = reader.read(&buf) catch |e| {
                if (e == error.EndOfStream) {
                    return error.EndOfStream;
                }
                return e;
            };
            if (bytes_read == 0) {
                return error.EndOfStream;
            }

            // Find header end
            const view = buf[0..bytes_read];
            if (std.mem.indexOf(u8, view, "\r\n\r\n")) |pos| {
                header_end_pos = pos + 4;
                // Parse Content-Length
                const header = view[0..pos];
                var lines = std.mem.splitScalar(u8, header, '\r');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "Content-Length:")) {
                        const val = std.mem.trim(u8, line[16..], " ");
                        content_length = try std.fmt.parseInt(usize, val, 10);
                    }
                }
                break;
            } else if (std.mem.indexOf(u8, view, "\n\n")) |pos| {
                header_end_pos = pos + 2;
                // Parse Content-Length
                const header = view[0..pos];
                var lines = std.mem.splitScalar(u8, header, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "Content-Length:")) {
                        const val = std.mem.trim(u8, line[16..], " ");
                        content_length = try std.fmt.parseInt(usize, val, 10);
                    }
                }
                break;
            }
        }

        if (content_length == 0) {
            return error.InvalidMessage;
        }

        // Read body
        const body_available = if (buf.len >= header_end_pos) buf.len - header_end_pos else 0;

        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);

        var body_offset: usize = 0;
        if (body_available > 0) {
            const to_copy = @min(body_available, content_length);
            @memcpy(body[0..to_copy], buf[header_end_pos .. header_end_pos + to_copy]);
            body_offset = to_copy;
        }

        while (body_offset < content_length) {
            const bytes_read = reader.read(body[body_offset..]) catch |e| {
                self.allocator.free(body);
                return e;
            };
            if (bytes_read == 0) {
                self.allocator.free(body);
                return error.EndOfStream;
            }
            body_offset += bytes_read;
        }

        return body;
    }

    /// Write a JSON-RPC response to stdout
    pub fn write_message(self: *Self, message: []const u8) !void {
        const writer = self.stdout.writer();
        try writer.print("Content-Length: {d}\r\n\r\n", .{message.len});
        try writer.writeAll(message);
    }
};

test {
    // Tests for mcp_transport would require mocking stdin/stdout Skipping for now - transport is tested via integration tests
}
