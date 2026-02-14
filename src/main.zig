const std = @import("std");
const parsing = @import("parsing.zig");
const process = @import("process.zig");
const ui = @import("ui.zig");
const reporting = @import("reporting.zig");

const Allocator = std.mem.Allocator;
const RunConfig = parsing.RunConfig;
const ParsedCli = parsing.ParsedCli;
const SplitInstallArgs = parsing.SplitInstallArgs;
const RunSummary = reporting.RunSummary;
const FailureInfo = reporting.FailureInfo;
const parseCliArgs = parsing.parseCliArgs;
const splitInstallArgs = parsing.splitInstallArgs;
const dependencyBaseName = parsing.dependencyBaseName;
const startsWithAny = parsing.startsWithAny;
const containsArg = parsing.containsArg;
const eql = parsing.eql;
const urlEncode = parsing.urlEncode;

const runStreaming = process.runStreaming;
const runStreamingCwd = process.runStreamingCwd;
const runStatus = process.runStatus;
const runCapture = process.runCapture;
const runCaptureCwd = process.runCaptureCwd;

const melon_version = "0.3.0";

var color_reset: []const u8 = "\x1b[0m";
var color_title: []const u8 = "\x1b[1;36m";
var color_ok: []const u8 = "\x1b[1;32m";
var color_warn: []const u8 = "\x1b[1;33m";
var color_err: []const u8 = "\x1b[1;31m";
var color_dim: []const u8 = "\x1b[2m";
const aur_info_cache_ttl_secs: i64 = 10 * 60;
const default_prefetch_jobs: usize = 4;
const network_retry_max_attempts: usize = 3;
const network_retry_initial_delay_ms: u64 = 250;
const sudoloop_interval_ns: u64 = 5 * 60 * std.time.ns_per_s;

var g_json_output: bool = false;
var g_run_summary = RunSummary{};
var g_failure: ?FailureInfo = null;
var g_sudoloop_running: bool = false;

const InstallContext = struct {
    allocator: Allocator,
    config: RunConfig,
    installed_aur: std.StringHashMap(void),
    visiting_aur: std.StringHashMap(void),
    reviewed_aur: std.StringHashMap(void),
    aur_info_cache: std.StringHashMap([]u8),
    aur_pkgbuild_diffs: std.StringHashMap([]u8),
    pending_pkg_paths: std.ArrayListUnmanaged([]u8),
    local_repo_dir: ?[]u8,
    skip_remaining_reviews: bool,

    fn init(allocator: Allocator, config: RunConfig) InstallContext {
        return .{
            .allocator = allocator,
            .config = config,
            .installed_aur = std.StringHashMap(void).init(allocator),
            .visiting_aur = std.StringHashMap(void).init(allocator),
            .reviewed_aur = std.StringHashMap(void).init(allocator),
            .aur_info_cache = std.StringHashMap([]u8).init(allocator),
            .aur_pkgbuild_diffs = std.StringHashMap([]u8).init(allocator),
            .pending_pkg_paths = .{},
            .local_repo_dir = null,
            .skip_remaining_reviews = false,
        };
    }

    fn deinit(self: *InstallContext) void {
        freeStringSetKeys(self.allocator, &self.installed_aur);
        freeStringSetKeys(self.allocator, &self.visiting_aur);
        freeStringSetKeys(self.allocator, &self.reviewed_aur);
        freeStringToOwnedSliceMap(self.allocator, &self.aur_info_cache);
        freeStringToOwnedSliceMap(self.allocator, &self.aur_pkgbuild_diffs);
        for (self.pending_pkg_paths.items) |path| self.allocator.free(path);
        self.pending_pkg_paths.deinit(self.allocator);
        if (self.local_repo_dir) |p| self.allocator.free(p);
        self.installed_aur.deinit();
        self.visiting_aur.deinit();
        self.reviewed_aur.deinit();
        self.aur_info_cache.deinit();
        self.aur_pkgbuild_diffs.deinit();
    }
};

