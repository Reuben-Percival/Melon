# Paru Parity Plan

This file tracks parity work between `melon` and `paru`.

## Implemented

- [x] Search official repos + AUR (`-Ss`)
- [x] AUR search with votes/popularity display
- [x] Interactive search selection (install by number)
- [x] Local package search (`-Qs`)
- [x] Package info with AUR fallback (`-Si`)
- [x] AUR info enrichment in `-Si` (votes/popularity/comments/out-of-date + comments URL)
- [x] Install with official repo first, AUR fallback (`-S`)
- [x] `-Syu` full system upgrade flow
- [x] `-Sua` AUR-only upgrade flow
- [x] `-Qu` / `-Qua` update checking without installing
- [x] `-Qm` list foreign packages
- [x] `-G` clone AUR repos
- [x] `-Sc` / `-Scc` cache management
- [x] Batch install transaction planning and conflict handling
- [x] Mandatory `PKGBUILD` review gate
- [x] Mandatory `.SRCINFO` + dependency review gate
- [x] PKGBUILD diff against previously reviewed state
- [x] PKGBUILD security check
- [x] Source/checksum/signature review summary prompt
- [x] GPG key and signature verification surfacing during review/build
- [x] Interactive per-package reject/skip in batch-style runs
- [x] Recursive AUR dependency resolution
- [x] Split package support (build-once/install-selected outputs)
- [x] Devel package detection and update policy (`-git`, `-svn`, etc.)
- [x] Local clone cache and reuse
- [x] AUR RPC response caching (memory + disk)
- [x] Retry/backoff for network operations
- [x] Parallel prefetch of AUR metadata
- [x] Parallel AUR clone scheduling for `-G`
- [x] Resolver memoization for dependency/official checks on large graphs
- [x] Config file parity flags (all `--[no]` toggle flags)
- [x] `--version` flag
- [x] `--color=auto|always|never` and `NO_COLOR` env support
- [x] `--bottomup` / `--topdown` sort order
- [x] `--sudoloop` background thread to prevent sudo timeout
- [x] Optional dependencies display after dependency resolution
- [x] Provider selection (multiple AUR providers for a dependency)
- [x] Arch news display (`--newsonupgrade`)
- [x] JSON output mode for all commands
- [x] Dry-run mode
- [x] Failure report with step/package/command/hint
- [x] End-of-run summary card
- [x] `--resume-failed` retry support
- [x] Chroot build support
- [x] Local repo support
- [x] GPG signing (packages and databases)
- [x] Build dir retention toggle (`--[no]keepsrc`)
- [x] Shell completion scripts (bash, zsh, fish)
- [x] Pacman flag passthrough
- [x] Zig build script compatibility across Zig versions
- [x] `--rebuild` flag support
- [x] AUR Out-of-Date status display in search results
- [x] Integration tests with mocked pacman/AUR backends (fixture harness + CI)
- [x] Release automation (tagged builds + published assets + checksums)

## Remaining Work

### Core Package Management

- [x] Full pacman flag passthrough compatibility (improved root-op detection across combined/long flags)
- [x] Robust passthrough exit code propagation (non-zero pacman codes are preserved)

### AUR Features

- [x] AUR comments/rating display

### Review and Security

- [x] Source URL and checksum review prompt
- [x] GPG key handling and signature verification surfacing
- [x] Interactive approve/reject per package in batch transactions

### Performance

- [x] Parallel downloads/clones/build scheduling
- [x] Faster resolver strategy for large dependency graphs

### UX and Config

- [ ] Config file (`~/.config/melon/melon.conf`)
- [x] Interactive menu mode and package selection (fuzzy)

### Maintenance

- [ ] Packaging variants (`melon`, `melon-git`)
- [ ] Signed release artifacts
