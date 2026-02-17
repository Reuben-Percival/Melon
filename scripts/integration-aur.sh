#!/usr/bin/env bash
set -euo pipefail

ROOT="${MELON_IT_ROOT:-/tmp/melon-it-fixture}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MELON_IT_BIN:-$WORKDIR/zig-out/bin/melon}"

MOCK_BIN="$ROOT/mockbin"
LOG_DIR="$ROOT/logs"
STATE_DIR="$ROOT/state"
FIXTURE_REPOS="$ROOT/fixture-repos"

mkdir -p "$MOCK_BIN" "$LOG_DIR" "$STATE_DIR" "$FIXTURE_REPOS"
mkdir -p "$ROOT/cache" "$ROOT/home"

if [[ ! -x "$BIN" ]]; then
  (cd "$WORKDIR" && zig build -Doptimize=ReleaseSafe)
fi

make_fixture_repo() {
  local base="$1"
  local srcinfo="$2"
  local dir="$FIXTURE_REPOS/$base"
  rm -rf "$dir"
  mkdir -p "$dir"
  cat > "$dir/PKGBUILD" <<'PKG'
pkgname=placeholder
pkgver=1
pkgrel=1
pkgdesc="fixture"
arch=('x86_64')
license=('custom')
source=()
sha256sums=()
PKG
  printf '%s\n' "$srcinfo" > "$dir/.SRCINFO"
  cat > "$dir/$base.install" <<'INST'
post_install() { :; }
INST
  cat > "$dir/fix.patch" <<'PATCH'
--- a/file
+++ b/file
@@ -1 +1 @@
-a
+b
PATCH

  (
    cd "$dir"
    /usr/bin/git init -q
    /usr/bin/git config user.name melon-it
    /usr/bin/git config user.email melon-it@example.invalid
    /usr/bin/git add PKGBUILD .SRCINFO "$base.install" fix.patch
    /usr/bin/git commit -q -m "fixture: $base"
  )
}

make_fixture_repo "nx" "
pkgbase = nx
pkgname = nxproxy
pkgname = nxagent
"

make_fixture_repo "samsung-unified-driver" "
pkgbase = samsung-unified-driver
pkgname = samsung-unified-driver
depends = samsung-unified-driver-printer
depends = samsung-unified-driver-scanner
depends = cups
pkgname = samsung-unified-driver-printer
pkgname = samsung-unified-driver-scanner
"

cat > "$MOCK_BIN/sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
SH

cat > "$MOCK_BIN/vercmp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 0
SH

cat > "$MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
if [[ "$url" == *"/rpc/v5/info/"* ]]; then
  pkg="${url##*/}"
  case "$pkg" in
    nxproxy|nxagent)
      printf '{"resultcount":1,"results":[{"Name":"%s","PackageBase":"nx","Version":"1.0-1"}],"type":"multiinfo","version":5}\n' "$pkg"
      exit 0
      ;;
    samsung-unified-driver)
      printf '{"resultcount":1,"results":[{"Name":"samsung-unified-driver","PackageBase":"samsung-unified-driver","Version":"1.0-1"}],"type":"multiinfo","version":5}\n'
      exit 0
      ;;
  esac
fi
printf '{"resultcount":0,"results":[],"type":"multiinfo","version":5}\n'
SH

cat > "$MOCK_BIN/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "clone" ]]; then
  base_url=""
  dest=""
  for arg in "$@"; do
    if [[ "$arg" == https://aur.archlinux.org/*.git ]]; then
      base_url="$arg"
    fi
  done
  dest="${@: -1}"
  if [[ -n "$base_url" ]]; then
    base="$(basename "$base_url" .git)"
    src="${MELON_IT_FIXTURE_REPOS:?}/$base"
    exec /usr/bin/git clone --depth 1 "$src" "$dest"
  fi
fi
exec /usr/bin/git "$@"
SH

cat > "$MOCK_BIN/pacman" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="${MELON_IT_LOG_DIR:?}"
STATE_DIR="${MELON_IT_STATE_DIR:?}"
MODE="${MELON_IT_MODE:-satisfied}"
INSTALLED_FILE="$STATE_DIR/installed_pkgs.txt"
mkdir -p "$STATE_DIR"
touch "$INSTALLED_FILE"

extract_pkg_name() {
  local file="$1"
  local base stem
  base="$(basename "$file")"
  stem="${base%%.pkg.tar*}"
  stem="${stem%-*}" # arch
  stem="${stem%-*}" # rel
  stem="${stem%-*}" # ver
  printf '%s\n' "$stem"
}

last_non_flag_arg() {
  local out=""
  for a in "$@"; do
    [[ "$a" == -* ]] && continue
    out="$a"
  done
  printf '%s\n' "$out"
}

is_aur_target() {
  case "$1" in
    nxproxy|nxagent|samsung-unified-driver|samsung-unified-driver-printer|samsung-unified-driver-scanner) return 0 ;;
    *) return 1 ;;
  esac
}

cmd="${1:-}"
shift || true

case "$cmd" in
  -Qi)
    pkg="$(last_non_flag_arg "$@")"
    if grep -Fxq "$pkg" "$INSTALLED_FILE"; then
      echo "Name            : $pkg"
      exit 0
    fi
    exit 1
    ;;
  -T)
    dep="$(last_non_flag_arg "$@")"
    if [[ "$MODE" == "unsatisfied" ]]; then
      echo "$dep"
      exit 0
    fi
    exit 0
    ;;
  -Si|-Sp)
    pkg="$(last_non_flag_arg "$@")"
    if is_aur_target "$pkg"; then exit 1; fi
    exit 0
    ;;
  -S)
    echo "PACMAN_S $*" >> "$LOG_DIR/pacman.log"
    exit 0
    ;;
  -U)
    echo "PACMAN_U $*" >> "$LOG_DIR/pacman.log"
    for f in "$@"; do
      [[ "$f" == -* ]] && continue
      n="$(extract_pkg_name "$f")"
      [[ -n "$n" ]] && echo "$n" >> "$INSTALLED_FILE"
    done
    exit 0
    ;;
  -Qm|-Qq|-Qtdq|-Rns)
    exit 0
    ;;
  *)
    echo "PACMAN_OTHER $cmd $*" >> "$LOG_DIR/pacman.log"
    exit 0
    ;;