fn beginRun() void {
    reporting.beginRun(&g_run_summary, &g_failure);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = try parseCliArgs(allocator, args[1..]);
    defer allocator.free(parsed.args);
    g_json_output = parsed.config.json;

    // Color mode detection: NO_COLOR env, --color flag, pipe detection
    initColorMode(allocator, parsed.config);

    // --version
    if (parsed.config.version) {
        std.debug.print("melon {s}\n", .{melon_version});
        return;
    }

    if (parsed.config.cache_info) {
        cacheInfo(allocator, parsed.config) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }
    if (parsed.config.cache_clean) {
        cacheClean(allocator, parsed.config) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }
    if (parsed.config.resume_failed) {
        beginRun();
        startSudoLoop(allocator, parsed.config);
        resumeFailed(allocator, parsed.config) catch |err| {
            g_run_summary.failures += 1;
            printFailureReport(err);
            printSummaryCard();
            return err;
        };
        printSummaryCard();
        return;
    }

    if (parsed.args.len == 0 or eql(parsed.args[0], "-h") or eql(parsed.args[0], "--help")) {
        printUsage();
        return;
    }
    if (parsed.config.assume_reviewed and
        !parsed.config.i_know_what_im_doing and
        !stdinIsTty())
    {
        return usageErr("non-interactive --assume-reviewed requires --i-know-what-im-doing");
    }

    const cmd = parsed.args[0];

    // -Ss: search
    if (eql(cmd, "-Ss")) {
        if (parsed.args.len < 2) return usageErr("missing search query");
        searchPackages(allocator, parsed.config, parsed.args[1]) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -Qs: local search
    if (eql(cmd, "-Qs")) {
        if (parsed.args.len < 2) return usageErr("missing search query");
        try pacmanPassthrough(allocator, parsed.config, parsed.args);
        return;
    }

    // -Si: info
    if (eql(cmd, "-Si")) {
        if (parsed.args.len < 2) return usageErr("missing package name");
        infoPackage(allocator, parsed.args[1]) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -G: clone AUR repo
    if (eql(cmd, "-G")) {
        if (parsed.args.len < 2) return usageErr("missing package name");
        for (parsed.args[1..]) |pkg| {
            cloneAurRepo(allocator, pkg) catch |err| {
                printFailureReport(err);
                if (parsed.config.failfast) return err;
                continue;
            };
        }
        return;
    }

    // -Sc: clean pacman cache + melon aur-info cache
    if (eql(cmd, "-Sc")) {
        cleanCacheLight(allocator, parsed.config) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -Scc: deep cache clean (pacman + all melon cache)
    if (eql(cmd, "-Scc")) {
        cleanCacheDeep(allocator, parsed.config) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -S: install
    if (eql(cmd, "-S")) {
        if (parsed.args.len < 2) return usageErr("missing package name(s)");
        beginRun();
        startSudoLoop(allocator, parsed.config);
        installWithCompatibility(allocator, parsed.config, parsed.args[1..]) catch |err| {
            g_run_summary.failures += 1;
            printFailureReport(err);
            printSummaryCard();
            return err;
        };
        printSummaryCard();
        return;
    }

    // -Syu: full upgrade
    if (eql(cmd, "-Syu")) {
        beginRun();
        startSudoLoop(allocator, parsed.config);
        systemUpgrade(allocator, parsed.config) catch |err| {
            g_run_summary.failures += 1;
            printFailureReport(err);
            printSummaryCard();
            return err;
        };
        printSummaryCard();
        return;
    }

    // -Sua: AUR-only upgrade
    if (eql(cmd, "-Sua")) {
        beginRun();
        startSudoLoop(allocator, parsed.config);
        aurUpgrade(allocator, parsed.config) catch |err| {
            g_run_summary.failures += 1;
            printFailureReport(err);
            printSummaryCard();
            return err;
        };
        printSummaryCard();
        return;
    }

    // -Qu: check for updates (repo + AUR)
    if (eql(cmd, "-Qu")) {
        checkUpdates(allocator, parsed.config, false) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -Qua: check for AUR updates only
    if (eql(cmd, "-Qua")) {
        checkUpdates(allocator, parsed.config, true) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // -Qm: list foreign packages
    if (eql(cmd, "-Qm")) {
        foreignPackages(allocator) catch |err| {
            printFailureReport(err);
            return err;
        };
        return;
    }

    // Passthrough anything else that starts with -
    if (parsed.args[0].len > 0 and parsed.args[0][0] == '-') {
        try pacmanPassthrough(allocator, parsed.config, parsed.args);
        return;
    }

    return usageErr("unknown command (tip: pacman-like flags are passed through)");
}

fn initColorMode(allocator: Allocator, config: RunConfig) void {
    const should_disable = blk: {
        // Explicit --color=never
        if (config.color_mode == .never) break :blk true;
        // Explicit --color=always means force color
        if (config.color_mode == .always) break :blk false;
        // NO_COLOR env
        const no_color = std.process.getEnvVarOwned(allocator, "NO_COLOR") catch null;
        if (no_color) |v| {
            allocator.free(v);
            break :blk true;
        }
        // Auto: disable if stderr is not a TTY
        if (!stderrIsTty()) break :blk true;
        break :blk false;
    };
    if (should_disable) {
        color_reset = "";
        color_title = "";
        color_ok = "";
        color_warn = "";
        color_err = "";
        color_dim = "";
    }
}

fn stderrIsTty() bool {
    if (@hasDecl(std.fs.File, "stderr")) return std.fs.File.stderr().isTty();
    if (@hasDecl(std, "io")) {
        if (@hasDecl(std.io, "getStdErr")) return std.io.getStdErr().isTty();
    }
    if (@hasDecl(std, "Io")) {
        if (@hasDecl(std.Io, "getStdErr")) return std.Io.getStdErr().isTty();
    }
    return true;
}

fn startSudoLoop(allocator: Allocator, config: RunConfig) void {
    if (!config.sudoloop or g_sudoloop_running) return;
    g_sudoloop_running = true;
    // Initial sudo auth
    _ = runStreaming(allocator, &.{ "sudo", "-v" }) catch {};
    // Spawn background thread to keep sudo alive
    _ = std.Thread.spawn(.{}, sudoLoopThread, .{allocator}) catch {};
}

fn sudoLoopThread(allocator: Allocator) void {
    while (g_sudoloop_running) {
        sleepNs(sudoloop_interval_ns);
        _ = runStatus(allocator, null, &.{ "sudo", "-vn" }) catch {};
    }
}

fn printUsage() void {
    title("melon");
    std.debug.print("  v{s}\n", .{melon_version});
    std.debug.print(
        \\  AUR helper in Zig
        \\
        \\  Commands
        \\    melon -Ss <query>        Search repos + AUR (interactive selection)
        \\    melon -Qs <query>        Search locally installed packages
        \\    melon -Si <package>      Show package info
        \\    melon -S <pkg...>        Install packages (repo first, AUR fallback)
        \\    melon -Syu               Full upgrade: pacman sync + AUR updates
        \\    melon -Sua               Upgrade only installed AUR packages
        \\    melon -Qu                Check for updates (repo + AUR)
        \\    melon -Qua               Check for AUR updates only
        \\    melon -Qm                List foreign (AUR/manual) packages
        \\    melon -G <pkg...>        Clone AUR package repo(s) to current dir
        \\    melon -Sc                Clean pacman cache + melon info cache
        \\    melon -Scc               Deep clean all caches
        \\    melon <pacman flags...>  Passthrough to pacman for other operations
        \\
        \\  Melon Options
        \\    --version                Show version
        \\    --dry-run                Print mutating actions without executing them
        \\    --json                   Output machine-readable summaries where available
        \\    --color=auto|always|never
        \\                             Control color output (default: auto)
        \\    --assume-reviewed        Skip AUR review prompts for this run
        \\    --i-know-what-im-doing   Required with --assume-reviewed in non-interactive runs
        \\    --cache-info             Show melon cache size/details
        \\    --cache-clean            Remove melon cache data
        \\    --resume-failed          Retry last failed package set
        \\    --bottomup / --topdown   Sort AUR search results (default: topdown)
        \\    --[no]pgpfetch           Prompt to import PGP keys from PKGBUILDs
        \\    --[no]useask             Automatically resolve conflicts using pacman's ask flag
        \\    --[no]savechanges        Commit changes to PKGBUILDs made during review
        \\    --[no]newsonupgrade      Print new news during sysupgrade
        \\    --[no]combinedupgrade    Refresh then perform repo and AUR upgrade together
        \\    --[no]batchinstall       Build multiple AUR packages then install together
        \\    --[no]provides           Look for matching providers when searching packages
        \\    --[no]devel              Check development packages during sysupgrade
        \\    --[no]installdebug       Also install debug packages when available
        \\    --[no]sudoloop           Loop sudo calls in the background to avoid timeout
        \\    --[no]chroot             Build packages in a chroot
        \\    --[no]failfast           Exit as soon as building an AUR package fails
        \\    --[no]keepsrc            Keep src/ and pkg/ dirs after building packages
        \\    --[no]sign               Sign packages with gpg
        \\    --[no]signdb             Sign databases with gpg
        \\    --[no]localrepo          Build packages into a local repo
        \\    --rebuild                Force matching targets to be rebuilt
        \\    melon -h | --help        Show help
        \\
    , .{});
}

fn usageErr(msg: []const u8) !void {
    errLine(msg);
    printUsage();
    return error.InvalidArguments;
}

fn installWithCompatibility(allocator: Allocator, config: RunConfig, raw_args: []const []const u8) !void {
    try clearFailedPackages(allocator);
    phaseLine("classify targets", 1, 4);
    const split = try splitInstallArgs(allocator, raw_args);
    defer allocator.free(split.options);
    defer allocator.free(split.targets);

    if (split.targets.len == 0) {
        section("pacman -S passthrough (no explicit targets)");
        var pac_args = try allocator.alloc([]const u8, 1 + split.options.len);
        defer allocator.free(pac_args);
        pac_args[0] = "-S";
        @memcpy(pac_args[1..], split.options);
        const rc = try runPacmanSudoMaybe(allocator, config, pac_args);
        if (rc != 0) return error.PacmanInstallFailed;
        return;
    }

    var classifications = try allocator.alloc(bool, split.targets.len);
    defer allocator.free(classifications);

    var official_count: usize = 0;
    var aur_count: usize = 0;
    for (split.targets, 0..) |target, idx| {
        const is_official = try isOfficialPackage(allocator, target);
        classifications[idx] = is_official;
        if (is_official) official_count += 1 else aur_count += 1;
    }
    g_run_summary.official_targets += official_count;
    g_run_summary.aur_targets += aur_count;

    var official_targets = try allocator.alloc([]const u8, official_count);
    defer allocator.free(official_targets);
    var aur_targets = try allocator.alloc([]const u8, aur_count);
    defer allocator.free(aur_targets);

    var oi: usize = 0;
    var ai: usize = 0;
    for (split.targets, 0..) |target, idx| {
        if (classifications[idx]) {
            official_targets[oi] = target;
            oi += 1;
        } else {
            aur_targets[ai] = target;
            ai += 1;
        }
    }

    var fallback_official_to_aur = false;
    if (official_targets.len > 0) {
        phaseLine("install repo targets", 2, 4);
        section("install official targets");
        installOfficialTargets(allocator, config, split.options, official_targets) catch |err| {
            warnLineFmt("official repo install failed ({s}); attempting AUR fallback for requested targets", .{@errorName(err)});
            fallback_official_to_aur = true;
        };
    }

    if (aur_targets.len == 0 and !fallback_official_to_aur) return;
    if (fallback_official_to_aur) g_run_summary.aur_targets += official_targets.len;

    phaseLine("resolve/build AUR targets", 3, 4);
    section("install AUR targets");
    var ctx = InstallContext.init(allocator, config);
    defer ctx.deinit();
    for (aur_targets, 0..) |pkg, idx| {
        progressLine("aur target", pkg, idx + 1, aur_targets.len);
        warnLineFmt("using AUR for: {s}", .{pkg});
        installAurPackageRecursive(allocator, &ctx, pkg, !config.rebuild, false) catch |err| {
            recordFailedPackage(allocator, pkg) catch {};
            if (config.failfast) return err;
            g_run_summary.failures += 1;
            printFailureReport(err);
            continue;
        };
        okLineFmt("AUR install complete: {s}", .{pkg});
    }

    if (fallback_official_to_aur) {
        for (official_targets, 0..) |pkg, idx| {
            progressLine("aur fallback", pkg, idx + 1, official_targets.len);
            warnLineFmt("repo unavailable, trying AUR for: {s}", .{pkg});
            installAurPackageRecursive(allocator, &ctx, pkg, !config.rebuild, false) catch |err| {
                recordFailedPackage(allocator, pkg) catch {};
                if (config.failfast) return err;
                g_run_summary.failures += 1;
                printFailureReport(err);
                continue;
            };
            okLineFmt("AUR fallback install complete: {s}", .{pkg});
        }
    }
    try flushPendingBatchInstalls(allocator, &ctx);
    phaseLine("complete", 4, 4);

    if (config.json) {
        std.debug.print("{{\"command\":\"-S\",\"official_targets\":{d},\"aur_targets\":{d}}}\n", .{ official_targets.len, aur_targets.len });
    }
}

fn installOfficialTargets(allocator: Allocator, config: RunConfig, options: []const []const u8, targets: []const []const u8) !void {
    const need_needed = !containsArg(options, "--needed");
    const len = 1 + options.len + (if (need_needed) @as(usize, 1) else 0) + targets.len;
    var pac_args = try allocator.alloc([]const u8, len);
    defer allocator.free(pac_args);

    var i: usize = 0;
    pac_args[i] = "-S";
    i += 1;
    @memcpy(pac_args[i .. i + options.len], options);
    i += options.len;
    if (need_needed) {
        pac_args[i] = "--needed";
        i += 1;
    }
    @memcpy(pac_args[i .. i + targets.len], targets);

    const rc = try runPacmanSudoMaybe(allocator, config, pac_args);
    if (rc != 0) {
        setFailureContext("repo install", "pacman", "sudo pacman -S ...", "Check pacman output and rerun");
        return error.PacmanInstallFailed;
    }
    if (config.installdebug) try installDebugCompanions(allocator, config, targets);
}

fn searchPackages(allocator: Allocator, config: RunConfig, query: []const u8) !void {
    title("Search");
    kv("query", query);
    rule();
    section("official repositories");
    _ = runStreaming(allocator, &.{ "pacman", "-Ss", query }) catch |err| {
        warnLineFmt("pacman search failed: {s}", .{@errorName(err)});
        return;
    };

    section("AUR");
    const enc = try urlEncode(allocator, query);
    defer allocator.free(enc);

    const url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/rpc/v5/search/{s}", .{enc});
    defer allocator.free(url);

    const body = try fetchUrl(allocator, url);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const results = getArray(parsed.value, "results") orelse {
        warnLine("invalid AUR response");
        return;
    };

    if (results.items.len == 0) {
        warnLine("no AUR results");
        if (g_json_output) std.debug.print("{{\"command\":\"-Ss\",\"query\":\"{s}\",\"aur_results\":0}}\n", .{query});
        return;
    }

    // Collect results so we can optionally reverse (bottomup) and show names for selection
    const SearchResult = struct {
        name: []const u8,
        version: []const u8,
        desc: []const u8,
        votes: i64,
        popularity: f64,
        out_of_date: bool,
    };

    var result_list: std.ArrayListUnmanaged(SearchResult) = .{};
    defer result_list.deinit(allocator);

    for (results.items) |entry| {
        if (entry != .object) continue;
        const name = getString(entry, "Name") orelse "<unknown>";
        const version = getString(entry, "Version") orelse "<unknown>";
        const desc = getString(entry, "Description") orelse "";
        const votes: i64 = if (getInt(entry, "NumVotes")) |v| v else 0;
        const popularity: f64 = if (getFloat(entry, "Popularity")) |v| v else 0.0;
        const out_of_date = (getInt(entry, "OutOfDate") orelse 0) != 0;

        try result_list.append(allocator, .{
            .name = name,
            .version = version,
            .desc = desc,
            .votes = votes,
            .popularity = popularity,
            .out_of_date = out_of_date,
        });
    }

    if (result_list.items.len == 0) return;

    // Bottomup: reverse the display order so highest-numbered result is at top
    const items = result_list.items;
    const bottomup = config.bottomup;

    var shown: usize = 0;
    if (g_json_output) std.debug.print("{{\"command\":\"-Ss\",\"query\":\"{s}\",\"aur\":[", .{query});

    var display_idx: usize = 0;
    while (display_idx < items.len) : (display_idx += 1) {
        const idx = if (bottomup) items.len - 1 - display_idx else display_idx;
        const r = items[idx];
        shown += 1;
        const display_num = idx + 1;
        if (g_json_output) {
            if (shown > 1) std.debug.print(",", .{});
            std.debug.print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"votes\":{d},\"popularity\":{d:.2},\"out_of_date\":{}}}", .{ r.name, r.version, r.votes, r.popularity, r.out_of_date });
        } else {
            const ood = if (r.out_of_date) " [OutOfDate]" else "";
            std.debug.print("{s}[{d: >2}]{s} aur/{s} {s}", .{
                color_title, display_num, color_reset, r.name, r.version,
            });
            std.debug.print("{s}{s}{s} {s}(+{d} {d:.2}){s}\n", .{
                color_err, ood, color_reset,
                color_dim, r.votes, r.popularity, color_reset,
            });
            if (r.desc.len > 0) std.debug.print("     {s}{s}{s}\n", .{ color_dim, r.desc, color_reset });
        }
    }

    if (g_json_output) {
        std.debug.print("],\"aur_results\":{d}}}\n", .{shown});
    } else {
        rule();
        kvInt("aur results", shown);
    }

    if (!config.provides or g_json_output) return;
    section("AUR providers");
    const providers_url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/rpc/v5/search/{s}?by=provides", .{enc});
    defer allocator.free(providers_url);
    const providers_body = try fetchUrl(allocator, providers_url);
    defer allocator.free(providers_body);
    const providers_parsed = try std.json.parseFromSlice(std.json.Value, allocator, providers_body, .{});
    defer providers_parsed.deinit();
    const providers_results = getArray(providers_parsed.value, "results") orelse return;
    if (providers_results.items.len == 0) {
        warnLine("no provider matches");
        return;
    }
    for (providers_results.items) |entry| {
        if (entry != .object) continue;
        const name = getString(entry, "Name") orelse "<unknown>";
        const version = getString(entry, "Version") orelse "<unknown>";
        const desc = getString(entry, "Description") orelse "";
        std.debug.print("{s}provider{s} aur/{s} {s}\n", .{ color_title, color_reset, name, version });
        if (desc.len > 0) std.debug.print("  {s}{s}{s}\n", .{ color_dim, desc, color_reset });
    }

    // Interactive selection: prompt to install packages by number
    if (g_json_output or !stdinIsTty()) return;
    rule();
    std.debug.print("\n{s}Enter package numbers to install (e.g. 1 3 5), or press Enter to skip:{s}\n", .{ color_title, color_reset });
    const selection_raw = promptLine(allocator, ">> ") catch return;
    defer allocator.free(selection_raw);
    const trimmed_sel = std.mem.trim(u8, selection_raw, " \t\r\n");
    if (trimmed_sel.len == 0) return;

    // Parse space/comma separated numbers
    var to_install: std.ArrayListUnmanaged([]const u8) = .{};
    defer to_install.deinit(allocator);
    var tok = std.mem.tokenizeAny(u8, trimmed_sel, " ,\t");
    while (tok.next()) |num_str| {
        const num = std.fmt.parseInt(usize, num_str, 10) catch {
            warnLineFmt("ignoring invalid number: {s}", .{num_str});
            continue;
        };
        if (num < 1 or num > items.len) {
            warnLineFmt("ignoring out-of-range number: {d}", .{num});
            continue;
        }
        try to_install.append(allocator, items[num - 1].name);
    }
    if (to_install.items.len == 0) return;

    // Install selected packages
    section("installing selected packages");
    for (to_install.items) |pkg| {
        okLineFmt("queuing: {s}", .{pkg});
    }
    var ctx = InstallContext.init(allocator, config);
    defer ctx.deinit();
    for (to_install.items) |pkg| {
        installAurPackageRecursive(allocator, &ctx, pkg, true, false) catch |err| {
            warnLineFmt("failed to install {s}: {s}", .{ pkg, @errorName(err) });
            continue;
        };
        okLineFmt("installed: {s}", .{pkg});
    }
    try flushPendingBatchInstalls(allocator, &ctx);
}

fn infoPackage(allocator: Allocator, pkg: []const u8) !void {
    title("Info");
    const official_ok = blk: {
        const rc = runStreaming(allocator, &.{ "pacman", "-Si", pkg }) catch break :blk false;
        break :blk rc == 0;
    };
    if (official_ok) return;

    section("AUR fallback");
    const info = try fetchAurInfo(allocator, pkg);
    defer info.parsed.deinit();

    if (info.entry == null) {
        errLineFmt("package '{s}' not found in AUR", .{pkg});
        return error.NotFound;
    }
    const entry = info.entry.?;

    if (g_json_output) {
        std.debug.print(
            "{{\"command\":\"-Si\",\"repository\":\"aur\",\"name\":\"{s}\",\"version\":\"{s}\",\"description\":\"{s}\",\"url\":\"{s}\",\"maintainer\":\"{s}\"}}\n",
            .{
                getString(entry, "Name") orelse "<unknown>",
                getString(entry, "Version") orelse "<unknown>",
                getString(entry, "Description") orelse "",
                getString(entry, "URL") orelse "",
                getString(entry, "Maintainer") orelse "<orphan>",
            },
        );
        return;
    }

    rule();
    kv("Repository", "aur");
    kv("Name", getString(entry, "Name") orelse "<unknown>");
    kv("Version", getString(entry, "Version") orelse "<unknown>");
    kv("Description", getString(entry, "Description") orelse "");
    kv("URL", getString(entry, "URL") orelse "");
    kv("Maintainer", getString(entry, "Maintainer") orelse "<orphan>");
    rule();
}

fn systemUpgrade(allocator: Allocator, config: RunConfig) !void {
    title("Upgrade");
    try clearFailedPackages(allocator);
    if (config.newsonupgrade) try showArchNews(allocator);
    phaseLine("system sync", 1, 3);
    section("system packages");
    const sync_rc = try runPacmanSudoMaybe(allocator, config, &.{"-Syu"});
    if (sync_rc != 0) {
        recordFailedPackage(allocator, "__system_upgrade__") catch {};
        setFailureContext("system upgrade", "__system_upgrade__", "sudo pacman -Syu", "Resolve pacman sync issues, then rerun");
        if (config.combinedupgrade) return error.PacmanInstallFailed;
        warnLine("system repo upgrade failed; continuing with AUR upgrade best-effort mode");
        g_run_summary.failures += 1;
    } else {
        okLine("system packages are up to date");
    }

    section("AUR packages");
    phaseLine("AUR upgrade", 2, 3);
    try aurUpgrade(allocator, config);
    phaseLine("complete", 3, 3);
    if (config.json) {
        std.debug.print("{{\"command\":\"-Syu\",\"status\":\"ok\"}}\n", .{});
    }
}

fn aurUpgrade(allocator: Allocator, config: RunConfig) !void {
    title("AUR upgrade");
    try clearFailedPackages(allocator);
    phaseLine("prefetch AUR metadata", 1, 3);
    var ctx = InstallContext.init(allocator, config);
    defer ctx.deinit();
    var seen_bases = std.StringHashMap(void).init(allocator);
    defer {
        freeStringSetKeys(allocator, &seen_bases);
        seen_bases.deinit();
    }

    const aur_list = try listForeignPackageNames(allocator);
    defer freeNameList(allocator, aur_list);

    if (aur_list.len == 0) {
        warnLine("no foreign packages found");
        return;
    }
    try prefetchAurInfoInParallel(allocator, aur_list);

    phaseLine("scan upgrades", 2, 3);
    var upgraded: usize = 0;
    var scanned: usize = 0;
    for (aur_list, 0..) |pkg, idx| {
        progressLine("scan", pkg, idx + 1, aur_list.len);
        scanned += 1;
        const info = try fetchAurInfoCached(allocator, &ctx, pkg);
        defer info.parsed.deinit();
        if (info.entry == null) continue;
        const entry = info.entry.?;

        const latest = getString(entry, "Version") orelse continue;
        const base = getString(entry, "PackageBase") orelse getString(entry, "Name") orelse continue;

        const installed = try installedVersion(allocator, pkg);
        defer allocator.free(installed);

        const cmp = try vercmp(allocator, installed, latest);
        if (cmp < 0 or (config.devel and isDevelPackageName(pkg))) {
            if (seen_bases.contains(base)) continue;
            try seen_bases.put(try allocator.dupe(u8, base), {});

            sectionFmt("upgrade aur/{s}", .{base});
            kv("package", pkg);
            kv("current", installed);
            kv("latest", latest);
            installAurPackageRecursive(allocator, &ctx, base, false, false) catch |err| {
                recordFailedPackage(allocator, base) catch {};
                if (config.failfast) return err;
                g_run_summary.failures += 1;
                printFailureReport(err);
                continue;
            };
            upgraded += 1;
            g_run_summary.aur_upgraded += 1;
        }
    }
    try flushPendingBatchInstalls(allocator, &ctx);
    phaseLine("complete", 3, 3);

    if (config.json) {
        std.debug.print("{{\"command\":\"-Sua\",\"scanned\":{d},\"upgraded\":{d}}}\n", .{ scanned, upgraded });
    } else {
        rule();
        kvInt("scanned", scanned);
        kvInt("upgraded", upgraded);
    }
}

fn foreignPackages(allocator: Allocator) !void {
    title("Foreign packages (-Qm)");
    if (!g_json_output) {
        _ = try runStreaming(allocator, &.{ "pacman", "-Qm" });
        return;
    }
    const out = try runCapture(allocator, &.{ "pacman", "-Qm" });
    defer allocator.free(out);
    std.debug.print("{{\"command\":\"-Qm\",\"packages\":[", .{});
    var line_it = std.mem.splitScalar(u8, out, '\n');
    var first = true;
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = tok.next() orelse continue;
        const version = tok.next() orelse "";
        if (!first) std.debug.print(",", .{});
        first = false;
        std.debug.print("{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ name, version });
    }
    std.debug.print("]}}\n", .{});
}

fn checkUpdates(allocator: Allocator, config: RunConfig, aur_only: bool) !void {
    title(if (aur_only) "AUR update check (-Qua)" else "Update check (-Qu)");

    if (!aur_only) {
        section("official repositories");
        _ = runStreaming(allocator, &.{ "pacman", "-Qu" }) catch {};
    }

    section("AUR packages");
    const aur_list = try listForeignPackageNames(allocator);
    defer freeNameList(allocator, aur_list);

    if (aur_list.len == 0) {
        warnLine("no foreign packages found");
        return;
    }

    try prefetchAurInfoInParallel(allocator, aur_list);
    var ctx = InstallContext.init(allocator, config);
    defer ctx.deinit();

    var updates_available: usize = 0;
    if (g_json_output) std.debug.print("{{\"command\":\"{s}\",\"updates\":[", .{if (aur_only) "-Qua" else "-Qu"});

    for (aur_list, 0..) |pkg, idx| {
        progressLine("check", pkg, idx + 1, aur_list.len);
        const info = try fetchAurInfoCached(allocator, &ctx, pkg);
        defer info.parsed.deinit();
        if (info.entry == null) continue;
        const entry = info.entry.?;

        const latest = getString(entry, "Version") orelse continue;
        const installed = try installedVersion(allocator, pkg);
        defer allocator.free(installed);

        const cmp = try vercmp(allocator, installed, latest);
        if (cmp < 0 or (config.devel and isDevelPackageName(pkg))) {
            updates_available += 1;
            if (g_json_output) {
                if (updates_available > 1) std.debug.print(",", .{});
                std.debug.print("{{\"name\":\"{s}\",\"current\":\"{s}\",\"latest\":\"{s}\"}}", .{ pkg, installed, latest });
            } else {
                std.debug.print("{s}{s}{s} {s} -> {s}{s}{s}\n", .{
                    color_warn, pkg, color_reset,
                    installed,
                    color_ok,   latest, color_reset,
                });
            }
        }
    }

    if (g_json_output) {
        std.debug.print("],\"count\":{d}}}\n", .{updates_available});
    } else {
        rule();
        kvInt("updates available", updates_available);
    }
}

fn cloneAurRepo(allocator: Allocator, pkg: []const u8) !void {
    const repo_url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/{s}.git", .{pkg});
    defer allocator.free(repo_url);
    sectionFmt("cloning aur/{s}", .{pkg});
    const rc = try runStreamingRetry(allocator, &.{ "git", "clone", repo_url }, network_retry_max_attempts, network_retry_initial_delay_ms);
    if (rc != 0) {
        setFailureContext("clone", pkg, "git clone", "Check package name and network");
        return error.AurCloneFailed;
    }
    okLineFmt("cloned {s}", .{pkg});
}

fn cleanCacheLight(allocator: Allocator, config: RunConfig) !void {
    title("Clean cache (-Sc)");

    section("pacman cache");
    if (config.dry_run) {
        printDryRunCommand("sudo pacman", &.{"-Sc"});
    } else {
        _ = try runPacmanSudoMaybe(allocator, config, &.{"-Sc"});
    }

    section("melon info cache");
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const info_dir = try std.fmt.allocPrint(allocator, "{s}/aur-info", .{cache_root});
    defer allocator.free(info_dir);

    if (config.dry_run) {
        std.debug.print("{s}[dry-run]{s} rm -rf {s}\n", .{ color_warn, color_reset, info_dir });
    } else {
        std.fs.deleteTreeAbsolute(info_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    okLine("info cache cleaned");
}

fn cleanCacheDeep(allocator: Allocator, config: RunConfig) !void {
    title("Deep clean cache (-Scc)");

    section("pacman cache");
    if (config.dry_run) {
        printDryRunCommand("sudo pacman", &.{"-Scc"});
    } else {
        _ = try runPacmanSudoMaybe(allocator, config, &.{"-Scc"});
    }

    section("melon cache");
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);

    if (config.dry_run) {
        std.debug.print("{s}[dry-run]{s} rm -rf {s}\n", .{ color_warn, color_reset, cache_root });
    } else {
        std.fs.deleteTreeAbsolute(cache_root) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    okLine("all caches deep cleaned");
}

fn showOptionalDeps(allocator: Allocator, srcinfo: []const u8, pkg: []const u8) void {
    var has_optdeps = false;
    var it = std.mem.splitScalar(u8, srcinfo, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "optdepends = ")) continue;
        if (!has_optdeps) {
            has_optdeps = true;
            sectionFmt("optional dependencies for {s}", .{pkg});
        }
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const dep = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (dep.len == 0) continue;
        const base_dep = dependencyBaseName(dep);
        const installed = isDependencySatisfied(allocator, base_dep) catch false;
        if (installed) {
            std.debug.print("  {s}[installed]{s} {s}\n", .{ color_ok, color_reset, dep });
        } else {
            std.debug.print("  {s}[optional]{s}  {s}\n", .{ color_dim, color_reset, dep });
        }
    }
}

fn installAurPackageRecursive(allocator: Allocator, ctx: *InstallContext, pkg: []const u8, skip_if_installed: bool, is_dependency: bool) anyerror!void {
    if (skip_if_installed and (try isInstalledPackage(allocator, pkg))) return;

    const repo_base = (try resolveAurPackageBaseCached(allocator, ctx, pkg)) orelse {
        errLineFmt("package '{s}' not found in AUR", .{pkg});
        return error.NotFound;
    };
    defer allocator.free(repo_base);

    if (ctx.installed_aur.contains(repo_base)) return;
    if (ctx.visiting_aur.contains(repo_base)) {
        errLineFmt("dependency cycle detected at aur/{s}", .{repo_base});
        return error.DependencyCycle;

    }
    try ctx.visiting_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
    errdefer removeStringSetEntryAndFreeKey(ctx.allocator, &ctx.visiting_aur, repo_base);

    if (ctx.config.dry_run) {
        sectionFmt("dry-run: would build and install aur/{s}", .{repo_base});
        removeStringSetEntryAndFreeKey(ctx.allocator, &ctx.visiting_aur, repo_base);
        try ctx.installed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
        return;
    }

    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const repo_sync = try ensureAurRepoCacheSynced(allocator, cache_root, repo_base);
    defer allocator.free(repo_sync.repo_dir);
    defer if (repo_sync.reviewed_from) |c| allocator.free(c);
    if (repo_sync.pkgbuild_diff) |diff| {
        defer allocator.free(diff);
        if (ctx.aur_pkgbuild_diffs.fetchRemove(repo_base)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
        }
        try ctx.aur_pkgbuild_diffs.put(try allocator.dupe(u8, repo_base), try allocator.dupe(u8, diff));
    }

    const build_dir = try createSecureBuildDir(allocator, repo_base);
    defer allocator.free(build_dir);
    const keep_build_dir = ctx.config.keepsrc or ctx.config.savechanges;
    defer if (!keep_build_dir) std.fs.deleteTreeAbsolute(build_dir) catch {};
    try std.fs.makeDirAbsolute(build_dir);
    const repo_contents_path = try std.fmt.allocPrint(allocator, "{s}/.", .{repo_sync.repo_dir});
    defer allocator.free(repo_contents_path);
    const copy_rc = try runStreaming(allocator, &.{ "cp", "-a", repo_contents_path, build_dir });
    if (copy_rc != 0) {
        setFailureContext("aur checkout", repo_base, "cp -a <repo>/. <build_dir>", "Cache may be corrupted; try --cache-clean then rerun");
        return error.AurCloneFailed;
    }

    const srcinfo = try generateSrcinfo(allocator, ctx.config, build_dir, repo_base);
    defer allocator.free(srcinfo);

    try resolveAurDependencies(allocator, ctx, srcinfo);
    if (!g_json_output) showOptionalDeps(allocator, srcinfo, pkg);
    try reviewAurPackage(allocator, ctx, build_dir, pkg, repo_base, srcinfo, repo_sync.reviewed_from);
    if (ctx.config.savechanges) try savePkgbuildReviewChanges(allocator, build_dir, repo_base);

    if (ctx.config.pgpfetch) {
        const verify_rc = try runStreamingCwd(allocator, build_dir, &.{ "makepkg", "--verifysource" });
        if (verify_rc != 0) {
            setFailureContext("aur verify", repo_base, "makepkg --verifysource", "Import required keys and retry, or disable with --nopgpfetch");
            return error.MakepkgFailed;
        }
    }

    const use_noinstall = ctx.config.chroot or
        ((ctx.config.localrepo or ctx.config.batchinstall) and !is_dependency);
    const built_pkg_paths = try buildAurPackage(allocator, ctx.config, build_dir, repo_base, use_noinstall);
    defer freeNameList(allocator, built_pkg_paths);

    if (use_noinstall) {
        if (built_pkg_paths.len == 0) {
            setFailureContext("aur package discovery", repo_base, "find built package files", "Build produced no package artifacts");
            return error.MakepkgFailed;
        }
        if (ctx.config.localrepo) try addPackagesToLocalRepo(allocator, ctx, built_pkg_paths);
        if (ctx.config.batchinstall and !is_dependency) {
            for (built_pkg_paths) |pkg_path| {
                try ctx.pending_pkg_paths.append(allocator, try allocator.dupe(u8, pkg_path));
            }
        } else {
            try installBuiltPackages(allocator, ctx.config, built_pkg_paths);
        }
    }

    removeStringSetEntryAndFreeKey(ctx.allocator, &ctx.visiting_aur, repo_base);
    try ctx.installed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
    g_run_summary.aur_installed += 1;
    if (keep_build_dir) warnLineFmt("keeping build dir: {s}", .{build_dir});
}

fn resolveAurDependencies(allocator: Allocator, ctx: *InstallContext, srcinfo: []const u8) anyerror!void {
    var it = std.mem.splitScalar(u8, srcinfo, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!startsWithAny(trimmed, &.{ "depends = ", "makedepends = ", "checkdepends = " })) continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const raw = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        const dep = dependencyBaseName(raw);
        if (dep.len == 0) continue;
        try ensureDependencyInstalled(allocator, ctx, dep);
    }
}

fn ensureDependencyInstalled(allocator: Allocator, ctx: *InstallContext, dep: []const u8) anyerror!void {
    if (dep.len == 0) return;
    if (try isDependencySatisfied(allocator, dep)) return;

    if (try isOfficialPackage(allocator, dep)) {
        sectionFmt("install dependency from repos: {s}", .{dep});
        const rc = try runPacmanSudoMaybe(allocator, ctx.config, &.{ "-S", "--needed", dep });
        if (rc == 0) {
            if (ctx.config.installdebug) try installDebugCompanions(allocator, ctx.config, &.{dep});
            return;
        }
        warnLineFmt("repo dependency install failed for {s}; trying AUR fallback", .{dep});
    }

    const selected = (try selectAurProvider(allocator, dep)) orelse {
        errLineFmt("no provider found for dependency '{s}'", .{dep});
        return error.NotFound;
    };
    defer allocator.free(selected);

    sectionFmt("install dependency from AUR: {s} (providing {s})", .{ selected, dep });
    try installAurPackageRecursive(allocator, ctx, selected, true, true);
}

fn reviewAurPackage(allocator: Allocator, ctx: *InstallContext, build_dir: []const u8, pkg: []const u8, repo_base: []const u8, srcinfo: []const u8, reviewed_from: ?[]const u8) !void {
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    if (ctx.config.assume_reviewed) {
        try ctx.reviewed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
        const head = try gitHeadCommit(allocator, build_dir);
        defer if (head) |h| allocator.free(h);
        if (head) |h| try writeReviewedCommit(allocator, cache_root, repo_base, h);
        return;
    }
    if (ctx.skip_remaining_reviews) return;
    if (ctx.reviewed_aur.contains(repo_base)) return;

    try writeSrcinfoFile(allocator, build_dir, srcinfo);

    title("AUR review");
    kv("package", pkg);
    kv("repo", repo_base);
    kv("path", build_dir);
    if (reviewed_from) |commit| kv("reviewed from", commit);
    std.debug.print("\n", .{});
    std.debug.print("  1) View PKGBUILD\n", .{});
    std.debug.print("  2) View dependency summary\n", .{});
    std.debug.print("  3) View full .SRCINFO\n", .{});
    std.debug.print("  4) View PKGBUILD diff (if upgraded)\n", .{});
    std.debug.print("  5) Run PKGBUILD security check\n", .{});
    std.debug.print("  c) Continue build\n", .{});
    std.debug.print("  a) Continue and trust all for this run\n", .{});
    std.debug.print("  q) Abort\n", .{});

    var did_security_check = false;
    while (true) {
        const choice = try promptLine(allocator, "Choose [1/2/3/4/5/c/a/q]: ");
        defer allocator.free(choice);
        if (eql(choice, "1")) {
            try showFileForReview(allocator, build_dir, "PKGBUILD");
            continue;
        }
        if (eql(choice, "2")) {
            std.debug.print("\n", .{});
            try printDependencyLines(srcinfo);
            std.debug.print("\n", .{});
            continue;
        }
        if (eql(choice, "3")) {
            try showFileForReview(allocator, build_dir, ".SRCINFO");
            continue;
        }
        if (eql(choice, "4")) {
            if (ctx.aur_pkgbuild_diffs.get(repo_base)) |diff| {
                if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
                    warnLine("no PKGBUILD changes detected");
                } else {
                    std.debug.print("\n{s}PKGBUILD diff{s}\n", .{ color_title, color_reset });
                    rule();
                    std.debug.print("{s}\n", .{diff});
                    rule();
                }
            } else {
                warnLine("no previous PKGBUILD snapshot available");
            }
            continue;
        }
        if (eql(choice, "5")) {
            try runPkgbuildSecurityCheck(allocator, build_dir);
            did_security_check = true;
            continue;
        }
        if (eql(choice, "c")) {
            if (!did_security_check) {
                warnLine("run option 5 (security check) before continuing");
                continue;
            }
            try ctx.reviewed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
            const head = try gitHeadCommit(allocator, build_dir);
            defer if (head) |h| allocator.free(h);
            if (head) |h| try writeReviewedCommit(allocator, cache_root, repo_base, h);
            return;
        }
        if (eql(choice, "a")) {
            if (!did_security_check) {
                warnLine("run option 5 (security check) before continue-and-trust");
                continue;
            }
            ctx.skip_remaining_reviews = true;
            try ctx.reviewed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
            const head = try gitHeadCommit(allocator, build_dir);
            defer if (head) |h| allocator.free(h);
            if (head) |h| try writeReviewedCommit(allocator, cache_root, repo_base, h);
            return;
        }
        if (eql(choice, "q")) {
            return error.PkgbuildRejected;
        }
        warnLine("invalid choice");
    }
}

fn writeSrcinfoFile(allocator: Allocator, build_dir: []const u8, srcinfo: []const u8) !void {
    const srcinfo_copy = try allocator.dupe(u8, srcinfo);
    defer allocator.free(srcinfo_copy);

    const srcinfo_path = try std.fmt.allocPrint(allocator, "{s}/.SRCINFO", .{build_dir});
    defer allocator.free(srcinfo_path);
    var srcinfo_file = try std.fs.createFileAbsolute(srcinfo_path, .{ .truncate = true });
    defer srcinfo_file.close();
    try srcinfo_file.writeAll(srcinfo_copy);
}

fn runPkgbuildSecurityCheck(allocator: Allocator, build_dir: []const u8) !void {
    const pkgbuild_path = try std.fmt.allocPrint(allocator, "{s}/PKGBUILD", .{build_dir});
    defer allocator.free(pkgbuild_path);
    const body = try readFileAbsoluteAlloc(allocator, pkgbuild_path, 1024 * 1024);
    defer allocator.free(body);

    const analysis = analyzePkgbuildCapabilities(body);
    std.debug.print("\n{s}PKGBUILD security check{s}\n", .{ color_title, color_reset });
    rule();
    std.debug.print("  - Executed by makepkg as current user: yes\n", .{});
    std.debug.print("  - Can run arbitrary shell commands during prepare/build/check/package: yes\n", .{});
    std.debug.print("  - Can read/write files owned by current user: yes\n", .{});
    std.debug.print("  - Direct root access from PKGBUILD itself: no (unless build scripts escalate)\n", .{});
    std.debug.print("  - Root actions happen later via pacman install step\n", .{});
    std.debug.print("  - Network/download indicators: {s}\n", .{if (analysis.network) "present" else "not obvious"});
    std.debug.print("  - File mutation indicators: {s}\n", .{if (analysis.file_mutation) "present" else "not obvious"});
    std.debug.print("  - Service/system mutation indicators: {s}\n", .{if (analysis.system_mutation) "present" else "not obvious"});
    if (analysis.risky_count > 0) {
        std.debug.print("  - Risky command markers ({d}): ", .{analysis.risky_count});
        for (analysis.risky_markers, 0..) |marker, idx| {
            if (idx >= analysis.risky_count) break;
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{marker});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("  - Risky command markers: none detected\n", .{});
    }
    rule();
}

const PkgbuildAnalysis = struct {
    network: bool = false,
    file_mutation: bool = false,
    system_mutation: bool = false,
    risky_markers: [16][]const u8 = [_][]const u8{""} ** 16,
    risky_count: usize = 0,
};

fn analyzePkgbuildCapabilities(body: []const u8) PkgbuildAnalysis {
    var out = PkgbuildAnalysis{};
    const candidates = [_][]const u8{
        "curl", "wget", "git clone", "rm -", "chmod", "chown", "install ",
        "cp ", "mv ", "systemctl", "sudo", "mount ", "dd ", "mkfs", "tee ",
    };
    for (candidates) |needle| {
        if (std.mem.indexOf(u8, body, needle) != null) {
            if (std.mem.indexOf(u8, needle, "curl") != null or std.mem.indexOf(u8, needle, "wget") != null or std.mem.indexOf(u8, needle, "git clone") != null) {
                out.network = true;
            }
            if (std.mem.indexOf(u8, needle, "rm -") != null or std.mem.indexOf(u8, needle, "chmod") != null or std.mem.indexOf(u8, needle, "chown") != null or std.mem.indexOf(u8, needle, "install ") != null or std.mem.indexOf(u8, needle, "cp ") != null or std.mem.indexOf(u8, needle, "mv ") != null or std.mem.indexOf(u8, needle, "tee ") != null) {
                out.file_mutation = true;
            }
            if (std.mem.indexOf(u8, needle, "systemctl") != null or std.mem.indexOf(u8, needle, "sudo") != null or std.mem.indexOf(u8, needle, "mount ") != null or std.mem.indexOf(u8, needle, "dd ") != null or std.mem.indexOf(u8, needle, "mkfs") != null) {
                out.system_mutation = true;
            }
            if (out.risky_count < out.risky_markers.len) {
                out.risky_markers[out.risky_count] = needle;
                out.risky_count += 1;
            }
        }
    }
    return out;
}

fn readFileAbsoluteAlloc(allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    var f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return f.readToEndAlloc(allocator, max);
}

fn showFileForReview(allocator: Allocator, build_dir: []const u8, file_name: []const u8) !void {
    const pager_rc = runStreamingCwd(allocator, build_dir, &.{ "less", "-R", file_name }) catch 1;
    if (pager_rc == 0) return;
    const cat_rc = runStreamingCwd(allocator, build_dir, &.{ "cat", file_name }) catch 1;
    if (cat_rc != 0) return error.PkgbuildReadFailed;
}

fn printDependencyLines(srcinfo: []const u8) !void {
    std.debug.print("{s}Dependencies{s}\n", .{ color_title, color_reset });
    rule();
    var it = std.mem.splitScalar(u8, srcinfo, '\n');
    var found = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "depends = ") or
            std.mem.startsWith(u8, trimmed, "makedepends = ") or
            std.mem.startsWith(u8, trimmed, "checkdepends = ") or
            std.mem.startsWith(u8, trimmed, "optdepends = "))
        {
            found = true;
            std.debug.print("  - {s}\n", .{trimmed});
        }
    }
    if (!found) std.debug.print("  - (none declared)\n", .{});
    rule();
}

