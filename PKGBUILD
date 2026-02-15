pkgname=melon
pkgver=r0.0a1b2c3
pkgrel=1
pkgdesc="Minimal AUR helper written in Zig with mandatory PKGBUILD review"
arch=('x86_64')
url="https://github.com/Reuben-Percival/Melon"
license=('Gplv2')
depends=('pacman' 'curl' 'git' 'sudo')
makedepends=('zig')
provides=('melon')
conflicts=('melon-git')
source=("git+$url.git")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/Melon"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

build() {
  cd "$srcdir/Melon"
  zig build -Doptimize=ReleaseSafe -Dversion="$pkgver"
}

check() {
  cd "$srcdir/Melon"
  zig build test -Dversion="$pkgver"
}

package() {
  cd "$srcdir/Melon"
  NO_SUDO=1 SKIP_BUILD=1 PREFIX="$pkgdir/usr" BIN_NAME="melon" ./install.sh
}
