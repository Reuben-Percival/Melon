const std = @import("std");

const Allocator = std.mem.Allocator;

const color_reset = "\x1b[0m";
const color_title = "\x1b[1;36m";
const color_ok = "\x1b[1;32m";
const color_warn = "\x1b[1;33m";
const color_err = "\x1b[1;31m";
const color_dim = "\x1b[2m";

const InstallContext = struct {
    allocator: Allocator,
    installed_aur: std.StringHashMap(void),
    visiting_aur: std.StringHashMap(void),
    reviewed_aur: std.StringHashMap(void),
    skip_remaining_reviews: bool,

    fn init(allocator: Allocator) InstallContext {
        return .{
            .allocator = allocator,
            .installed_aur = std.StringHashMap(void).init(allocator),
            .visiting_aur = std.StringHashMap(void).init(allocator),
            .reviewed_aur = std.StringHashMap(void).init(allocator),
            .skip_remaining_reviews = false,
        };
    }

    fn deinit(self: *InstallContext) void {
        freeStringSetKeys(self.allocator, &self.installed_aur);
        freeStringSetKeys(self.allocator, &self.visiting_aur);
        freeStringSetKeys(self.allocator, &self.reviewed_aur);
        self.installed_aur.deinit();
        self.visiting_aur.deinit();
        self.reviewed_aur.deinit();
    }
};

const SplitInstallArgs = struct {
    options: []const []const u8,
    targets: []const []const u8,
};

const AurSearchResult = struct {
    name: []const u8,
    version: []const u8,
    desc: []const u8,
};

const InstallSummary = struct {
    started_ns: i128 = 0,
    requested_targets: usize = 0,
    official_targets: usize = 0,
    aur_targets: usize = 0,
    official_installed: usize = 0,
    aur_installed: usize = 0,
    skipped_installed: usize = 0,
    failures: usize = 0,
    failed_target: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or eql(args[1], "-h") or eql(args[1], "--help")) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (eql(cmd, "-Ss")) {
        if (args.len < 3) return usageErr("missing search query");
        try searchPackages(allocator, args[2]);
        return;
    }

    if (eql(cmd, "-Si")) {
        if (args.len < 3) return usageErr("missing package name");
        try infoPackage(allocator, args[2]);
        return;
    }

    if (eql(cmd, "-S")) {
        if (args.len < 3) return usageErr("missing package name(s)");
        try installWithCompatibility(allocator, args[2..]);
        return;
    }

    if (eql(cmd, "-Syu")) {
        try systemUpgrade(allocator);
        return;
    }

    if (eql(cmd, "-Sua")) {
        try aurUpgrade(allocator);
        return;
    }

    if (eql(cmd, "-Qm")) {
        try foreignPackages(allocator);
        return;
    }

    if (args[1].len > 0 and args[1][0] == '-') {
        try pacmanPassthrough(allocator, args[1..]);
        return;
    }

    return usageErr("unknown command (tip: pacman-like flags are passed through)");
}

fn printUsage() void {
    title("melon");
    std.debug.print(
        \\  AUR helper in Zig
        \\
        \\  Commands
        \\    melon -Ss <query>        Search repos + AUR
        \\    melon -Si <package>      Show package info
        \\    melon -S <pkg...>        Install packages (repo first, AUR fallback)
        \\    melon -Syu               Full upgrade: pacman sync + AUR updates
        \\    melon -Sua               Upgrade only installed AUR packages
        \\    melon -Qm                List foreign (AUR/manual) packages
        \\    melon <pacman flags...>  Passthrough to pacman for other operations
        \\    melon -h | --help        Show help
        \\
    , .{});
}

fn usageErr(msg: []const u8) !void {
    errLine(msg);
    printUsage();
    return error.InvalidArguments;
}

