const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn runStreaming(allocator: Allocator, argv: []const []const u8) !u8 {
    return runStreamingCwd(allocator, null, argv);
}

pub fn runStreamingCwd(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !u8 {
    var proc = std.process.Child.init(argv, allocator);
    proc.stdin_behavior = .Inherit;
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;
    proc.cwd = cwd;

    try proc.spawn();
    const term = try proc.wait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

pub fn runStatus(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !u8 {
    var proc = std.process.Child.init(argv, allocator);
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;
    proc.cwd = cwd;

    try proc.spawn();
    const term = try proc.wait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

pub fn runCapture(allocator: Allocator, argv: []const []const u8) ![]u8 {
    return runCaptureCwd(allocator, null, argv);
}

pub fn runCaptureCwd(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
    var proc = std.process.Child.init(argv, allocator);
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Inherit;
    proc.cwd = cwd;

    try proc.spawn();
    const stdout = proc.stdout.?;
    const data = try stdout.readToEndAlloc(allocator, 16 * 1024 * 1024);
    const term = try proc.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return data;
}