const AurInfo = struct {
    parsed: std.json.Parsed(std.json.Value),
    entry: ?std.json.Value,
};

fn fetchAurInfo(allocator: Allocator, pkg: []const u8) !AurInfo {
    const body = try fetchAurInfoBody(allocator, pkg);
    defer allocator.free(body);
    return parseAurInfoBody(allocator, body);
}

fn fetchAurInfoCached(allocator: Allocator, ctx: *InstallContext, pkg: []const u8) !AurInfo {
    const body = try fetchAurInfoBodyCached(allocator, ctx, pkg);
    return parseAurInfoBody(allocator, body);
}

fn fetchAurInfoBody(allocator: Allocator, pkg: []const u8) ![]u8 {
    const enc = try urlEncode(allocator, pkg);
    defer allocator.free(enc);

    const url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/rpc/v5/info/{s}", .{enc});
    defer allocator.free(url);

    return fetchUrl(allocator, url);
}

fn fetchAurInfoBodyCached(allocator: Allocator, ctx: *InstallContext, pkg: []const u8) ![]const u8 {
    if (ctx.aur_info_cache.get(pkg)) |cached| return cached;
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    if (try readAurInfoDiskCache(allocator, cache_root, pkg, aur_info_cache_ttl_secs)) |disk_cached| {
        g_run_summary.cache_hits += 1;
        const cached_key = try allocator.dupe(u8, pkg);
        errdefer allocator.free(cached_key);
        try ctx.aur_info_cache.put(cached_key, disk_cached);
        return ctx.aur_info_cache.get(pkg).?;
    }
    g_run_summary.cache_misses += 1;

    const body = try fetchAurInfoBody(allocator, pkg);
    defer allocator.free(body);

    const cached_key = try allocator.dupe(u8, pkg);
    errdefer allocator.free(cached_key);
    const cached_body = try allocator.dupe(u8, body);
    errdefer allocator.free(cached_body);
    try ctx.aur_info_cache.put(cached_key, cached_body);
    try writeAurInfoDiskCache(allocator, cache_root, pkg, body);
    return ctx.aur_info_cache.get(pkg).?;
}

