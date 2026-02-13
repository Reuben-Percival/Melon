# Paru Parity Plan

This file tracks parity work between `melon` and `paru`.

## Implemented

- [x] Search official repos + AUR (`-Ss`)
- [x] Package info with AUR fallback (`-Si`)
- [x] Install with official repo first, AUR fallback (`-S`)
- [x] Mandatory `PKGBUILD` review gate
- [x] Mandatory `.SRCINFO` + dependency review gate

## Core Package Management

- [ ] Full pacman flag passthrough compatibility
- [ ] `-Syu` full system upgrade flow
- [ ] `-Sua` AUR-only upgrade flow
- [ ] Batch install transaction planning and conflict handling
- [ ] Robust exit code behavior matching pacman/paru expectations

## AUR Features

- [ ] Recursive AUR dependency resolution
- [ ] Split package support
- [ ] Devel package detection and update policy
- [ ] Local clone cache and reuse
- [ ] Build dir retention policy and cleanup options
- [ ] AUR comments/rating display

## Review and Security

- [ ] PKGBUILD diff against previously reviewed state
- [ ] Source URL and checksum review prompt
- [ ] GPG key handling and signature verification surfacing
- [ ] Interactive approve/reject per package in batch transactions

## Performance

- [ ] Parallel downloads/clones/build scheduling
- [ ] AUR RPC response caching
- [ ] Faster resolver strategy for large dependency graphs

## UX and Config

- [ ] Config file parity (`~/.config/paru/paru.conf` analog)
- [ ] Pacman color/output integration
- [ ] News display and manual intervention prompts
- [ ] Interactive menu mode and package selection
- [ ] Completion scripts (bash/zsh/fish)

## Maintenance

- [ ] Integration tests with mocked pacman/AUR backends
- [ ] Packaging variants (`melon`, `melon-git`)
- [ ] Release automation and signed artifacts
