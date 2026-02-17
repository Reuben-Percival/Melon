# Melon

`melon` is a Zig-based AUR helper for Arch Linux focused on explicit PKGBUILD review, resilient upgrades, and predictable terminal output.

## Status

- Development status: active.
- Packaging model: rolling git source (`PKGBUILD` builds from `https://github.com/Reuben-Percival/Melon.git`).
- `pkgver` format: `r<rev>.<hash>` (git revision count + short commit hash).

## Why Melon

- Review-first AUR workflow with required security check before build continuation.
- Repo-first behavior with AUR fallback when appropriate.
- Split-package-aware dependency solving (`pkgname`/`provides` from `.SRCINFO`).
- Structured failure context and resumable failed package sets.
- Shell completions for bash, zsh, and fish.

## Feature Highlights

### Package operations

- Unified search and inspection:
  - `melon -Ss <query>` searches official repositories and AUR in one flow.
  - `-Ss` supports interactive AUR install selection: numbers/ranges/names (`1 3 5-7 ripgrep-git`), `a`/`all`, deselect with `^` (for example `a ^2 ^foo-git`), or fuzzy multi-select via `fzf` (`f`, with preview pane).
  - `melon -Si <package>` resolves package metadata with repo-first, AUR fallback behavior.
- Mixed-target installs:
  - `melon -S [options] <targets...>` splits repo and AUR targets automatically.
  - `melon -S --targets-file <path> [targets...]` reads additional package targets from file (whitespace/comma separated, `#` comments supported).
  - Supports shared install options such as `--needed` and `--noconfirm`.
  - Prints a post-install summary with requested/installed/skipped/failed counts and retry hint.
- Upgrade workflows:
  - `melon -Syu` performs full system upgrade plus AUR upgrade pass.
  - `melon -Sua` upgrades only installed AUR/foreign packages.
- Maintenance and utility operations:
  - `melon -Qm` lists foreign packages.
  - `melon -Cbd` prunes unused dependency packages until no orphans remain.
  - `melon -G <pkg...>` clones AUR repositories for offline/manual inspection.
  - `melon <pacman flags...>` passes through non-overridden pacman operations.

### Review and safety

Before each AUR build (unless explicitly bypassed), Melon requires an interactive review step:

- `1`: view syntax-highlighted `PKGBUILD`.
- `2`: view dependency summary.
- `3`: view full `.SRCINFO`.
- `4`: view source diff since last reviewed commit (`PKGBUILD`, `.install`, patches, and other tracked build files).
- `5`: run PKGBUILD security check (capabilities, risky markers, unsafe makepkg flags such as `!strip`, `!check`, `!fortify`).
- `6`: view source/checksum/signature summary (`source`, checksum arrays, `validpgpkeys`).
- `c`: continue build.
- `a`: continue and trust remaining packages for the current run.
- `s`: skip this package and continue the run.
- `q`: abort.

`5` (security check) is required before `c`/`a` for that prompt.

### Resilience behavior

- Dependency solver:
  - Recursively resolves `depends`, `makedepends`, and `checkdepends`.
  - Uses split-package-aware solving via `.SRCINFO` `pkgname`/`provides`.
  - Avoids false dependency cycles inside a single `pkgbase`.
  - Supports split package workflows:
    - builds a package base once per run, then reuses artifacts for additional split outputs
    - installs split outputs independently (e.g. one output without force-installing sibling outputs)
    - handles split outputs that depend on other outputs from the same `pkgbase`
- Failure-tolerant execution:
  - `-S` attempts AUR fallback for requested targets when repo install fails.
  - Dependency installation can fall back from repo packages to AUR providers.
  - `-Syu` continues to AUR upgrade phase even if repo sync/upgrade fails.
- Network robustness:
  - Retry/backoff for AUR RPC calls (`curl`).
  - Retry/backoff for AUR git synchronization (`clone`/`fetch`).
- Persistent state and recovery:
  - Caches AUR info and AUR git repositories.
  - Stores reviewed commit snapshots for PKGBUILD diffing.
  - Tracks failed package sets for `--resume-failed`.

## Runtime Options