fn parseAurInfoBody(allocator: Allocator, body: []const u8) !AurInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const results = getArray(parsed.value, "results") orelse return .{ .parsed = parsed, .entry = null };
    if (results.items.len == 0) return .{ .parsed = parsed, .entry = null };
    return .{ .parsed = parsed, .entry = results.items[0] };
}

fn resolveAurPackageBase(allocator: Allocator, pkg: []const u8) !?[]u8 {
    const info = try fetchAurInfo(allocator, pkg);
    defer info.parsed.deinit();
    if (info.entry == null) return null;

    const base = getString(info.entry.?, "PackageBase") orelse getString(info.entry.?, "Name") orelse return null;
    return try allocator.dupe(u8, base);
}

fn resolveAurPackageBaseCached(allocator: Allocator, ctx: *InstallContext, pkg: []const u8) !?[]u8 {
    const info = try fetchAurInfoCached(allocator, ctx, pkg);
    defer info.parsed.deinit();
    if (info.entry == null) return null;

    const base = getString(info.entry.?, "PackageBase") orelse getString(info.entry.?, "Name") orelse return null;
    return try allocator.dupe(u8, base);
}

fn installedVersion(allocator: Allocator, pkg: []const u8) ![]u8 {
    const out = try runCapture(allocator, &.{ "pacman", "-Q", pkg });
    defer allocator.free(out);
    var tok = std.mem.tokenizeAny(u8, out, " \t\r\n");
    _ = tok.next() orelse return error.InvalidPacmanOutput;
    const version = tok.next() orelse return error.InvalidPacmanOutput;
    return try allocator.dupe(u8, version);
}

