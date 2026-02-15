# Melon

`melon` is a Zig-based AUR helper for Arch Linux focused on explicit review, resilient upgrades, and clear terminal UX.

## Project status

- Active development.
- Current packaging model: rolling git source (`PKGBUILD` builds from `https://github.com/Reuben-Percival/Melon.git`).
- `pkgver` is derived from git revision count + commit hash (`r<rev>.<hash>`).

## Core commands

- `melon -Ss <query>`: search official repos and AUR.
- `melon -Si <package>`: package info (repo first, AUR fallback).
- `melon -S [options] <targets...>`: install targets (repo first, AUR fallback).
- `melon -Syu`: full system upgrade + AUR upgrades (best-effort AUR continuation if repo sync fails).
- `melon -Sua`: upgrade only installed AUR/foreign packages.
- `melon -Cbd`: prune all unused dependency packages (`pacman -Qtdq` + `pacman -Rns`, repeated until clean).
- `melon -Qm`: list foreign packages.
- `melon <pacman flags...>`: passthrough for non-overridden pacman operations.

## Runtime options

- `-h`, `--help`: show command and flag help.
- `--dry-run`: print mutating actions without executing them.
- `--json`: machine-readable summaries for key flows.
- `--assume-reviewed`: skip interactive review prompts.
- `--i-know-what-im-doing`: required with `--assume-reviewed` in non-interactive runs.
- `--cache-info`: show cache location/size.
- `--cache-clean`: clear melon cache state.
- `--resume-failed`: retry last failed package set.
- `--[no]pgpfetch`: prompt to import PGP keys from PKGBUILDs.
- `--[no]useask`: automatically resolve conflicts using pacman's ask flag.
- `--[no]savechanges`: commit changes to PKGBUILDs made during review.
- `--[no]newsonupgrade`: print new news during sysupgrade.
- `--[no]combinedupgrade`: refresh then perform the repo and AUR upgrade together.
- `--[no]batchinstall`: build multiple AUR packages then install them together.
- `--[no]provides`: look for matching providers when searching for packages.
- `--[no]devel`: check development packages during sysupgrade.
- `--[no]installdebug`: also install debug packages when a package provides them.
- `--[no]sudoloop`: loop sudo calls in the background to avoid timeout.
- `--[no]chroot`: build packages in a chroot.
- `--[no]failfast`: exit as soon as building an AUR package fails.
- `--[no]keepsrc`: keep `src/` and `pkg/` dirs after building packages.
- `--[no]sign`: sign packages with gpg.
- `--[no]signdb`: sign databases with gpg.
- `--[no]localrepo`: build packages into a local repo.

## AUR review flow

Before each AUR build, melon requires a review step (unless explicitly bypassed):

- `1` View raw `PKGBUILD` (classic pager view).
- `2` View dependency summary.
- `3` View full `.SRCINFO`.
- `4` View `PKGBUILD` diff since last reviewed commit (when available).
- `5` Run PKGBUILD security check (capability/risk summary).
- `c` Continue build.
- `a` Continue and trust remaining builds for this run.
- `q` Abort.

Security check (`5`) is required before `c`/`a` for that review prompt.

## Resilience and safety behavior

- Recursive AUR dependency resolution (`depends`, `makedepends`, `checkdepends`).
- Best-effort fallback when official repo operations fail:
  - `-S`: attempts AUR fallback for requested targets.
  - dependency installs: tries AUR if repo dependency install fails.
  - `-Syu`: continues to AUR phase even if repo sync fails.
- Retry/backoff for AUR RPC (`curl`) and AUR git sync (`clone`/`fetch`).
- Persistent cache:
  - AUR info cache
  - AUR git repo cache
  - reviewed commit snapshots
  - failed package set tracking
- Structured failure report with step/package/command/hint.

## UX output

- Phase/progress lines for install/upgrade flow.
- End-of-run summary card:
  - official/AUR targets
  - AUR installed/upgraded
  - failures
  - cache hits/misses
  - elapsed time

## Build and test

```bash
zig build
zig build test
```

If Zig global cache is not writable:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test
```

## Quick run examples

```bash
zig build run -- -Ss neovim
zig build run -- -Si paru
zig build run -- -S rustfetch-git
zig build run -- -S --needed --noconfirm ripgrep paru
zig build run -- -Syu
zig build run -- -Sua
zig build run -- -Qm
zig build run -- --dry-run -Syu
zig build run -- --json -Sua
zig build run -- --cache-info
zig build run -- --resume-failed
zig build run -- -Cbd
```

## Runtime dependencies

- `pacman`
- `sudo` (for repo installs/upgrades)
- `curl`
- `git`
- `makepkg`
- `vercmp` (from pacman)

## Source layout

- `src/main.zig`: orchestration, review flow, UX/reporting.
- `src/parsing.zig`: CLI/dependency parsing.
- `src/process.zig`: process execution helpers.
- `src/ui.zig`: terminal UI helpers.

## Packaging and release

- `PKGBUILD` is included in repo and builds from git source.
- CI runs `zig build` and `zig build test`.
- Tagged releases (`v*`) publish Linux x86_64 binary artifacts.
