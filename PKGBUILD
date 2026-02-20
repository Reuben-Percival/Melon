# Maintainer: Reuben Percival <reuben at p-rvl dot com>
pkgname=melon
pkgver=r115.6acbc01
pkgrel=1
pkgdesc="Minimal AUR helper written in Zig with mandatory PKGBUILD review"
arch=('x86_64' 'aarch64' 'armv7h' 'riscv64')
url="https://github.com/Reuben-Percival/Melon"
license=('GPL2')
depends=('pacman' 'curl' 'git' 'sudo')
makedepends=('zig' 'git')
optdepends=('fzf: for fuzzy package selection')
provides=('melon')
conflicts=('melon-git')
source=("git+$url.git")
sha256sums=('SKIP')

pkgver() {
  cd "$pkgname"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

build() {
  cd "$pkgname"
  # Standard Arch build flags mapping (best effort for Zig)
  zig build \
    -Doptimize=ReleaseSafe \
    -Dversion="$pkgver" \
    --prefix usr/
}

check() {
  cd "$pkgname"
  zig build test -Dversion="$pkgver"
}

package() {
  cd "$pkgname"
  
  # Install binary
  install -Dm755 "zig-out/bin/melon" "$pkgdir/usr/bin/melon"
  
  # Install shell completions
  install -Dm644 "completions/melon.bash" "$pkgdir/usr/share/bash-completion/completions/melon"
  install -Dm644 "completions/melon.zsh"  "$pkgdir/usr/share/zsh/site-functions/_melon"
  install -Dm644 "completions/melon.fish" "$pkgdir/usr/share/fish/vendor_completions.d/melon.fish"
  
  # Install license
  install -Dm644 "LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  
  # Install documentation
  install -Dm644 "README.md" "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 "wiki.md" "$pkgdir/usr/share/doc/$pkgname/wiki.md"
}
