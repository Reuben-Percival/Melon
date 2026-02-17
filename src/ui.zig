const std = @import("std");

const Allocator = std.mem.Allocator;

const color_reset = "\x1b[0m";
const color_title = "\x1b[1;36m";
const color_ok = "\x1b[1;32m";
const color_warn = "\x1b[1;33m";
const color_err = "\x1b[1;31m";
const color_dim = "\x1b[2m";

pub fn title(msg: []const u8) void {
    std.debug.print("\n{s}==> {s}{s}\n", .{ color_title, msg, color_reset });
}

pub fn section(msg: []const u8) void {
    std.debug.print("{s}:: {s}{s}\n", .{ color_dim, msg, color_reset });
}

pub fn sectionFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}:: ", .{color_dim});
    std.debug.print(fmt, args);
    std.debug.print("{s}\n", .{color_reset});
}

pub fn rule() void {
    std.debug.print("{s}----------------------------------------{s}\n", .{ color_dim, color_reset });
}

pub fn kv(key: []const u8, value: []const u8) void {
    std.debug.print("  {s: <14} : {s}\n", .{ key, value });
}

pub fn kvInt(key: []const u8, value: usize) void {
    std.debug.print("  {s: <14} : {d}\n", .{ key, value });
}

pub fn okLine(msg: []const u8) void {
    std.debug.print("{s}[ok]{s} {s}\n", .{ color_ok, color_reset, msg });
}

pub fn okLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[ok]{s} ", .{ color_ok, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn warnLine(msg: []const u8) void {
    std.debug.print("{s}[warn]{s} {s}\n", .{ color_warn, color_reset, msg });
}

pub fn warnLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[warn]{s} ", .{ color_warn, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn errLine(msg: []const u8) void {
    std.debug.print("{s}[error]{s} {s}\n", .{ color_err, color_reset, msg });
}

pub fn errLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[error]{s} ", .{ color_err, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn promptLine(allocator: Allocator, prompt: []const u8) ![]u8 {
    std.debug.print("{s}", .{prompt});
    var line_buf: [256]u8 = undefined;
    const line_opt = try readStdinLine(line_buf[0..]);
    const line = line_opt orelse return allocator.dupe(u8, "");
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn readStdinLine(buf: []u8) !?[]u8 {
    if (@hasDecl(std.fs.File, "stdin")) {
        const stdin_file = std.fs.File.stdin();
        if (@hasDecl(@TypeOf(stdin_file), "reader")) {
            return stdin_file.reader().readUntilDelimiterOrEof(buf, '\n');
        }
        if (@hasDecl(@TypeOf(stdin_file), "deprecatedReader")) {
            return stdin_file.deprecatedReader().readUntilDelimiterOrEof(buf, '\n');
        }
    }
    if (@hasDecl(std, "io")) {
        if (@hasDecl(std.io, "getStdIn")) {
            const stdin_file = std.io.getStdIn();
            if (@hasDecl(@TypeOf(stdin_file), "reader")) {
                return stdin_file.reader().readUntilDelimiterOrEof(buf, '\n');
            }
            if (@hasDecl(@TypeOf(stdin_file), "deprecatedReader")) {
                return stdin_file.deprecatedReader().readUntilDelimiterOrEof(buf, '\n');
            }
        }
    }
    if (@hasDecl(std, "Io")) {
        if (@hasDecl(std.Io, "getStdIn")) {
            const stdin_file = std.Io.getStdIn();
            if (@hasDecl(@TypeOf(stdin_file), "reader")) {
                return stdin_file.reader().readUntilDelimiterOrEof(buf, '\n');
            }
            if (@hasDecl(@TypeOf(stdin_file), "deprecatedReader")) {
                return stdin_file.deprecatedReader().readUntilDelimiterOrEof(buf, '\n');
            }
        }
    }
    return error.UnsupportedStdin;
}
