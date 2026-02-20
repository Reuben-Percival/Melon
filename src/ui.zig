const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ColorMode = enum {
    auto,
    always,
    never,
};

var color_enabled: bool = true;

pub fn init(mode: ColorMode) void {
    color_enabled = switch (mode) {
        .always => true,
        .never => false,
        .auto => blk: {
            // Check NO_COLOR
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR")) |val| {
                defer std.heap.page_allocator.free(val);
                break :blk false;
            } else |_| {}

            // Check if stderr is a terminal
            const is_terminal = std.posix.isatty(std.posix.STDERR_FILENO);
            break :blk is_terminal;
        },
    };
}

const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const underline = "\x1b[4m";

    const black = "\x1b[30m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const white = "\x1b[37m";

    const bright_black = "\x1b[90m";
    const bright_red = "\x1b[91m";
    const bright_green = "\x1b[92m";
    const bright_yellow = "\x1b[93m";
    const bright_blue = "\x1b[94m";
    const bright_magenta = "\x1b[95m";
    const bright_cyan = "\x1b[96m";
    const bright_white = "\x1b[97m";
};

fn color(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

pub fn title(msg: []const u8) void {
    std.debug.print("\n{s}==>{s} {s}{s}{s}\n", .{ color(C.bright_cyan), color(C.reset), color(C.bold), msg, color(C.reset) });
}

pub fn section(msg: []const u8) void {
    std.debug.print("{s}::{s} {s}\n", .{ color(C.bright_blue), color(C.reset), msg });
}

pub fn sectionFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}::{s} ", .{ color(C.bright_blue), color(C.reset) });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn rule() void {
    std.debug.print("{s}--------------------------------------------------------------------------------{s}\n", .{ color(C.dim), color(C.reset) });
}

pub fn kv(key: []const u8, value: []const u8) void {
    std.debug.print("  {s}{s: <16}{s} : {s}\n", .{ color(C.cyan), key, color(C.reset), value });
}

pub fn kvInt(key: []const u8, value: usize) void {
    std.debug.print("  {s}{s: <16}{s} : {d}\n", .{ color(C.cyan), key, color(C.reset), value });
}

pub fn okLine(msg: []const u8) void {
    std.debug.print("{s}[ok]{s} {s}\n", .{ color(C.bright_green), color(C.reset), msg });
}

pub fn okLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[ok]{s} ", .{ color(C.bright_green), color(C.reset) });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn warnLine(msg: []const u8) void {
    std.debug.print("{s}[warn]{s} {s}\n", .{ color(C.bright_yellow), color(C.reset), msg });
}

pub fn warnLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[warn]{s} ", .{ color(C.bright_yellow), color(C.reset) });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn errLine(msg: []const u8) void {
    std.debug.print("{s}[error]{s} {s}\n", .{ color(C.bright_red), color(C.reset), msg });
}

pub fn errLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[error]{s} ", .{ color(C.bright_red), color(C.reset) });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn printPackageHeader(repo: []const u8, name: []const u8, version: []const u8, idx: ?usize) void {
    if (idx) |i| {
        std.debug.print("{s}{d: >2}{s} ", .{ color(C.bright_magenta), i, color(C.reset) });
    }
    std.debug.print("{s}{s}/{s}{s} {s}{s}{s}\n", .{
        color(C.bright_blue),
        repo,
        color(C.bright_white),
        name,
        color(C.bright_green),
        version,
        color(C.reset),
    });
}

pub fn printDescription(desc: []const u8) void {
    if (desc.len > 0) {
        std.debug.print("    {s}{s}{s}\n", .{ color(C.dim), desc, color(C.reset) });
    }
}

pub fn highlightBash(allocator: Allocator, line: []const u8) ![]const u8 {
    if (!color_enabled) return try allocator.dupe(u8, line);

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];

        // Comments
        if (c == '#') {
            try result.appendSlice(allocator, C.dim);
            try result.appendSlice(allocator, line[i..]);
            try result.appendSlice(allocator, C.reset);
            break;
        }

        // Variables
        if (c == '$') {
            try result.appendSlice(allocator, C.bright_yellow);
            try result.append(allocator, c);
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '{' or line[i] == '}')) : (i += 1) {
                try result.append(allocator, line[i]);
            }
            try result.appendSlice(allocator, C.reset);
            continue;
        }

        // Keywords (very simple)
        if (std.ascii.isAlphabetic(c)) {
            const start = i;
            while (i < line.len and std.ascii.isAlphabetic(line[i])) : (i += 1) {}
            const word = line[start..i];

            if (isBashKeyword(word)) {
                try result.appendSlice(allocator, C.bright_magenta);
                try result.appendSlice(allocator, word);
                try result.appendSlice(allocator, C.reset);
            } else if (isPkgbuildVar(word)) {
                try result.appendSlice(allocator, C.bright_cyan);
                try result.appendSlice(allocator, word);
                try result.appendSlice(allocator, C.reset);
            } else {
                try result.appendSlice(allocator, word);
            }
            continue;
        }

        // Strings
        if (c == '"' or c == '\'') {
            const quote = c;
            try result.appendSlice(allocator, C.bright_green);
            try result.append(allocator, c);
            i += 1;
            while (i < line.len) : (i += 1) {
                try result.append(allocator, line[i]);
                if (line[i] == quote and (i == 0 or line[i - 1] != '\\')) {
                    i += 1;
                    break;
                }
            }
            try result.appendSlice(allocator, C.reset);
            continue;
        }

        try result.append(allocator, c);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn isBashKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "local", "export", "alias",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, word, k)) return true;
    }
    return false;
}

fn isPkgbuildVar(word: []const u8) bool {
    const vars = [_][]const u8{
        "pkgname", "pkgver", "pkgrel", "pkgdesc", "arch", "url", "license", "groups", "depends", "makedepends", "checkdepends", "optdepends", "provides", "conflicts", "replaces", "backup", "options", "install", "changelog", "source", "noextract", "validpgpkeys", "md5sums", "sha1sums", "sha224sums", "sha256sums", "sha384sums", "sha512sums", "b2sums",
    };
    for (vars) |v| {
        if (std.mem.eql(u8, word, v)) return true;
    }
    return false;
}

pub fn promptLine(allocator: Allocator, prompt: []const u8) ![]u8 {
    std.debug.print("{s}{s}{s}", .{ color(C.bold), prompt, color(C.reset) });
    var line_buf: [256]u8 = undefined;
    const line_opt = try readStdinLine(line_buf[0..]);
    const line = line_opt orelse return allocator.dupe(u8, "");
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn readStdinLine(buf: []u8) !?[]u8 {
    const stdin = std.fs.File.stdin();
    return stdin.deprecatedReader().readUntilDelimiterOrEof(buf, '\n') catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLong,
        else => return err,
    };
}