fn installWithCompatibility(allocator: Allocator, raw_args: []const []const u8) !void {
    const split = try splitInstallArgs(allocator, raw_args);
    defer allocator.free(split.options);
    defer allocator.free(split.targets);

    if (split.targets.len == 0) {
        section("pacman -S passthrough (no explicit targets)");
        var pac_args = try allocator.alloc([]const u8, 1 + split.options.len);
        defer allocator.free(pac_args);
        pac_args[0] = "-S";
        @memcpy(pac_args[1..], split.options);
        const rc = try runPacmanSudo(allocator, pac_args);
        if (rc != 0) return error.PacmanInstallFailed;
        return;
    }

    var summary = InstallSummary{
        .started_ns = std.time.nanoTimestamp(),
        .requested_targets = split.targets.len,
    };
    defer printInstallSummary(summary);

    var official_count: usize = 0;
    var aur_count: usize = 0;
    for (split.targets) |target| {
        if (try isOfficialPackage(allocator, target)) official_count += 1 else aur_count += 1;
    }
    summary.official_targets = official_count;
    summary.aur_targets = aur_count;

    var official_targets = try allocator.alloc([]const u8, official_count);
    defer allocator.free(official_targets);
    var aur_targets = try allocator.alloc([]const u8, aur_count);
    defer allocator.free(aur_targets);

    var oi: usize = 0;
    var ai: usize = 0;
    for (split.targets) |target| {
        if (try isOfficialPackage(allocator, target)) {
            official_targets[oi] = target;
            oi += 1;
        } else {
            aur_targets[ai] = target;
            ai += 1;
        }
    }

    if (official_targets.len > 0) {
        section("install official targets");
        installOfficialTargets(allocator, split.options, official_targets) catch |err| {
            summary.failures += 1;
            if (summary.failed_target == null) summary.failed_target = "official-repos";
            return err;
        };
        summary.official_installed = official_targets.len;
    }

    if (aur_targets.len == 0) return;

    section("install AUR targets");
    var ctx = InstallContext.init(allocator);
    defer ctx.deinit();
    for (aur_targets) |pkg| {
        if (try isInstalledPackage(allocator, pkg)) {
            summary.skipped_installed += 1;
            continue;
        }
        warnLineFmt("using AUR for: {s}", .{pkg});
        installAurPackageRecursive(allocator, &ctx, pkg, false) catch |err| {
            summary.failures += 1;
            if (summary.failed_target == null) summary.failed_target = pkg;
            return err;
        };
        summary.aur_installed += 1;
        okLineFmt("AUR install complete: {s}", .{pkg});
    }
}

fn splitInstallArgs(allocator: Allocator, raw_args: []const []const u8) !SplitInstallArgs {
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

    var options = try allocator.alloc([]const u8, opt_count);
    var targets = try allocator.alloc([]const u8, target_count);

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

fn installOfficialTargets(allocator: Allocator, options: []const []const u8, targets: []const []const u8) !void {
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

    const rc = try runPacmanSudo(allocator, pac_args);
    if (rc != 0) return error.PacmanInstallFailed;
}

fn searchPackages(allocator: Allocator, query: []const u8) !void {
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
        return;
    }

    var shown: usize = 0;
    var aur_results = std.ArrayList(AurSearchResult){};
    defer aur_results.deinit(allocator);
    for (results.items) |entry| {
        if (entry != .object) continue;
        const name = getString(entry, "Name") orelse "<unknown>";
        const version = getString(entry, "Version") orelse "<unknown>";
        const desc = getString(entry, "Description") orelse "";
        try aur_results.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .desc = try allocator.dupe(u8, desc),
        });
        shown += 1;
        std.debug.print("{s}[{d: >2}]{s} aur/{s} {s}\n", .{ color_title, shown, color_reset, name, version });
        if (desc.len > 0) std.debug.print("     {s}{s}{s}\n", .{ color_dim, desc, color_reset });
    }
    defer {
        for (aur_results.items) |item| {
            allocator.free(item.name);
            allocator.free(item.version);
            allocator.free(item.desc);
        }
    }
    rule();
    kvInt("aur results", shown);
    try maybeHandleSearchSelection(allocator, aur_results.items);
}

fn maybeHandleSearchSelection(allocator: Allocator, aur_results: []const AurSearchResult) !void {
    if (aur_results.len == 0) return;

    std.debug.print("\n", .{});
    std.debug.print("Install from AUR results:\n", .{});
    std.debug.print("  - Enter numbers (example: 1 3 5)\n", .{});
    std.debug.print("  - Enter 'f' for fuzzy multi-select (fzf)\n", .{});
    std.debug.print("  - Press Enter to skip\n", .{});

    const choice = try promptLine(allocator, "Select packages: ");
    defer allocator.free(choice);
    if (choice.len == 0) return;

    const selected = if (eql(choice, "f"))
        try selectAurPackagesWithFzf(allocator, aur_results)
    else
        try selectAurPackagesByNumber(allocator, choice, aur_results);
    defer freeNameList(allocator, selected);

    if (selected.len == 0) {
        warnLine("no packages selected");
        return;
    }

    section("install selected AUR packages");
    try installWithCompatibility(allocator, selected);
}

