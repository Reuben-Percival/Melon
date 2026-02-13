# melon

`melon` is an AUR helper written in Zig.

## Features

- `-Ss <query>`: search official repos (`pacman -Ss`) and AUR (RPC).
- `-Si <package>`: package info from official repos, then AUR fallback.
- `-S <pkg...>`: install from official repos, then fallback to AUR via `git clone` + `makepkg -si`.
- `-S [options] <targets...>`: pacman-compatible `-S` parsing (options + targets). Official targets are installed in one pacman transaction; unresolved targets are handled via AUR.
- `-Syu`: run full system upgrade and then upgrade installed AUR packages.
- `-Sua`: upgrade only installed AUR/foreign packages.
- `-Qm`: list foreign packages (same as `pacman -Qm`).
- `melon <pacman flags...>`: passthrough for pacman operations not explicitly overridden.
- Recursive AUR dependency resolution for `depends`, `makedepends`, and `checkdepends`.
- Faster internal checks (quiet package detection, dependency satisfaction via `pacman -T`, shallow AUR clones).
- Cleaner styled output with sections, status markers, and colored summaries.
- Mandatory AUR review gates:
  - Before each AUR build, an interactive review menu lets you:
    - view `PKGBUILD`
    - view dependency summary
    - view full `.SRCINFO`
    - continue, continue-and-trust-remaining for this run, or abort

## Build

```bash
zig build
```

If your global Zig cache path is not writable:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build
```

## Run

```bash
zig build run -- -Ss neovim
zig build run -- -Si yay
zig build run -- -S paru
zig build run -- -S --needed --noconfirm ripgrep paru
zig build run -- -Syu
zig build run -- -Sua
zig build run -- -Qm
zig build run -- -Rns somepkg
```

## Runtime dependencies

- `pacman`
- `sudo` (for official repo installs)
- `curl`
- `git`
- `makepkg`
- `vercmp` (from `pacman`)

## Packaging

A `PKGBUILD` for `melon` is included in this repo.

Release packaging expects tags in the form `v<version>` (example: `v0.1.0`).