const AurCandidate = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
};

fn fetchAurCandidates(allocator: Allocator, dep: []const u8) ![]AurCandidate {
    var candidates: std.ArrayListUnmanaged(AurCandidate) = .{};
    errdefer {
        for (candidates.items) |c| {
            allocator.free(c.name);
            allocator.free(c.version);
            allocator.free(c.description);
        }
        candidates.deinit(allocator);
    }

    // 1. Try exact match info
    const info_body = fetchAurInfoBody(allocator, dep) catch null;
    if (info_body) |body| {
        defer allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        if (getArray(parsed.value, "results")) |results| {
            for (results.items) |item| {
                const name = getString(item, "Name") orelse continue;
                const version = getString(item, "Version") orelse "";
                const desc = getString(item, "Description") orelse "";
                try candidates.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .version = try allocator.dupe(u8, version),
                    .description = try allocator.dupe(u8, desc),
                });
            }
        }
    }

    // 2. Search by provides
    const enc = try urlEncode(allocator, dep);
    defer allocator.free(enc);
    const prov_url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/rpc/v5/search/{s}?by=provides", .{enc});
    defer allocator.free(prov_url);
    const prov_body = fetchUrl(allocator, prov_url) catch null;
    if (prov_body) |body| {
        defer allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        if (getArray(parsed.value, "results")) |results| {
            for (results.items) |item| {
                const name = getString(item, "Name") orelse continue;

                var already_in = false;
                for (candidates.items) |c| {
                    if (std.mem.eql(u8, c.name, name)) {
                        already_in = true;
                        break;
                    }
                }
                if (already_in) continue;

                const version = getString(item, "Version") orelse "";
                const desc = getString(item, "Description") orelse "";
                try candidates.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .version = try allocator.dupe(u8, version),
                    .description = try allocator.dupe(u8, desc),
                });
            }
        }
    }

    return try candidates.toOwnedSlice(allocator);
}

fn selectAurProvider(allocator: Allocator, dep: []const u8) !?[]u8 {
    const candidates = try fetchAurCandidates(allocator, dep);
    defer {
        for (candidates) |c| {
            allocator.free(c.name);
            allocator.free(c.version);
            allocator.free(c.description);
        }
        allocator.free(candidates);
    }

    if (candidates.len == 0) return null;
    if (candidates.len == 1) return try allocator.dupe(u8, candidates[0].name);

    if (!stdinIsTty()) return try allocator.dupe(u8, candidates[0].name);

    sectionFmt("There are {d} providers available for {s}:", .{ candidates.len, dep });
    for (candidates, 0..) |c, i| {
        std.debug.print("{s}{d: >2}){s} aur/{s} {s}\n", .{ color_title, i + 1, color_reset, c.name, c.version });
        if (c.description.len > 0) {
            std.debug.print("    {s}{s}{s}\n", .{ color_dim, c.description, color_reset });
        }
    }

    while (true) {
        const prompt = try std.fmt.allocPrint(allocator, "Enter a number [1-{d}]: ", .{candidates.len});
        defer allocator.free(prompt);
        const choice_raw = try promptLine(allocator, prompt);
        defer allocator.free(choice_raw);

        const selection = std.fmt.parseInt(usize, choice_raw, 10) catch {
            warnLine("Invalid selection");
            continue;
        };
        if (selection < 1 or selection > candidates.len) {
            warnLine("Selection out of range");
            continue;
        }
        return try allocator.dupe(u8, candidates[selection - 1].name);
    }
}

