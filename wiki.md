# Melon Wiki

## Overview

Melon is a Zig-based AUR helper focused on:

- explicit PKGBUILD review before build/install
- resilient repo/AUR upgrade and install flows
- deterministic output and failure context

Primary reference remains `README.md`. This wiki provides operational notes and quick troubleshooting.

## Core Flows

- `-S`: mixed-target install (repo-first + AUR fallback).
- `-S` post-run summary reports requested/installed/skipped/failed counts with retry hint.
- `-Syu`: full system upgrade plus AUR upgrade pass.
- `-Sua`: AUR/foreign-only upgrade.
- `-Ss`: supports interactive AUR install picks by number/range/name (`1 3 5-7 ripgrep-git`), `a`/`all` for all, `^` to deselect (for example `a ^2 ^foo-git`), plus fuzzy multi-select when `fzf` is available (with preview pane).
- `-S --targets-file <path>`: batch install packages from file (blank lines and `#` comments ignored).
- `-Qu`/`-Qua`: update check without install.
- `-G`: clone AUR repos (parallelized when cloning multiple targets).
- pacman passthrough: non-overridden pacman flags are forwarded with root-op detection and exit-code propagation.

## AUR Review Menu

For each AUR build (unless `--assume-reviewed`):

- `1`: show `PKGBUILD`
- `2`: show dependency lines
- `3`: show `.SRCINFO`
- `4`: show tracked source diff since reviewed commit
- `5`: run PKGBUILD security check (required before continue)
- `6`: show source/checksum/signature summary
- `c`: continue current package
- `a`: continue and trust remaining packages this run
- `s`: skip current package and continue
- `q`: abort

## Security Notes

- `makepkg --verifysource` is run when `--pgpfetch` is enabled.
- On signature verification failure, Melon surfaces relevant `validpgpkeys`/signature hints.
- Security check reports risky command markers and makepkg hardening flags, plus checksum/signature indicators.

## Build and Test

```bash
zig build
zig build test
./scripts/integration-aur.sh
```

If needed:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build
```

## CI Coverage

CI includes:

- workflow lint (`actionlint`)
- Zig fmt check
- shell script lint (`bash -n`, `shellcheck`)
- build/test matrix on Zig `0.14.1` and `0.15.2`
- install/uninstall smoke test
- integration fixture harness
- Arch Linux container build/test

## Troubleshooting

### Build fails with Zig API differences

If CI fails on one Zig version only:

- verify compatibility shims in `src/ui.zig` and `src/main.zig` for stdin/TTY handling
- run local checks against both versions where possible

### Permission issues on install

- use `NO_SUDO=1` with writable `PREFIX`
- otherwise install/uninstall scripts fall back to `sudo`

### Retry failed package sets

```bash
melon --resume-failed
```

### Inspect cache state

```bash
melon --cache-info
melon --cache-clean
```