fn selectAurPackagesByNumber(allocator: Allocator, raw: []const u8, aur_results: []const AurSearchResult) ![]const []const u8 {
    var picked = try allocator.alloc(bool, aur_results.len);
    defer allocator.free(picked);
    @memset(picked, false);

    var selected = std.ArrayList([]const u8){};
    errdefer {
        for (selected.items) |name| allocator.free(name);
        selected.deinit(allocator);
    }

    var tok = std.mem.tokenizeAny(u8, raw, ", \t");
    while (tok.next()) |part| {
        const idx = std.fmt.parseInt(usize, part, 10) catch {
            errLineFmt("invalid selection token: {s}", .{part});
            return error.InvalidArguments;
        };
        if (idx == 0 or idx > aur_results.len) {
            errLineFmt("selection out of range: {d}", .{idx});
            return error.InvalidArguments;
        }
        const pos = idx - 1;
        if (picked[pos]) continue;
        picked[pos] = true;
        try selected.append(allocator, try allocator.dupe(u8, aur_results[pos].name));
    }

    return selected.toOwnedSlice(allocator);
}

fn selectAurPackagesWithFzf(allocator: Allocator, aur_results: []const AurSearchResult) ![]const []const u8 {
    const fzf_ok = runStatus(allocator, null, &.{ "fzf", "--version" }) catch 1;
    if (fzf_ok != 0) {
        warnLine("fzf not found; use numeric selection or install fzf");
        return allocator.alloc([]const u8, 0);
    }

    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/melon-search-{d}.txt", .{std.time.timestamp()});
    defer allocator.free(temp_path);
    defer std.fs.deleteFileAbsolute(temp_path) catch {};

    var file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer file.close();
    for (aur_results, 0..) |item, i| {
        const line = try std.fmt.allocPrint(allocator, "{d}\t{s}\t{s}\t{s}\n", .{ i + 1, item.name, item.version, item.desc });
        try file.writeAll(line);
        allocator.free(line);
    }

    const cmd = try std.fmt.allocPrint(
        allocator,
        "fzf --multi --delimiter=$'\\t' --with-nth=2,3,4 --prompt='Select AUR package(s)> ' < {s}",
        .{temp_path},
    );
    defer allocator.free(cmd);

    const out = runCapture(allocator, &.{ "bash", "-lc", cmd }) catch {
        return allocator.alloc([]const u8, 0);
    };
    defer allocator.free(out);

    var selected = std.ArrayList([]const u8){};
    errdefer {
        for (selected.items) |name| allocator.free(name);
        selected.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitScalar(u8, trimmed, '\t');
        _ = parts.next();
        const name = parts.next() orelse continue;
        try selected.append(allocator, try allocator.dupe(u8, name));
    }

    return selected.toOwnedSlice(allocator);
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

    rule();
    kv("Repository", "aur");
    kv("Name", getString(entry, "Name") orelse "<unknown>");
    kv("Version", getString(entry, "Version") orelse "<unknown>");
    kv("Description", getString(entry, "Description") orelse "");
    kv("URL", getString(entry, "URL") orelse "");
    kv("Maintainer", getString(entry, "Maintainer") orelse "<orphan>");
    rule();
}

fn systemUpgrade(allocator: Allocator) !void {
    title("Upgrade");
    section("system packages");
    const sync_rc = try runPacmanSudo(allocator, &.{"-Syu"});
    if (sync_rc != 0) return error.PacmanUpgradeFailed;
    okLine("system packages are up to date");

    section("AUR packages");
    try aurUpgrade(allocator);
}

fn aurUpgrade(allocator: Allocator) !void {
    title("AUR upgrade");
    var ctx = InstallContext.init(allocator);
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

    var upgraded: usize = 0;
    var scanned: usize = 0;
    for (aur_list) |pkg| {
        scanned += 1;
        const info = try fetchAurInfo(allocator, pkg);
        defer info.parsed.deinit();
        if (info.entry == null) continue;
        const entry = info.entry.?;

        const latest = getString(entry, "Version") orelse continue;
        const base = getString(entry, "PackageBase") orelse getString(entry, "Name") orelse continue;

        const installed = try installedVersion(allocator, pkg);
        defer allocator.free(installed);

        const cmp = try vercmp(allocator, installed, latest);
        if (cmp < 0) {
            if (seen_bases.contains(base)) continue;
            try seen_bases.put(try allocator.dupe(u8, base), {});

            sectionFmt("upgrade aur/{s}", .{base});
            kv("package", pkg);
            kv("current", installed);
            kv("latest", latest);
            try installAurPackageRecursive(allocator, &ctx, base, false);
            upgraded += 1;
        }
    }

    rule();
    kvInt("scanned", scanned);
    kvInt("upgraded", upgraded);
}