fn vercmp(allocator: Allocator, a: []const u8, b: []const u8) !i32 {
    const out = try runCapture(allocator, &.{ "vercmp", a, b });
    defer allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return try std.fmt.parseInt(i32, trimmed, 10);
}

fn listForeignPackageNames(allocator: Allocator) ![]const []const u8 {
    const out = try runCapture(allocator, &.{ "pacman", "-Qm" });
    defer allocator.free(out);

    var line_it = std.mem.splitScalar(u8, out, '\n');
    var count: usize = 0;
    while (line_it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }

    var names = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    line_it = std.mem.splitScalar(u8, out, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = tok.next() orelse continue;
        names[idx] = try allocator.dupe(u8, name);
        idx += 1;
    }
    return names[0..idx];
}

fn freeNameList(allocator: Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn fetchUrl(allocator: Allocator, url: []const u8) ![]u8 {
    return runCaptureRetry(allocator, &.{ "curl", "-fsSL", url }, network_retry_max_attempts, network_retry_initial_delay_ms) catch |err| {
        setFailureContext("aur rpc", url, "curl -fsSL <url>", "Check network connectivity and retry");
        return err;
    };
}

const RepoSync = struct {
    repo_dir: []u8,
    pkgbuild_diff: ?[]u8,
    reviewed_from: ?[]u8,
};

fn ensureAurRepoCacheSynced(allocator: Allocator, cache_root: []const u8, repo_base: []const u8) !RepoSync {
    const repos_root = try std.fmt.allocPrint(allocator, "{s}/aur-repos", .{cache_root});
    defer allocator.free(repos_root);
    try std.fs.cwd().makePath(repos_root);

    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repos_root, repo_base });
    const repo_exists = try pathExists(repo_dir);
    const old_head = if (repo_exists) try gitHeadCommit(allocator, repo_dir) else null;
    defer if (old_head) |h| allocator.free(h);

    if (!repo_exists) {
        const repo_url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/{s}.git", .{repo_base});
        defer allocator.free(repo_url);
        const clone_rc = try runStreamingRetry(allocator, &.{ "git", "clone", "--depth", "1", repo_url, repo_dir }, network_retry_max_attempts, network_retry_initial_delay_ms);
        if (clone_rc != 0) {
            setFailureContext("aur clone", repo_base, "git clone --depth 1 ...", "Check network/AUR availability");
            return error.AurCloneFailed;
        }
        return .{ .repo_dir = repo_dir, .pkgbuild_diff = null, .reviewed_from = null };
    }

    var fetch_rc = try runStreamingRetry(allocator, &.{ "git", "-C", repo_dir, "fetch", "--depth", "1", "origin" }, network_retry_max_attempts, network_retry_initial_delay_ms);
    if (fetch_rc != 0) {
        fetch_rc = try runStreamingRetry(allocator, &.{ "git", "-C", repo_dir, "fetch", "origin" }, network_retry_max_attempts, network_retry_initial_delay_ms);
        if (fetch_rc != 0) {
            setFailureContext("aur fetch", repo_base, "git fetch origin", "Check network and rerun");
            return error.AurFetchFailed;
        }
    }
    const reset_rc = try runStreaming(allocator, &.{ "git", "-C", repo_dir, "reset", "--hard", "FETCH_HEAD" });
    if (reset_rc != 0) {
        setFailureContext("aur sync", repo_base, "git reset --hard FETCH_HEAD", "Try --cache-clean and rerun");
        return error.AurFetchFailed;
    }

    const new_head = try gitHeadCommit(allocator, repo_dir);
    defer if (new_head) |h| allocator.free(h);
    if (new_head == null) {
        return .{ .repo_dir = repo_dir, .pkgbuild_diff = null, .reviewed_from = null };
    }

    const reviewed_commit = try readReviewedCommit(allocator, cache_root, repo_base);
    defer if (reviewed_commit) |c| allocator.free(c);
    if (reviewed_commit != null and !eql(reviewed_commit.?, new_head.?)) {
        const diff_reviewed = runCapture(allocator, &.{ "git", "-C", repo_dir, "diff", reviewed_commit.?, new_head.?, "--", "PKGBUILD" }) catch null;
        return .{ .repo_dir = repo_dir, .pkgbuild_diff = diff_reviewed, .reviewed_from = try allocator.dupe(u8, reviewed_commit.?) };
    }

    if (old_head == null or eql(old_head.?, new_head.?)) {
        return .{ .repo_dir = repo_dir, .pkgbuild_diff = null, .reviewed_from = null };
    }
    const diff = runCapture(allocator, &.{ "git", "-C", repo_dir, "diff", old_head.?, new_head.?, "--", "PKGBUILD" }) catch null;
    return .{ .repo_dir = repo_dir, .pkgbuild_diff = diff, .reviewed_from = null };
}

fn pathExists(path: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn gitHeadCommit(allocator: Allocator, repo_dir: []const u8) !?[]u8 {
    const out = runCapture(allocator, &.{ "git", "-C", repo_dir, "rev-parse", "HEAD" }) catch return null;
    defer allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn melonCacheRoot(allocator: Allocator) ![]u8 {
    const xdg = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch null;
    if (xdg) |p| {
        defer allocator.free(p);
        return std.fmt.allocPrint(allocator, "{s}/melon", .{p});
    }
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |p| {
        defer allocator.free(p);
        return std.fmt.allocPrint(allocator, "{s}/.cache/melon", .{p});
    }
    return allocator.dupe(u8, "/tmp/melon-cache");
}

fn aurInfoCachePath(allocator: Allocator, cache_root: []const u8, pkg: []const u8) ![]u8 {
    const info_dir = try std.fmt.allocPrint(allocator, "{s}/aur-info", .{cache_root});
    defer allocator.free(info_dir);
    try std.fs.cwd().makePath(info_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ info_dir, pkg });
}

fn readAurInfoDiskCache(allocator: Allocator, cache_root: []const u8, pkg: []const u8, ttl_secs: i64) !?[]u8 {
    const cache_path = try aurInfoCachePath(allocator, cache_root, pkg);
    defer allocator.free(cache_path);
    var file = std.fs.openFileAbsolute(cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const age_ns = std.time.nanoTimestamp() - stat.mtime;
    if (age_ns > ttl_secs * std.time.ns_per_s) return null;
    return try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
}

fn writeAurInfoDiskCache(allocator: Allocator, cache_root: []const u8, pkg: []const u8, body: []const u8) !void {
    const cache_path = try aurInfoCachePath(allocator, cache_root, pkg);
    defer allocator.free(cache_path);
    var file = try std.fs.createFileAbsolute(cache_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
}

fn reviewedCommitPath(allocator: Allocator, cache_root: []const u8, pkg: []const u8) ![]u8 {
    const reviewed_dir = try std.fmt.allocPrint(allocator, "{s}/reviewed", .{cache_root});
    defer allocator.free(reviewed_dir);
    try std.fs.cwd().makePath(reviewed_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ reviewed_dir, pkg });
}

fn readReviewedCommit(allocator: Allocator, cache_root: []const u8, pkg: []const u8) !?[]u8 {
    const path = try reviewedCommitPath(allocator, cache_root, pkg);
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const out = try file.readToEndAlloc(allocator, 256);
    defer allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn writeReviewedCommit(allocator: Allocator, cache_root: []const u8, pkg: []const u8, commit: []const u8) !void {
    const path = try reviewedCommitPath(allocator, cache_root, pkg);
    defer allocator.free(path);
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(commit);
    try file.writeAll("\n");
}

fn failedPackagesPath(allocator: Allocator, cache_root: []const u8) ![]u8 {
    try std.fs.cwd().makePath(cache_root);
    return std.fmt.allocPrint(allocator, "{s}/failed-packages.txt", .{cache_root});
}

fn loadFailedPackages(allocator: Allocator) ![]const []const u8 {
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const path = try failedPackagesPath(allocator, cache_root);
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer file.close();
    const body = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(body);

    var line_it = std.mem.splitScalar(u8, body, '\n');
    var count: usize = 0;
    while (line_it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    var out = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        out[idx] = try allocator.dupe(u8, trimmed);
        idx += 1;
    }
    return out[0..idx];
}

fn clearFailedPackages(allocator: Allocator) !void {
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const path = try failedPackagesPath(allocator, cache_root);
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn recordFailedPackage(allocator: Allocator, pkg: []const u8) !void {
    const existing = try loadFailedPackages(allocator);
    defer freeNameList(allocator, existing);
    for (existing) |name| {
        if (eql(name, pkg)) return;
    }
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const path = try failedPackagesPath(allocator, cache_root);
    defer allocator.free(path);

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    for (existing) |name| {
        try file.writeAll(name);
        try file.writeAll("\n");
    }
    try file.writeAll(pkg);
    try file.writeAll("\n");
}

const PrefetchState = struct {
    next_idx: std.atomic.Value(usize),
    names: []const []const u8,
    cache_root: []const u8,
};

fn prefetchAurInfoInParallel(allocator: Allocator, aur_list: []const []const u8) !void {
    if (aur_list.len < 2) return;
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    var state = PrefetchState{
        .next_idx = std.atomic.Value(usize).init(0),
        .names = aur_list,
        .cache_root = cache_root,
    };
    const cpu_count = std.Thread.getCpuCount() catch default_prefetch_jobs;
    const worker_count = @min(@min(cpu_count, default_prefetch_jobs), aur_list.len);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (threads, 0..) |*th, idx| {
        th.* = try std.Thread.spawn(.{}, prefetchWorker, .{ &state, idx });
    }
    for (threads) |th| th.join();
}

fn prefetchWorker(state: *PrefetchState, _: usize) void {
    const allocator = std.heap.page_allocator;
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .monotonic);
        if (idx >= state.names.len) break;
        const pkg = state.names[idx];
        const body = fetchAurInfoBody(allocator, pkg) catch continue;
        defer allocator.free(body);
        writeAurInfoDiskCache(allocator, state.cache_root, pkg, body) catch {};
    }
}

fn cacheInfo(allocator: Allocator, config: RunConfig) !void {
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const stats = try dirSizeAndFiles(allocator, cache_root);
    if (config.json) {
        std.debug.print("{{\"cache_root\":\"{s}\",\"files\":{d},\"bytes\":{d}}}\n", .{ cache_root, stats.files, stats.bytes });
        return;
    }
    title("Cache info");
    kv("root", cache_root);
    kvInt("files", stats.files);
    kvInt("bytes", stats.bytes);
}

fn cacheClean(allocator: Allocator, config: RunConfig) !void {
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    std.fs.deleteTreeAbsolute(cache_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (config.json) {
        std.debug.print("{{\"cache_cleaned\":true,\"cache_root\":\"{s}\"}}\n", .{cache_root});
        return;
    }
    okLineFmt("cache cleaned: {s}", .{cache_root});
}

fn resumeFailed(allocator: Allocator, config: RunConfig) !void {
    const failed = try loadFailedPackages(allocator);
    defer freeNameList(allocator, failed);
    if (failed.len == 0) {
        if (config.json) {
            std.debug.print("{{\"resumed\":0,\"status\":\"empty\"}}\n", .{});
        } else {
            warnLine("no failed package set found");
        }
        return;
    }
    if (!config.json) {
        sectionFmt("resuming {d} failed packages", .{failed.len});
    }
    try installWithCompatibility(allocator, config, failed);
    if (config.json) {
        std.debug.print("{{\"resumed\":{d},\"status\":\"ok\"}}\n", .{failed.len});
    }
}

const DirStats = struct {
    files: usize = 0,
    bytes: usize = 0,
};

fn dirSizeAndFiles(allocator: Allocator, root: []const u8) !DirStats {
    var stats = DirStats{};
    try accumulateDirStats(allocator, root, &stats);
    return stats;
}

fn accumulateDirStats(allocator: Allocator, root: []const u8, stats: *DirStats) !void {
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => try accumulateDirStats(allocator, child, stats),
            .file => {
                stats.files += 1;
                var f = try std.fs.openFileAbsolute(child, .{});
                defer f.close();
                const st = try f.stat();
                stats.bytes += @intCast(st.size);
            },
            else => {},
        }
    }
}

fn createSecureBuildDir(allocator: Allocator, repo_base: []const u8) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);

    const now = std.time.milliTimestamp();
    return std.fmt.allocPrint(allocator, "/tmp/melon-{s}-{d}-{s}", .{ repo_base, now, random_hex[0..] });
}

