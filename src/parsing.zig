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
    pgpfetch: bool = false,
    useask: bool = false,
    savechanges: bool = false,
    newsonupgrade: bool = false,
    combinedupgrade: bool = false,
    batchinstall: bool = false,
    provides: bool = false,
    devel: bool = false,
    installdebug: bool = false,
    sudoloop: bool = false,
    chroot: bool = false,
    failfast: bool = false,
    keepsrc: bool = false,
    sign: bool = false,
    signdb: bool = false,
    localrepo: bool = false,
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
        if (matchGlobalOption(arg, &config)) {
            continue;
        }
        kept += 1;
    }

    const filtered = try allocator.alloc([]const u8, kept);
    var idx: usize = 0;
    for (cli_args) |arg| {
        if (matchGlobalOption(arg, null)) {
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

fn matchGlobalOption(arg: []const u8, config: ?*RunConfig) bool {
    if (eql(arg, "--dry-run")) return setConfigBool(config, "dry_run", true);
    if (eql(arg, "--assume-reviewed")) return setConfigBool(config, "assume_reviewed", true);
    if (eql(arg, "--i-know-what-im-doing")) return setConfigBool(config, "i_know_what_im_doing", true);
    if (eql(arg, "--json")) return setConfigBool(config, "json", true);
    if (eql(arg, "--cache-clean")) return setConfigBool(config, "cache_clean", true);
    if (eql(arg, "--cache-info")) return setConfigBool(config, "cache_info", true);
    if (eql(arg, "--resume-failed")) return setConfigBool(config, "resume_failed", true);

    if (eql(arg, "--pgpfetch")) return setConfigBool(config, "pgpfetch", true);
    if (eql(arg, "--nopgpfetch")) return setConfigBool(config, "pgpfetch", false);
    if (eql(arg, "--useask")) return setConfigBool(config, "useask", true);
    if (eql(arg, "--nouseask")) return setConfigBool(config, "useask", false);
    if (eql(arg, "--savechanges")) return setConfigBool(config, "savechanges", true);
    if (eql(arg, "--nosavechanges")) return setConfigBool(config, "savechanges", false);
    if (eql(arg, "--newsonupgrade")) return setConfigBool(config, "newsonupgrade", true);
    if (eql(arg, "--nonewsonupgrade")) return setConfigBool(config, "newsonupgrade", false);
    if (eql(arg, "--combinedupgrade")) return setConfigBool(config, "combinedupgrade", true);
    if (eql(arg, "--nocombinedupgrade")) return setConfigBool(config, "combinedupgrade", false);
    if (eql(arg, "--batchinstall")) return setConfigBool(config, "batchinstall", true);
    if (eql(arg, "--nobatchinstall")) return setConfigBool(config, "batchinstall", false);
    if (eql(arg, "--provides")) return setConfigBool(config, "provides", true);
    if (eql(arg, "--noprovides")) return setConfigBool(config, "provides", false);
    if (eql(arg, "--devel")) return setConfigBool(config, "devel", true);
    if (eql(arg, "--nodevel")) return setConfigBool(config, "devel", false);
    if (eql(arg, "--installdebug")) return setConfigBool(config, "installdebug", true);
    if (eql(arg, "--noinstalldebug")) return setConfigBool(config, "installdebug", false);
    if (eql(arg, "--sudoloop")) return setConfigBool(config, "sudoloop", true);
    if (eql(arg, "--nosudoloop")) return setConfigBool(config, "sudoloop", false);
    if (eql(arg, "--chroot")) return setConfigBool(config, "chroot", true);
    if (eql(arg, "--nochroot")) return setConfigBool(config, "chroot", false);
    if (eql(arg, "--failfast")) return setConfigBool(config, "failfast", true);
    if (eql(arg, "--nofailfast")) return setConfigBool(config, "failfast", false);
    if (eql(arg, "--keepsrc")) return setConfigBool(config, "keepsrc", true);
    if (eql(arg, "--nokeepsrc")) return setConfigBool(config, "keepsrc", false);
    if (eql(arg, "--sign")) return setConfigBool(config, "sign", true);
    if (eql(arg, "--nosign")) return setConfigBool(config, "sign", false);
    if (eql(arg, "--signdb")) return setConfigBool(config, "signdb", true);
    if (eql(arg, "--nosigndb")) return setConfigBool(config, "signdb", false);
    if (eql(arg, "--localrepo")) return setConfigBool(config, "localrepo", true);
    if (eql(arg, "--nolocalrepo")) return setConfigBool(config, "localrepo", false);

    return false;
}

fn setConfigBool(config: ?*RunConfig, comptime field: []const u8, value: bool) bool {
    if (config) |cfg| @field(cfg, field) = value;
    return true;
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

test "parseCliArgs recognizes and strips toggle flags" {
    const allocator = std.testing.allocator;
    const input = [_][]const u8{
        "--pgpfetch",
        "--nouseask",
        "--savechanges",
        "--nonewsonupgrade",
        "--combinedupgrade",
        "--nobatchinstall",
        "--provides",
        "--nodevel",
        "--installdebug",
        "--nosudoloop",
        "--chroot",
        "--nofailfast",
        "--keepsrc",
        "--nosign",
        "--signdb",
        "--nolocalrepo",
        "-Syu",
    };

    const parsed = try parseCliArgs(allocator, &input);
    defer allocator.free(parsed.args);

    try std.testing.expectEqual(@as(usize, 1), parsed.args.len);
    try std.testing.expectEqualStrings("-Syu", parsed.args[0]);
    try std.testing.expect(parsed.config.pgpfetch);
    try std.testing.expect(!parsed.config.useask);
    try std.testing.expect(parsed.config.savechanges);
    try std.testing.expect(!parsed.config.newsonupgrade);
    try std.testing.expect(parsed.config.combinedupgrade);
    try std.testing.expect(!parsed.config.batchinstall);
    try std.testing.expect(parsed.config.provides);
    try std.testing.expect(!parsed.config.devel);
    try std.testing.expect(parsed.config.installdebug);
    try std.testing.expect(!parsed.config.sudoloop);
    try std.testing.expect(parsed.config.chroot);
    try std.testing.expect(!parsed.config.failfast);
    try std.testing.expect(parsed.config.keepsrc);
    try std.testing.expect(!parsed.config.sign);
    try std.testing.expect(parsed.config.signdb);
    try std.testing.expect(!parsed.config.localrepo);
}
