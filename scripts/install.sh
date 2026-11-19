#!/usr/bin/env bash

# Install the artefacts CLI from GitHub releases.
# Usage: install.sh [version]

set -euo pipefail

REPO=art-e-fact/artefacts-bins
VERSION=latest
have_version=0
PREFIX=${PREFIX:-/usr/local}
PREFIX=${PREFIX%/}
case $PREFIX in
  /*) ;;
  *) PREFIX=$PWD/$PREFIX ;;
esac

#
# Messaging
#

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [version]

Install the artefacts CLI from GitHub releases.

Arguments:
  version        Release tag to install (default: latest)

Options:
  -h, --help     Show this help.

PREFIX defaults to /usr/local and can be overridden with the PREFIX
environment variable.
EOF
}

die() {
  printf 'artefacts: error: %s\n' "$*" >&2
  exit "${2:-1}"
}

log() {
  printf 'artefacts: %s\n' "$*"
}

warn() {
  printf 'artefacts: warning: %s\n' "$*" >&2
}

for arg in "$@"; do
  case $arg in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $arg"
      ;;
    *)
      [ "$have_version" = 0 ] ||
        die "usage: ${0##*/} [options] [version]"
      VERSION=$arg
      have_version=1
      ;;
  esac
done

# Escalate one command at a time, and say why that command needs it.
priv() {
  local why=$1
  shift
  [ "$(id -u)" -eq 0 ] && { "$@"; return; }
  log "sudo: $why"
  sudo "$@"
}

make_dir() {
  mkdir -p "$1" 2>/dev/null ||
    priv "create $1 (install destination)" mkdir -p "$1"
}

install_file() {
  install -m 755 "$1" "$2" 2>/dev/null ||
    priv "write $2 (install the CLI binary)" \
      install -m 755 "$1" "$2"
}

point_link() {
  local target=$1 link=$2
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    return 0
  fi
  ln -sfn "$target" "$link" 2>/dev/null ||
    priv "update $link (point it at $target)" \
      ln -sfn "$target" "$link"
}

on_path() {
  case ":$PATH:" in
    *":$PREFIX/bin:"*) return 0 ;;
  esac
  return 1
}

#
# Utils
#

# Platform detection
case $(uname -s) in
  Linux)  os=linux;  deb=1 ;;
  Darwin) os=darwin; deb=0 ;;
  MINGW*|MSYS*|CYGWIN*) die 'use install.ps1 on Windows' ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac

case $(uname -m) in
  x86_64|amd64)  arch=x64;   debarch=amd64 ;;
  arm64|aarch64) arch=arm64; debarch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac


# Target version
if [ "$VERSION" = latest ]; then
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null) ||
    die 'cannot resolve the latest release'
  VERSION=${url##*/}
else
  VERSION=${VERSION#v}
fi

case $VERSION in
  ''|*[!A-Za-z0-9._-]*) die "invalid version: $VERSION" ;;
esac

base="https://github.com/$REPO/releases/download/$VERSION"
page=$(curl -fsSL \
  "https://github.com/$REPO/releases/expanded_assets/$VERSION" \
  2>/dev/null) || die "release $VERSION not found"
assets=$(grep -o "releases/download/$VERSION/[^\"]*" <<<"$page" |
  sed 's|.*/||')

has() {
  printf '%s\n' "$assets" | grep -Fxq -- "$1"
}


if command -v sha256sum >/dev/null; then
  check=(sha256sum -c --status)
elif command -v shasum >/dev/null; then
  check=(shasum -a 256 -c)
else
  die 'no SHA-256 tool found (need sha256sum or shasum)'
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
  curl -fsSL -o "$tmp/$1" "$base/$1" 2>/dev/null ||
    die "download failed: $1"
}

verify() {
  fetch "$1.sha256"
  (cd "$tmp" && "${check[@]}" "$1.sha256" >/dev/null) ||
    die "checksum mismatch: $1"
}


# Native packages take priority wherever they are published.
if [ "$deb" = 1 ]; then
  pkg=artefacts_${VERSION}_${debarch}.deb
  if has "$pkg"; then
    current=$(dpkg-query -W -f='${Version}' artefacts 2>/dev/null || true)
    if [ "$current" = "$VERSION" ]; then
      log "artefacts $VERSION is already installed (Debian package)"
      exit 0
    fi
    fetch "$pkg"
    verify "$pkg"
    priv "install $pkg into system directories via dpkg" \
      dpkg -i "$tmp/$pkg"
    log "installed artefacts $VERSION via $pkg"
    exit 0
  fi
fi


# Binary install utils
asset=artefacts_$os-$arch
has "$asset" ||
  die "no installer or binary for $os-$arch in release $VERSION" 3

share=$PREFIX/share/artefacts
bin=$PREFIX/bin
target=$share/artefacts-$VERSION

on_path || warn "$bin is not on PATH"

if [ -f "$target" ]; then
  point_link "$target" "$bin/artefacts"
  on_path ||
    warn "$bin is still not on PATH; add it to PATH to use 'artefacts'"
  log "artefacts $VERSION is already installed at $target"
  exit 0
fi

#
# Main
#

fetch "$asset"
verify "$asset"
make_dir "$share"
make_dir "$bin"
install_file "$tmp/$asset" "$target"
point_link "$target" "$bin/artefacts"
log "installed artefacts $VERSION at $target, linked from $bin/artefacts"
on_path ||
  warn "$bin is still not on PATH; add it to PATH to use 'artefacts'"
