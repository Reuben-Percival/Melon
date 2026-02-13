pkgname=melon
pkgver=0.1.0
pkgrel=1
pkgdesc="Minimal AUR helper written in Zig with mandatory PKGBUILD review"
arch=('x86_64')
url="https://github.com/Reuben-Percival/Melon"
license=('MIT')
depends=('pacman' 'curl' 'git' 'sudo')
makedepends=('zig')
provides=('melon')
conflicts=('melon-git')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
  cd "$srcdir/Melon-$pkgver"
  zig build -Doptimize=ReleaseSafe
}

check() {
  cd "$srcdir/Melon-$pkgver"
  zig build
}

package() {
  cd "$srcdir/Melon-$pkgver"
  install -Dm755 "zig-out/bin/melon" "$pkgdir/usr/bin/melon"
}