fn foreignPackages(allocator: Allocator) !void {
    title("Foreign packages (-Qm)");
    _ = try runStreaming(allocator, &.{ "pacman", "-Qm" });
}

fn installAurPackageRecursive(allocator: Allocator, ctx: *InstallContext, pkg: []const u8, skip_if_installed: bool) anyerror!void {
    if (skip_if_installed and (try isInstalledPackage(allocator, pkg))) return;

    const repo_base = (try resolveAurPackageBase(allocator, pkg)) orelse {
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
    errdefer _ = ctx.visiting_aur.remove(repo_base);

    const now = std.time.timestamp();
    const build_dir = try std.fmt.allocPrint(allocator, "/tmp/melon-{s}-{d}", .{ repo_base, now });
    defer allocator.free(build_dir);

    const repo = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/{s}.git", .{repo_base});
    defer allocator.free(repo);

    const clone_rc = try runStreaming(allocator, &.{ "git", "clone", "--depth", "1", repo, build_dir });
    if (clone_rc != 0) return error.AurCloneFailed;

    const srcinfo = try generateSrcinfo(allocator, build_dir, repo_base);
    defer allocator.free(srcinfo);

    try resolveAurDependencies(allocator, ctx, srcinfo);
    try reviewAurPackage(allocator, ctx, build_dir, pkg, repo_base, srcinfo);

    const mk_rc = try runStreamingCwd(allocator, build_dir, &.{ "makepkg", "-si", "--noconfirm" });
    if (mk_rc != 0) return error.MakepkgFailed;

    _ = ctx.visiting_aur.remove(repo_base);
    try ctx.installed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
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
        const rc = try runPacmanSudo(allocator, &.{ "-S", "--needed", dep });
        if (rc != 0) return error.DependencyInstallFailed;
        return;
    }

    sectionFmt("install dependency from AUR: {s}", .{dep});
    try installAurPackageRecursive(allocator, ctx, dep, true);
}