fn generateSrcinfo(allocator: Allocator, config: RunConfig, build_dir: []const u8, pkg: []const u8) ![]u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .{};
    defer args.deinit(allocator);
    try args.append(allocator, "makepkg");
    try args.append(allocator, "--printsrcinfo");
    if (!config.pgpfetch) try args.append(allocator, "--skippgpcheck");
    return runCaptureCwd(allocator, build_dir, args.items) catch |err| {
        errLineFmt("failed to generate .SRCINFO for aur/{s}: {s}", .{ pkg, @errorName(err) });
        return error.SrcInfoFailed;
    };
}

fn buildAurPackage(allocator: Allocator, config: RunConfig, build_dir: []const u8, repo_base: []const u8, noinstall: bool) ![]const []const u8 {
    if (config.chroot) {
        const have_chroot = (runStatus(allocator, null, &.{ "sh", "-lc", "command -v extra-x86_64-build >/dev/null 2>&1" }) catch 1) == 0;
        if (!have_chroot) {
            setFailureContext("aur build", repo_base, "extra-x86_64-build", "Install devtools or disable --chroot");
            return error.MakepkgFailed;
        }
        const rc = try runStreamingCwd(allocator, build_dir, &.{"extra-x86_64-build"});
        if (rc != 0) {
            setFailureContext("aur chroot build", repo_base, "extra-x86_64-build", "Check devtools/chroot setup");
            return error.MakepkgFailed;
        }
        return listBuiltPackageFiles(allocator, build_dir);
    }

    var args: std.ArrayListUnmanaged([]const u8) = .{};
    defer args.deinit(allocator);
    try args.append(allocator, "makepkg");
    try args.append(allocator, "-s");
    try args.append(allocator, "--noconfirm");
    if (!config.pgpfetch) try args.append(allocator, "--skippgpcheck");
    if (config.sign) try args.append(allocator, "--sign");
    if (noinstall) {
        try args.append(allocator, "--noinstall");
    } else {
        try args.append(allocator, "-i");
    }
    const mk_rc = try runStreamingCwd(allocator, build_dir, args.items);
    if (mk_rc != 0) {
        setFailureContext("aur build", repo_base, "makepkg -s ...", "Review PKGBUILD and rerun with --resume-failed");
        return error.MakepkgFailed;
    }
    if (!noinstall) return allocator.alloc([]const u8, 0);
    return listBuiltPackageFiles(allocator, build_dir);
}

fn listBuiltPackageFiles(allocator: Allocator, build_dir: []const u8) ![]const []const u8 {
    var dir = try std.fs.openDirAbsolute(build_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var out: std.ArrayListUnmanaged([]const u8) = .{};
    defer out.deinit(allocator);
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, ".pkg.tar") == null) continue;
        if (std.mem.endsWith(u8, entry.name, ".sig")) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ build_dir, entry.name });
        try out.append(allocator, full);
    }
    return out.toOwnedSlice(allocator);
}

fn installBuiltPackages(allocator: Allocator, config: RunConfig, pkg_paths: []const []const u8) !void {
    if (pkg_paths.len == 0) return;
    const args_len = 1 + pkg_paths.len;
    var pac_args = try allocator.alloc([]const u8, args_len);
    defer allocator.free(pac_args);
    pac_args[0] = "-U";
    @memcpy(pac_args[1..], pkg_paths);
    const rc = try runPacmanSudoMaybe(allocator, config, pac_args);
    if (rc != 0) return error.PacmanInstallFailed;
}

fn localRepoDir(allocator: Allocator, ctx: *InstallContext) ![]const u8 {
    if (ctx.local_repo_dir) |p| return p;
    const cache_root = try melonCacheRoot(allocator);
    defer allocator.free(cache_root);
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/localrepo", .{cache_root});
    try std.fs.cwd().makePath(repo_dir);
    ctx.local_repo_dir = repo_dir;
    return repo_dir;
}

fn addPackagesToLocalRepo(allocator: Allocator, ctx: *InstallContext, pkg_paths: []const []const u8) !void {
    if (pkg_paths.len == 0) return;
    const repo_dir = try localRepoDir(allocator, ctx);
    for (pkg_paths) |pkg_path| {
        const cp_rc = try runStreaming(allocator, &.{ "cp", "-f", pkg_path, repo_dir });
        if (cp_rc != 0) return error.CommandFailed;
    }

    var copied: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (copied.items) |p| allocator.free(p);
        copied.deinit(allocator);
    }
    for (pkg_paths) |pkg_path| {
        const name = std.fs.path.basename(pkg_path);
        try copied.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, name }));
    }

    const db = try std.fmt.allocPrint(allocator, "{s}/melon-local.db.tar.gz", .{repo_dir});
    defer allocator.free(db);
    const argc = 2 + (if (ctx.config.signdb) @as(usize, 1) else 0) + copied.items.len;
    var repo_add_args = try allocator.alloc([]const u8, argc);
    defer allocator.free(repo_add_args);
    var i: usize = 0;
    repo_add_args[i] = "repo-add";
    i += 1;
    if (ctx.config.signdb) {
        repo_add_args[i] = "--sign";
        i += 1;
    }
    repo_add_args[i] = db;
    i += 1;
    @memcpy(repo_add_args[i..], copied.items);
    const rc = try runStreaming(allocator, repo_add_args);
    if (rc != 0) return error.CommandFailed;
}

fn flushPendingBatchInstalls(allocator: Allocator, ctx: *InstallContext) !void {
    if (!ctx.config.batchinstall or ctx.pending_pkg_paths.items.len == 0) return;
    section("batch install");
    try installBuiltPackages(allocator, ctx.config, ctx.pending_pkg_paths.items);
    for (ctx.pending_pkg_paths.items) |path| allocator.free(path);
    ctx.pending_pkg_paths.clearRetainingCapacity();
}

fn savePkgbuildReviewChanges(allocator: Allocator, build_dir: []const u8, repo_base: []const u8) !void {
    const dirty_rc = runStatus(allocator, build_dir, &.{ "git", "diff", "--quiet", "--", "PKGBUILD", ".SRCINFO" }) catch 0;
    if (dirty_rc == 0) return;
    _ = try runStreamingCwd(allocator, build_dir, &.{ "git", "add", "--", "PKGBUILD", ".SRCINFO" });
    const msg = try std.fmt.allocPrint(allocator, "melon: save review changes for {s}", .{repo_base});
    defer allocator.free(msg);
    const commit_rc = try runStreamingCwd(allocator, build_dir, &.{ "git", "-c", "user.name=melon", "-c", "user.email=melon@localhost", "commit", "-m", msg });
    if (commit_rc != 0) warnLine("savechanges enabled but no commit was created");
}

fn installDebugCompanions(allocator: Allocator, config: RunConfig, packages: []const []const u8) !void {
    for (packages) |pkg| {
        const debug_name = try std.fmt.allocPrint(allocator, "{s}-debug", .{pkg});
        defer allocator.free(debug_name);
        if (!try isOfficialPackage(allocator, debug_name)) continue;
        _ = try runPacmanSudoMaybe(allocator, config, &.{ "-S", "--needed", debug_name });
    }
}

fn isDevelPackageName(pkg: []const u8) bool {
    return std.mem.endsWith(u8, pkg, "-git") or
        std.mem.endsWith(u8, pkg, "-svn") or
        std.mem.endsWith(u8, pkg, "-hg") or
        std.mem.endsWith(u8, pkg, "-bzr") or
        std.mem.endsWith(u8, pkg, "-darcs");
}

fn showArchNews(allocator: Allocator) !void {
    section("arch news");
    const body = fetchUrl(allocator, "https://archlinux.org/feeds/news/") catch {
        warnLine("failed to fetch arch news");
        return;
    };
    defer allocator.free(body);
    var it = std.mem.splitSequence(u8, body, "<item>");
    _ = it.next();
    var count: usize = 0;
    while (it.next()) |item| {
        if (count >= 5) break;
        const title_start = std.mem.indexOf(u8, item, "<title>") orelse continue;
        const title_end = std.mem.indexOf(u8, item, "</title>") orelse continue;
        const t = item[title_start + "<title>".len .. title_end];
        std.debug.print("  - {s}\n", .{std.mem.trim(u8, t, " \t\r\n")});
        count += 1;
    }
}

fn isInstalledPackage(allocator: Allocator, pkg: []const u8) !bool {
    const rc = runStatus(allocator, null, &.{ "pacman", "-Qi", pkg }) catch return false;
    return rc == 0;
}

fn isOfficialPackage(allocator: Allocator, pkg: []const u8) !bool {
    const rc = runStatus(allocator, null, &.{ "pacman", "-Si", pkg }) catch 1;
    if (rc == 0) return true;
    const rc_prov = runStatus(allocator, null, &.{ "pacman", "-Sp", "--noconfirm", pkg }) catch 1;
    return rc_prov == 0;
}

fn pacmanPassthrough(allocator: Allocator, config: RunConfig, pacman_args: []const []const u8) !void {
    const rc = if (needsRootPacman(pacman_args))
        try runPacmanSudoMaybe(allocator, config, pacman_args)
    else
        try runPacman(allocator, pacman_args);
    if (rc != 0) return error.PacmanPassthroughFailed;
}

fn isDependencySatisfied(allocator: Allocator, dep: []const u8) !bool {
    const out = runCapture(allocator, &.{ "pacman", "-T", dep }) catch return false;
    defer allocator.free(out);
    return std.mem.trim(u8, out, " \t\r\n").len == 0;
}

