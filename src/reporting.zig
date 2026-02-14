const std = @import("std");
const ui = @import("ui.zig");

const color_reset = "\x1b[0m";
const color_title = "\x1b[1;36m";
const color_ok = "\x1b[1;32m";
const color_warn = "\x1b[1;33m";
const color_err = "\x1b[1;31m";
const color_dim = "\x1b[2m";

pub const RunSummary = struct {
    started_ns: i128 = 0,
    official_targets: usize = 0,
    aur_targets: usize = 0,
    aur_installed: usize = 0,
    aur_upgraded: usize = 0,
    failures: usize = 0,
    cache_hits: usize = 0,
    cache_misses: usize = 0,
};

pub const FailureInfo = struct {
    step: []const u8,
    package: []const u8,
    command: []const u8,
    hint: []const u8,
};

pub fn beginRun(summary: *RunSummary, failure: *?FailureInfo) void {
    summary.* = .{ .started_ns = std.time.nanoTimestamp() };
    failure.* = null;
}

pub fn phaseLine(json_output: bool, name: []const u8, idx: usize, total: usize) void {
    if (json_output) return;
    std.debug.print("{s}[phase {d}/{d}]{s} {s}\n", .{ color_title, idx, total, color_reset, name });
}

pub fn progressLine(json_output: bool, kind: []const u8, item: []const u8, idx: usize, total: usize) void {
    if (json_output) return;
    std.debug.print("{s}[{s} {d}/{d}]{s} {s}\n", .{ color_dim, kind, idx, total, color_reset, item });
}

pub fn setFailureContext(failure: *?FailureInfo, step: []const u8, package: []const u8, command: []const u8, hint: []const u8) void {
    failure.* = .{
        .step = step,
        .package = package,
        .command = command,
        .hint = hint,
    };
}

pub fn printFailureReport(json_output: bool, failure: ?FailureInfo, err: anyerror) void {
    if (json_output) {
        std.debug.print("{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
        return;
    }
    std.debug.print("\n{s}Failure report{s}\n", .{ color_err, color_reset });
    ui.rule();
    ui.kv("error", @errorName(err));
    if (failure) |f| {
        ui.kv("step", f.step);
        ui.kv("package", f.package);
        ui.kv("command", f.command);
        ui.kv("hint", f.hint);
    } else {
        ui.kv("hint", "Check logs above and rerun with --resume-failed if available");
    }
    ui.rule();
}

pub fn printSummaryCard(json_output: bool, summary: RunSummary) void {
    if (summary.started_ns == 0) return;
    const elapsed_ns = std.time.nanoTimestamp() - summary.started_ns;
    const elapsed_ms: i128 = @divFloor(elapsed_ns, std.time.ns_per_ms);
    if (json_output) {
        std.debug.print(
            "{{\"summary\":{{\"elapsed_ms\":{d},\"official_targets\":{d},\"aur_targets\":{d},\"aur_installed\":{d},\"aur_upgraded\":{d},\"failures\":{d},\"cache_hits\":{d},\"cache_misses\":{d}}}}}\n",
            .{
                elapsed_ms,
                summary.official_targets,
                summary.aur_targets,
                summary.aur_installed,
                summary.aur_upgraded,
                summary.failures,
                summary.cache_hits,
                summary.cache_misses,
            },
        );
        return;
    }
    std.debug.print("\n{s}Run summary{s}\n", .{ color_ok, color_reset });
    ui.rule();
    ui.kvInt("official targets", summary.official_targets);
    ui.kvInt("aur targets", summary.aur_targets);
    ui.kvInt("aur installed", summary.aur_installed);
    ui.kvInt("aur upgraded", summary.aur_upgraded);
    ui.kvInt("failures", summary.failures);
    ui.kvInt("cache hits", summary.cache_hits);
    ui.kvInt("cache misses", summary.cache_misses);
    std.debug.print("  {s: <14} : {d}\n", .{ "elapsed ms", elapsed_ms });
    if (summary.failures > 0) {
        std.debug.print("  {s: <14} : melon --resume-failed\n", .{"next"});
    }
    ui.rule();
}

pub fn printDryRunCommand(json_output: bool, prefix: []const u8, args: []const []const u8) void {
    if (json_output) return;
    std.debug.print("{s}[dry-run]{s} {s}", .{ color_warn, color_reset, prefix });
    for (args) |arg| {
        std.debug.print(" {s}", .{arg});
    }
    std.debug.print("\n", .{});
}

pub fn title(json_output: bool, msg: []const u8) void {
    if (json_output) return;
    ui.title(msg);
}

pub fn section(json_output: bool, msg: []const u8) void {
    if (json_output) return;
    ui.section(msg);
}

pub fn sectionFmt(json_output: bool, comptime fmt: []const u8, args: anytype) void {
    if (json_output) return;
    ui.sectionFmt(fmt, args);
}

pub fn rule(json_output: bool) void {
    if (json_output) return;
    ui.rule();
}

pub fn kv(json_output: bool, key: []const u8, value: []const u8) void {
    if (json_output) return;
    ui.kv(key, value);
}

pub fn kvInt(json_output: bool, key: []const u8, value: usize) void {
    if (json_output) return;
    ui.kvInt(key, value);
}

pub fn okLine(json_output: bool, msg: []const u8) void {
    if (json_output) return;
    ui.okLine(msg);
}

pub fn okLineFmt(json_output: bool, comptime fmt: []const u8, args: anytype) void {
    if (json_output) return;
    ui.okLineFmt(fmt, args);
}

pub fn warnLine(json_output: bool, msg: []const u8) void {
    if (json_output) return;
    ui.warnLine(msg);
}

pub fn warnLineFmt(json_output: bool, comptime fmt: []const u8, args: anytype) void {
    if (json_output) return;
    ui.warnLineFmt(fmt, args);
}

pub fn errLine(json_output: bool, msg: []const u8) void {
    if (json_output) return;
    ui.errLine(msg);
}

pub fn errLineFmt(json_output: bool, comptime fmt: []const u8, args: anytype) void {
    if (json_output) return;
    ui.errLineFmt(fmt, args);
}
