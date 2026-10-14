//! Hand-declared Lua 5.4 C API bindings (no `@cImport`).

const std = @import("std");

pub const LuaState = opaque {};

pub extern fn luaL_newstate() callconv(.c) ?*LuaState;
pub extern fn luaL_openlibs(L: ?*LuaState) callconv(.c) void;
pub extern fn lua_close(L: ?*LuaState) callconv(.c) void;
pub extern fn luaL_loadstring(L: ?*LuaState, s: [*:0]const u8) callconv(.c) c_int;
pub extern fn luaL_loadfilex(L: ?*LuaState, filename: [*:0]const u8, mode: ?[*:0]const u8) callconv(.c) c_int;
pub extern fn lua_pcallk(L: ?*LuaState, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) callconv(.c) c_int;
pub extern fn lua_getglobal(L: ?*LuaState, name: [*:0]const u8) callconv(.c) c_int;
pub extern fn lua_getfield(L: ?*LuaState, idx: c_int, k: [*:0]const u8) callconv(.c) c_int;
pub extern fn lua_tolstring(L: ?*LuaState, idx: c_int, len: ?*usize) callconv(.c) ?[*:0]const u8;
pub extern fn lua_tonumberx(L: ?*LuaState, idx: c_int, isnum: ?*c_int) callconv(.c) f64;
pub extern fn lua_pushstring(L: ?*LuaState, s: [*:0]const u8) callconv(.c) ?[*:0]const u8;
pub extern fn lua_pushlstring(L: ?*LuaState, s: [*]const u8, len: usize) callconv(.c) ?[*:0]const u8;
pub extern fn lua_createtable(L: ?*LuaState, narr: c_int, nrec: c_int) callconv(.c) void;
pub extern fn lua_setfield(L: ?*LuaState, idx: c_int, k: [*:0]const u8) callconv(.c) void;
pub extern fn lua_settop(L: ?*LuaState, idx: c_int) callconv(.c) void;
pub extern fn lua_type(L: ?*LuaState, idx: c_int) callconv(.c) c_int;
pub extern fn lua_gettop(L: ?*LuaState) callconv(.c) c_int;
pub extern fn lua_toboolean(L: ?*LuaState, idx: c_int) callconv(.c) c_int;

pub const LUA_OK: c_int = 0;
pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
pub const LUA_TFUNCTION: c_int = 6;
pub const LUA_MULTRET: c_int = -1;

test "lua bindings round-trip: script sets global, Zig reads it back" {
    const L = luaL_newstate() orelse return error.HookNoState;
    defer lua_close(L);
    luaL_openlibs(L);

    const script: [*:0]const u8 = "test_marker = 1 + 1";
    try std.testing.expectEqual(LUA_OK, luaL_loadstring(L, script));
    try std.testing.expectEqual(LUA_OK, lua_pcallk(L, 0, 0, 0, 0, null));

    _ = lua_getglobal(L, "test_marker");
    defer lua_settop(L, 0);
    try std.testing.expectEqual(LUA_TNUMBER, lua_type(L, -1));
    try std.testing.expectEqual(@as(f64, 2), lua_tonumberx(L, -1, null));
}

test "lua bindings: pcall return value readable via tolstring" {

    const L = luaL_newstate() orelse return error.HookNoState;
    defer lua_close(L);
    luaL_openlibs(L);

    const script: [*:0]const u8 = "return 'hello-from-lua'";
    try std.testing.expectEqual(LUA_OK, luaL_loadstring(L, script));
    try std.testing.expectEqual(LUA_OK, lua_pcallk(L, 0, 1, 0, 0, null));
    defer lua_settop(L, 0);
    try std.testing.expectEqual(LUA_TSTRING, lua_type(L, -1));
    var len: usize = 0;
    const ptr = lua_tolstring(L, -1, &len) orelse return error.HookNullString;
    try std.testing.expectEqualStrings("hello-from-lua", ptr[0..len]);
}