fn needsRootPacman(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const first = args[0];
    if (std.mem.startsWith(u8, first, "--sync") or
        std.mem.startsWith(u8, first, "--remove") or
        std.mem.startsWith(u8, first, "--upgrade") or
        std.mem.startsWith(u8, first, "--database"))
    {
        return true;
    }
    if (first.len < 2 or first[0] != '-') return false;
    var i: usize = 1;
    while (i < first.len) : (i += 1) {
        const c = first[i];
        if (c == 'S' or c == 'R' or c == 'U' or c == 'D') return true;
    }
    return false;
}

fn runPacman(allocator: Allocator, pacman_args: []const []const u8) !u8 {
    var argv = try allocator.alloc([]const u8, pacman_args.len + 1);
    defer allocator.free(argv);
    argv[0] = "pacman";
    @memcpy(argv[1..], pacman_args);
    return runStreaming(allocator, argv);
}

fn runPacmanSudo(allocator: Allocator, pacman_args: []const []const u8) !u8 {
    var argv = try allocator.alloc([]const u8, pacman_args.len + 2);
    defer allocator.free(argv);
    argv[0] = "sudo";
    argv[1] = "pacman";
    @memcpy(argv[2..], pacman_args);
    return runStreaming(allocator, argv);
}

fn runPacmanSudoMaybe(allocator: Allocator, config: RunConfig, pacman_args: []const []const u8) !u8 {
    const effective = try withPacmanAskOption(allocator, config, pacman_args);
    defer allocator.free(effective);
    if (config.dry_run) {
        printDryRunCommand("sudo pacman", effective);
        return 0;
    }
    // sudoloop is now handled by the background thread (startSudoLoop)
    return runPacmanSudo(allocator, effective);
}

fn withPacmanAskOption(allocator: Allocator, config: RunConfig, pacman_args: []const []const u8) ![]const []const u8 {
    if (!config.useask or hasPacmanAskArg(pacman_args)) {
        const out = try allocator.alloc([]const u8, pacman_args.len);
        @memcpy(out, pacman_args);
        return out;
    }
    const out = try allocator.alloc([]const u8, pacman_args.len + 1);
    @memcpy(out[0..pacman_args.len], pacman_args);
    out[pacman_args.len] = "--ask=4";
    return out;
}

fn hasPacmanAskArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (eql(arg, "--ask") or std.mem.startsWith(u8, arg, "--ask=")) return true;
    }
    return false;
}

fn stdinIsTty() bool {
    if (@hasDecl(std.fs.File, "stdin")) return std.fs.File.stdin().isTty();
    if (@hasDecl(std, "io")) {
        if (@hasDecl(std.io, "getStdIn")) return std.io.getStdIn().isTty();
    }
    if (@hasDecl(std, "Io")) {
        if (@hasDecl(std.Io, "getStdIn")) return std.Io.getStdIn().isTty();
    }
    return true;
}

fn sleepNs(ns: u64) void {
    if (@hasDecl(std.Thread, "sleep")) {
        std.Thread.sleep(ns);
        return;
    }
    if (@hasDecl(std.time, "sleep")) {
        std.time.sleep(ns);
        return;
    }
}

fn runStreamingRetry(allocator: Allocator, argv: []const []const u8, max_attempts: usize, initial_delay_ms: u64) !u8 {
    var attempt: usize = 0;
    var delay = initial_delay_ms;
    while (attempt < max_attempts) : (attempt += 1) {
        const rc = runStreaming(allocator, argv) catch 1;
        if (rc == 0) return 0;
        if (attempt + 1 < max_attempts) sleepNs(delay * std.time.ns_per_ms);
        delay *= 2;
    }
    return 1;
}

fn runCaptureRetry(allocator: Allocator, argv: []const []const u8, max_attempts: usize, initial_delay_ms: u64) ![]u8 {
    var attempt: usize = 0;
    var delay = initial_delay_ms;
    while (attempt < max_attempts) : (attempt += 1) {
        const out = runCapture(allocator, argv) catch null;
        if (out) |data| return data;
        if (attempt + 1 < max_attempts) sleepNs(delay * std.time.ns_per_ms);
        delay *= 2;
    }
    return error.CommandFailed;
}

fn getValue(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const candidate = getValue(v, key) orelse return null;
    if (candidate != .string) return null;
    return candidate.string;
}

fn getArray(v: std.json.Value, key: []const u8) ?std.json.Array {
    const candidate = getValue(v, key) orelse return null;
    if (candidate != .array) return null;
    return candidate.array;
}

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const candidate = getValue(v, key) orelse return null;
    if (candidate != .integer) return null;
    return candidate.integer;
}

fn getFloat(v: std.json.Value, key: []const u8) ?f64 {
    const candidate = getValue(v, key) orelse return null;
    return switch (candidate) {
        .float => candidate.float,
        .integer => @as(f64, @floatFromInt(candidate.integer)),
        else => null,
    };
}

fn freeStringSetKeys(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
}

fn removeStringSetEntryAndFreeKey(allocator: Allocator, set: *std.StringHashMap(void), key: []const u8) void {
    if (set.fetchRemove(key)) |entry| {
        allocator.free(entry.key);
    }
}

fn freeStringToOwnedSliceMap(allocator: Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
}

fn phaseLine(name: []const u8, idx: usize, total: usize) void {
    if (g_json_output) return;
    std.debug.print("{s}[phase {d}/{d}]{s} {s}\n", .{ color_title, idx, total, color_reset, name });
}

fn progressLine(kind: []const u8, item: []const u8, idx: usize, total: usize) void {
    if (g_json_output) return;
    std.debug.print("{s}[{s} {d}/{d}]{s} {s}\n", .{ color_dim, kind, idx, total, color_reset, item });
}

fn setFailureContext(step: []const u8, package: []const u8, command: []const u8, hint: []const u8) void {
    g_failure = .{
        .step = step,
        .package = package,
        .command = command,
        .hint = hint,
    };
}

fn printFailureReport(err: anyerror) void {
    if (g_json_output) {
        std.debug.print("{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
        return;
    }
    std.debug.print("\n{s}Failure report{s}\n", .{ color_err, color_reset });
    rule();
    kv("error", @errorName(err));
    if (g_failure) |f| {
        kv("step", f.step);
        kv("package", f.package);
        kv("command", f.command);
        kv("hint", f.hint);
    } else {
        kv("hint", "Check logs above and rerun with --resume-failed if available");
    }
    rule();
}

fn printSummaryCard() void {
    if (g_run_summary.started_ns == 0) return;
    const elapsed_ns = std.time.nanoTimestamp() - g_run_summary.started_ns;
    const elapsed_ms: i128 = @divFloor(elapsed_ns, std.time.ns_per_ms);
    if (g_json_output) {
        std.debug.print(
            "{{\"summary\":{{\"elapsed_ms\":{d},\"official_targets\":{d},\"aur_targets\":{d},\"aur_installed\":{d},\"aur_upgraded\":{d},\"failures\":{d},\"cache_hits\":{d},\"cache_misses\":{d}}}}}\n",
            .{
                elapsed_ms,
                g_run_summary.official_targets,
                g_run_summary.aur_targets,
                g_run_summary.aur_installed,
                g_run_summary.aur_upgraded,
                g_run_summary.failures,
                g_run_summary.cache_hits,
                g_run_summary.cache_misses,
            },
        );
        return;
    }
    std.debug.print("\n{s}Run summary{s}\n", .{ color_ok, color_reset });
    rule();
    kvInt("official targets", g_run_summary.official_targets);
    kvInt("aur targets", g_run_summary.aur_targets);
    kvInt("aur installed", g_run_summary.aur_installed);
    kvInt("aur upgraded", g_run_summary.aur_upgraded);
    kvInt("failures", g_run_summary.failures);
    kvInt("cache hits", g_run_summary.cache_hits);
    kvInt("cache misses", g_run_summary.cache_misses);
    std.debug.print("  {s: <14} : {d}\n", .{ "elapsed ms", elapsed_ms });
    if (g_run_summary.failures > 0) {
        std.debug.print("  {s: <14} : melon --resume-failed\n", .{"next"});
    }
    rule();
}

fn printDryRunCommand(prefix: []const u8, args: []const []const u8) void {
    if (g_json_output) return;
    std.debug.print("{s}[dry-run]{s} {s}", .{ color_warn, color_reset, prefix });
    for (args) |arg| {
        std.debug.print(" {s}", .{arg});
    }
    std.debug.print("\n", .{});
}

fn title(msg: []const u8) void {
    if (g_json_output) return;
    ui.title(msg);
}

fn section(msg: []const u8) void {
    if (g_json_output) return;
    ui.section(msg);
}

fn sectionFmt(comptime fmt: []const u8, args: anytype) void {
    if (g_json_output) return;
    ui.sectionFmt(fmt, args);
}

fn rule() void {
    if (g_json_output) return;
    ui.rule();
}

fn kv(key: []const u8, value: []const u8) void {
    if (g_json_output) return;
    ui.kv(key, value);
}

fn kvInt(key: []const u8, value: usize) void {
    if (g_json_output) return;
    ui.kvInt(key, value);
}

fn okLine(msg: []const u8) void {
    if (g_json_output) return;
    ui.okLine(msg);
}

fn okLineFmt(comptime fmt: []const u8, args: anytype) void {
    if (g_json_output) return;
    ui.okLineFmt(fmt, args);
}

fn warnLine(msg: []const u8) void {
    if (g_json_output) return;
    ui.warnLine(msg);
}

fn warnLineFmt(comptime fmt: []const u8, args: anytype) void {
    if (g_json_output) return;
    ui.warnLineFmt(fmt, args);
}

fn errLine(msg: []const u8) void {
    if (g_json_output) return;
    ui.errLine(msg);
}

fn errLineFmt(comptime fmt: []const u8, args: anytype) void {
    if (g_json_output) return;
    ui.errLineFmt(fmt, args);
}

fn promptLine(allocator: Allocator, prompt: []const u8) ![]u8 {
    return ui.promptLine(allocator, prompt);
}

test "splitInstallArgs separates options and targets" {
    const allocator = std.testing.allocator;
    const input = [_][]const u8{ "--needed", "--noconfirm", "ripgrep", "paru" };
    const split = try splitInstallArgs(allocator, input[0..]);
    defer allocator.free(split.options);
    defer allocator.free(split.targets);

    try std.testing.expectEqual(@as(usize, 2), split.options.len);
    try std.testing.expectEqual(@as(usize, 2), split.targets.len);
    try std.testing.expectEqualStrings("--needed", split.options[0]);
    try std.testing.expectEqualStrings("--noconfirm", split.options[1]);
    try std.testing.expectEqualStrings("ripgrep", split.targets[0]);
    try std.testing.expectEqualStrings("paru", split.targets[1]);
}

test "splitInstallArgs respects explicit -- separator" {
    const allocator = std.testing.allocator;
    const input = [_][]const u8{ "--needed", "--", "-literal-target" };
    const split = try splitInstallArgs(allocator, input[0..]);
    defer allocator.free(split.options);
    defer allocator.free(split.targets);

    try std.testing.expectEqual(@as(usize, 1), split.options.len);
    try std.testing.expectEqual(@as(usize, 1), split.targets.len);
    try std.testing.expectEqualStrings("--needed", split.options[0]);
    try std.testing.expectEqualStrings("-literal-target", split.targets[0]);
}

test "dependencyBaseName strips operators and repo prefixes" {
    try std.testing.expectEqualStrings("openssl", dependencyBaseName("openssl>=3"));
    try std.testing.expectEqualStrings("python", dependencyBaseName("community/python<3.14"));
    try std.testing.expectEqualStrings("", dependencyBaseName("!conflicts-with"));
}
