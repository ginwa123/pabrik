const std = @import("std");

pub const Reason = enum {
    forced,
    no_local_server,

    pub fn note(self: Reason) []const u8 {
        return switch (self) {
            .forced => "",
            .no_local_server => "No Pabrik server was found on this machine. Enter the address of the one you want to use.",
        };
    }
};

pub const Choice = union(enum) {
    connect: []const u8,
    picker: Reason,
    local,
};

pub fn decide(flag_url: ?[]const u8, saved_url: ?[]const u8, choose_server: bool) Choice {
    if (choose_server) return .{ .picker = .forced };
    if (flag_url) |url| return .{ .connect = url };
    if (saved_url) |url| return .{ .connect = url };
    return .local;
}

const testing = std.testing;

test "a desktop with no saved server still opens the local one" {
    try testing.expectEqual(Choice.local, decide(null, null, false));
}

test "a saved server is used on the next launch" {
    const choice = decide(null, "https://pabrik.example.com", false);
    try testing.expectEqualStrings("https://pabrik.example.com", choice.connect);
}

test "the --pabrik-url flag wins over the saved server" {
    const choice = decide("http://127.0.0.1:8080", "https://pabrik.example.com", false);
    try testing.expectEqualStrings("http://127.0.0.1:8080", choice.connect);
}

test "--choose-server opens the picker even when a server is saved" {
    try testing.expectEqual(Reason.forced, decide(null, "https://pabrik.example.com", true).picker);
}

test "--choose-server wins over --pabrik-url" {
    try testing.expectEqual(Reason.forced, decide("http://127.0.0.1:8080", null, true).picker);
}