- `-h`, `--help`: show help.
- `--version`: show version.
- `--dry-run`: print mutating actions without executing them.
- `--json`: machine-readable summaries for key flows.
- `--assume-reviewed`: skip interactive review prompts.
- `--i-know-what-im-doing`: required with `--assume-reviewed` in non-interactive runs.
- `--cache-info`: show cache path and size.
- `--cache-clean`: clear Melon cache.
- `--resume-failed`: retry the last failed package set.
- `--bottomup` / `--topdown`: control AUR search ordering.
- `--[no]pgpfetch`: import PGP keys from PKGBUILDs when needed.
- `--[no]useask`: use pacman's ask flag for conflict handling.
- `--[no]savechanges`: commit PKGBUILD changes made during review.
- `--[no]newsonupgrade`: show Arch news during sysupgrade.
- `--[no]combinedupgrade`: combine refresh and repo/AUR upgrade.
- `--[no]batchinstall`: build multiple AUR packages and install together.
- `--[no]provides`: search provider matches.
- `--[no]devel`: include development packages during sysupgrade checks.
- `--[no]installdebug`: install debug companion packages when available.
- `--[no]sudoloop`: keep sudo credentials warm in background.
- `--[no]chroot`: build in chroot.
- `--[no]failfast`: stop at first AUR build failure.
- `--[no]keepsrc`: keep `src/` and `pkg/` after build.
- `--[no]sign`: sign packages with GPG.
- `--[no]signdb`: sign package databases with GPG.
- `--[no]localrepo`: publish built packages into a local repo.
- `--rebuild`: force matching targets to rebuild.

## Installation

### Build from source

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/melon --help
```

### Install locally (binary + shell completions)

```bash
./install.sh
```

Environment overrides:

- `PREFIX` (default: `/usr/local`)
- `BIN_NAME` (default: `melon`)
- `NO_SUDO=1` (disable sudo fallback)
- `SKIP_BUILD=1` (install existing `zig-out/bin/melon`)

Uninstall binary and installed shell completions:

```bash
./uninstall.sh
```

## Shell Completions

Completions are shipped in `completions/` for:

- bash: `completions/melon.bash`
- zsh: `completions/melon.zsh`
- fish: `completions/melon.fish`

`install.sh` installs them into standard completion paths under `PREFIX`.

## Build and Test

```bash
zig build
zig build test
```

If Zig global cache is not writable:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test
```

## Quick Examples

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

## Runtime Dependencies

- `pacman`
- `sudo` (for repo installs/upgrades)
- `curl`
- `git`
- `makepkg`
- `vercmp` (from pacman)

## Repository Layout

- `src/main.zig`: orchestration, review flow, install/upgrade pipeline.
- `src/parsing.zig`: CLI and dependency parsing.
- `src/process.zig`: process execution helpers.
- `src/ui.zig`: terminal UI helpers.
- `src/reporting.zig`: run summaries and failure context.
- `src/json_helpers.zig`: shared JSON field extraction helpers.

## CI and Releases

- CI validates:
  - workflow syntax (`actionlint`)
  - Zig formatting (`zig fmt --check`)
  - shell scripts (`bash -n` + `shellcheck`)
  - build/test across Zig `0.14.1` and `0.15.2`
  - install/uninstall smoke paths
  - integration logic harness
  - Arch Linux container build/test
- Tagged releases (`v*`) publish Linux `x86_64` binary artifacts and SHA-256 checksums.

## Validated Scenarios

Automated fixture-based integration harness:

- Script: `scripts/integration-aur.sh`
- CI job: `Integration logic (fixture harness)` in `.github/workflows/ci.yml`
- Validates:
  - split outputs from one package base are built once and installed independently (`nxproxy` + `nxagent` topology)
  - split outputs that depend on siblings from the same package base do not trigger false recursion/rebuild (`samsung-unified-driver` topology)
  - non-local dependencies are still resolved normally (fixture `cups` repo dependency)

Run locally:

```bash
./scripts/integration-aur.sh
```

Manual live-AUR smoke validation (performed on February 16, 2026):

- `nxproxy` + `nxagent` (`PackageBase=nx`) reuse/build-selection behavior.
- `samsung-unified-driver` split-output selection behavior.