fn dependencyBaseName(raw_dep: []const u8) []const u8 {
    var dep = std.mem.trim(u8, raw_dep, " \t");
    if (dep.len == 0) return "";
    if (dep[0] == '!') return "";
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

fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

fn reviewAurPackage(allocator: Allocator, ctx: *InstallContext, build_dir: []const u8, pkg: []const u8, repo_base: []const u8, srcinfo: []const u8) !void {
    if (ctx.skip_remaining_reviews) return;
    if (ctx.reviewed_aur.contains(repo_base)) return;

    try writeSrcinfoFile(allocator, build_dir, srcinfo);

    title("AUR review");
    kv("package", pkg);
    kv("repo", repo_base);
    kv("path", build_dir);
    std.debug.print("\n", .{});
    std.debug.print("  1) View PKGBUILD\n", .{});
    std.debug.print("  2) View dependency summary\n", .{});
    std.debug.print("  3) View full .SRCINFO\n", .{});
    std.debug.print("  c) Continue build\n", .{});
    std.debug.print("  a) Continue and trust all for this run\n", .{});
    std.debug.print("  q) Abort\n", .{});

    while (true) {
        const choice = try promptLine(allocator, "Choose [1/2/3/c/a/q]: ");
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
        if (eql(choice, "c")) {
            try ctx.reviewed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
            return;
        }
        if (eql(choice, "a")) {
            ctx.skip_remaining_reviews = true;
            try ctx.reviewed_aur.put(try ctx.allocator.dupe(u8, repo_base), {});
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

fn promptLine(allocator: Allocator, prompt: []const u8) ![]u8 {
    std.debug.print("{s}", .{prompt});
    var line_buf: [256]u8 = undefined;
    const line_opt = try std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEof(line_buf[0..], '\n');
    const line = line_opt orelse return allocator.dupe(u8, "");
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

const AurInfo = struct {
    parsed: std.json.Parsed(std.json.Value),
    entry: ?std.json.Value,
};

fn fetchAurInfo(allocator: Allocator, pkg: []const u8) !AurInfo {
    const enc = try urlEncode(allocator, pkg);
    defer allocator.free(enc);

    const url = try std.fmt.allocPrint(allocator, "https://aur.archlinux.org/rpc/v5/info/{s}", .{enc});
    defer allocator.free(url);

    const body = try fetchUrl(allocator, url);
    defer allocator.free(body);

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

fn installedVersion(allocator: Allocator, pkg: []const u8) ![]u8 {
    const out = try runCapture(allocator, &.{ "pacman", "-Q", pkg });
    defer allocator.free(out);
    var tok = std.mem.tokenizeAny(u8, out, " \t\r\n");
    _ = tok.next() orelse return error.InvalidPacmanOutput;
    const version = tok.next() orelse return error.InvalidPacmanOutput;
    return try allocator.dupe(u8, version);
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
    return runCapture(allocator, &.{ "curl", "-fsSL", url });
}

fn generateSrcinfo(allocator: Allocator, build_dir: []const u8, pkg: []const u8) ![]u8 {
    return runCaptureCwd(allocator, build_dir, &.{ "makepkg", "--printsrcinfo" }) catch |err| {
        errLineFmt("failed to generate .SRCINFO for aur/{s}: {s}", .{ pkg, @errorName(err) });
        return error.SrcInfoFailed;
    };
}

fn isInstalledPackage(allocator: Allocator, pkg: []const u8) !bool {
    const rc = runStatus(allocator, null, &.{ "pacman", "-Qi", pkg }) catch return false;
    return rc == 0;
}

fn isOfficialPackage(allocator: Allocator, pkg: []const u8) !bool {
    const rc = runStatus(allocator, null, &.{ "pacman", "-Si", pkg }) catch return false;
    return rc == 0;
}

fn pacmanPassthrough(allocator: Allocator, pacman_args: []const []const u8) !void {
    const rc = if (needsRootPacman(pacman_args))
        try runPacmanSudo(allocator, pacman_args)
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

fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
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

fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (eql(arg, needle)) return true;
    }
    return false;
}

fn isUnreserved(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn runStreaming(allocator: Allocator, argv: []const []const u8) !u8 {
    return runStreamingCwd(allocator, null, argv);
}

fn runStreamingCwd(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !u8 {
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

fn runStatus(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !u8 {
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

fn runCapture(allocator: Allocator, argv: []const []const u8) ![]u8 {
    return runCaptureCwd(allocator, null, argv);
}

fn runCaptureCwd(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
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

fn freeStringSetKeys(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn printInstallSummary(summary: InstallSummary) void {
    if (summary.started_ns == 0) return;
    const elapsed_ns = std.time.nanoTimestamp() - summary.started_ns;
    const elapsed_ms: i128 = @divFloor(elapsed_ns, std.time.ns_per_ms);

    std.debug.print("\n{s}Install summary{s}\n", .{ color_ok, color_reset });
    rule();
    kvInt("requested", summary.requested_targets);
    kvInt("official targets", summary.official_targets);
    kvInt("aur targets", summary.aur_targets);
    kvInt("official done", summary.official_installed);
    kvInt("aur done", summary.aur_installed);
    kvInt("skipped", summary.skipped_installed);
    kvInt("failures", summary.failures);
    std.debug.print("  {s: <14} : {d}\n", .{ "elapsed ms", elapsed_ms });
    if (summary.failed_target) |target| {
        std.debug.print("  {s: <14} : melon -S {s}\n", .{ "retry", target });
    }
    if (summary.failures > 0) {
        std.debug.print("  {s: <14} : check failure logs above\n", .{"next"});
    } else if (summary.requested_targets > 0) {
        std.debug.print("  {s: <14} : melon -Qm\n", .{"next"});
    }
    rule();
}

fn title(msg: []const u8) void {
    std.debug.print("\n{s}==> {s}{s}\n", .{ color_title, msg, color_reset });
}

fn section(msg: []const u8) void {
    std.debug.print("{s}:: {s}{s}\n", .{ color_dim, msg, color_reset });
}

fn sectionFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}:: ", .{color_dim});
    std.debug.print(fmt, args);
    std.debug.print("{s}\n", .{color_reset});
}

fn rule() void {
    std.debug.print("{s}----------------------------------------{s}\n", .{ color_dim, color_reset });
}

fn kv(key: []const u8, value: []const u8) void {
    std.debug.print("  {s: <14} : {s}\n", .{ key, value });
}

fn kvInt(key: []const u8, value: usize) void {
    std.debug.print("  {s: <14} : {d}\n", .{ key, value });
}

fn okLine(msg: []const u8) void {
    std.debug.print("{s}[ok]{s} {s}\n", .{ color_ok, color_reset, msg });
}

fn okLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[ok]{s} ", .{ color_ok, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn warnLine(msg: []const u8) void {
    std.debug.print("{s}[warn]{s} {s}\n", .{ color_warn, color_reset, msg });
}

fn warnLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[warn]{s} ", .{ color_warn, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

fn errLine(msg: []const u8) void {
    std.debug.print("{s}[error]{s} {s}\n", .{ color_err, color_reset, msg });
}

fn errLineFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[error]{s} ", .{ color_err, color_reset });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}