esac
SH

cat > "$MOCK_BIN/makepkg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="${MELON_IT_LOG_DIR:?}"

if [[ "$*" == *"--printsrcinfo"* ]]; then
  [[ -f .SRCINFO ]] || { echo "missing .SRCINFO" >&2; exit 1; }
  cat .SRCINFO
  exit 0
fi

if [[ "$*" == *"--verifysource"* ]]; then
  exit 0
fi

# Normal package build path (supports both legacy --noinstall and default build invocation).
if [[ "$*" == *"-s"* || "$*" == *"--syncdeps"* || "$*" == *"--noconfirm"* || "$*" == *"--noinstall"* ]]; then
  echo "MAKEPKG_BUILD $(basename "$PWD")" >> "$LOG_DIR/makepkg.log"
  mapfile -t pkgs < <(awk -F'=' '/^pkgname = /{gsub(/^ +| +$/, "", $2); print $2}' .SRCINFO | sort -u)
  [[ "${#pkgs[@]}" -gt 0 ]] || { echo "no pkgname entries" >&2; exit 1; }
  for p in "${pkgs[@]}"; do
    : > "$PWD/${p}-1.0-1-x86_64.pkg.tar.zst"
  done
  exit 0
fi

echo "unsupported makepkg invocation: $*" >&2
exit 1
SH

chmod +x "$MOCK_BIN"/*

run_case() {
  local mode="$1"
  local label="$2"
  shift 2
  rm -f "$LOG_DIR/pacman.log" "$LOG_DIR/makepkg.log"
  : > "$STATE_DIR/installed_pkgs.txt"

  PATH="$MOCK_BIN:/usr/bin:/bin" \
  XDG_CACHE_HOME="$ROOT/cache" \
  HOME="$ROOT/home" \
  MELON_IT_LOG_DIR="$LOG_DIR" \
  MELON_IT_STATE_DIR="$STATE_DIR" \
  MELON_IT_FIXTURE_REPOS="$FIXTURE_REPOS" \
  MELON_IT_MODE="$mode" \
  "$BIN" --assume-reviewed --i-know-what-im-doing --nopgpfetch --noprovides --nosudoloop -S "$@" \
    > "$LOG_DIR/${label}.out" 2>&1

  cp "$LOG_DIR/pacman.log" "$LOG_DIR/${label}.pacman.log"
  if [[ -f "$LOG_DIR/makepkg.log" ]]; then
    cp "$LOG_DIR/makepkg.log" "$LOG_DIR/${label}.makepkg.log"
  else
    : > "$LOG_DIR/${label}.makepkg.log"
  fi
}

run_case satisfied nx_split nxproxy nxagent
run_case unsatisfied samsung_split samsung-unified-driver

nx_u_lines="$(grep -c '^PACMAN_U ' "$LOG_DIR/nx_split.pacman.log" || true)"
nx_build_lines="$(grep -c '^MAKEPKG_BUILD .*nx-' "$LOG_DIR/nx_split.makepkg.log" || true)"
nx_proxy_u="$(grep -c 'nxproxy-1.0-1-x86_64.pkg.tar.zst' "$LOG_DIR/nx_split.pacman.log" || true)"
nx_agent_u="$(grep -c 'nxagent-1.0-1-x86_64.pkg.tar.zst' "$LOG_DIR/nx_split.pacman.log" || true)"

samsung_build_lines="$(grep -c '^MAKEPKG_BUILD .*samsung-unified-driver-' "$LOG_DIR/samsung_split.makepkg.log" || true)"
samsung_u_main="$(grep -c 'samsung-unified-driver-1.0-1-x86_64.pkg.tar.zst' "$LOG_DIR/samsung_split.pacman.log" || true)"
samsung_u_split="$(grep -E -c 'samsung-unified-driver-(printer|scanner)-1.0-1-x86_64.pkg.tar.zst' "$LOG_DIR/samsung_split.pacman.log" || true)"
samsung_repo_dep="$(grep -c 'PACMAN_S --needed cups' "$LOG_DIR/samsung_split.pacman.log" || true)"

echo "NX_U_LINES=$nx_u_lines"
echo "NX_BUILD_LINES=$nx_build_lines"
echo "NX_PROXY_U=$nx_proxy_u"
echo "NX_AGENT_U=$nx_agent_u"
echo "SAMSUNG_BUILD_LINES=$samsung_build_lines"
echo "SAMSUNG_U_MAIN=$samsung_u_main"
echo "SAMSUNG_U_SPLIT=$samsung_u_split"
echo "SAMSUNG_REPO_DEP_CUPS=$samsung_repo_dep"

[[ "$nx_u_lines" -eq 2 ]]
[[ "$nx_build_lines" -eq 1 ]]
[[ "$nx_proxy_u" -eq 1 ]]
[[ "$nx_agent_u" -eq 1 ]]
[[ "$samsung_build_lines" -eq 1 ]]
[[ "$samsung_u_main" -ge 1 ]]
[[ "$samsung_u_split" -eq 0 ]]
[[ "$samsung_repo_dep" -ge 1 ]]

echo "INTEGRATION_RESULT=PASS"
echo "LOG_DIR=$LOG_DIR"
