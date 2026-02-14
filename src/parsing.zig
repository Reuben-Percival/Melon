const std = @import("std");

const Allocator = std.mem.Allocator;

pub const RunConfig = struct {
    dry_run: bool = false,
    assume_reviewed: bool = false,
    i_know_what_im_doing: bool = false,
    json: bool = false,
    cache_clean: bool = false,
    cache_info: bool = false,
    resume_failed: bool = false,
};

pub const ParsedCli = struct {
    config: RunConfig,
    args: []const []const u8,
};

pub const SplitInstallArgs = struct {
    options: []const []const u8,
    targets: []const []const u8,
};

pub fn parseCliArgs(allocator: Allocator, cli_args: []const []const u8) !ParsedCli {
    var config = RunConfig{};
    var kept: usize = 0;
    for (cli_args) |arg| {
        if (eql(arg, "--dry-run")) {
            config.dry_run = true;
            continue;
        }
        if (eql(arg, "--assume-reviewed")) {
            config.assume_reviewed = true;
            continue;
        }
        if (eql(arg, "--i-know-what-im-doing")) {
            config.i_know_what_im_doing = true;
            continue;
        }
        if (eql(arg, "--json")) {
            config.json = true;
            continue;
        }
        if (eql(arg, "--cache-clean")) {
            config.cache_clean = true;
            continue;
        }
        if (eql(arg, "--cache-info")) {
            config.cache_info = true;
            continue;
        }
        if (eql(arg, "--resume-failed")) {
            config.resume_failed = true;
            continue;
        }
        kept += 1;
    }

    const filtered = try allocator.alloc([]const u8, kept);
    var idx: usize = 0;
    for (cli_args) |arg| {
        if (eql(arg, "--dry-run") or
            eql(arg, "--assume-reviewed") or
            eql(arg, "--i-know-what-im-doing") or
            eql(arg, "--json") or
            eql(arg, "--cache-clean") or
            eql(arg, "--cache-info") or
            eql(arg, "--resume-failed"))
        {
            continue;
        }
        filtered[idx] = arg;
        idx += 1;
    }

    return .{
        .config = config,
        .args = filtered,
    };
}

pub fn splitInstallArgs(allocator: Allocator, raw_args: []const []const u8) !SplitInstallArgs {
    var opt_count: usize = 0;
    var target_count: usize = 0;
    var parsing_options = true;
    for (raw_args) |arg| {
        if (parsing_options and eql(arg, "--")) {
            parsing_options = false;
            continue;
        }
        if (parsing_options and arg.len > 0 and arg[0] == '-') {
            opt_count += 1;
        } else {
            target_count += 1;
        }
    }

    const options = try allocator.alloc([]const u8, opt_count);
    const targets = try allocator.alloc([]const u8, target_count);

    var oi: usize = 0;
    var ti: usize = 0;
    parsing_options = true;
    for (raw_args) |arg| {
        if (parsing_options and eql(arg, "--")) {
            parsing_options = false;
            continue;
        }
        if (parsing_options and arg.len > 0 and arg[0] == '-') {
            options[oi] = arg;
            oi += 1;
        } else {
            targets[ti] = arg;
            ti += 1;
        }
    }
    return .{ .options = options, .targets = targets };
}

pub fn dependencyBaseName(raw_dep: []const u8) []const u8 {
    var dep = std.mem.trim(u8, raw_dep, " \t");
    if (dep.len == 0) return "";
    if (dep[0] == '!') return "";
    if (std.mem.lastIndexOfScalar(u8, dep, '/')) |i| dep = dep[i + 1 ..];
    if (std.mem.indexOfScalar(u8, dep, ':')) |i| dep = dep[0..i];

    var cut = dep.len;
    var i: usize = 0;
    while (i < dep.len) : (i += 1) {
        const c = dep[i];
        if (c == '<' or c == '>' or c == '=' or c == ':') {
            cut = i;
            break;
        }
    }
    return std.mem.trim(u8, dep[0..cut], " \t");
}

pub fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

pub fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (eql(arg, needle)) return true;
    }
    return false;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out = try allocator.alloc(u8, input.len * 3);
    errdefer allocator.free(out);

    var idx: usize = 0;
    for (input) |c| {
        if (isUnreserved(c)) {
            out[idx] = c;
            idx += 1;
        } else {
            out[idx] = '%';
            out[idx + 1] = hex[c >> 4];
            out[idx + 2] = hex[c & 0x0f];
            idx += 3;
        }
    }
    return try allocator.realloc(out, idx);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}
