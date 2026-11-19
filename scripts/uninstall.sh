#!/usr/bin/env bash

# Detect and remove artefacts CLI installs.

set -euo pipefail

PREFIX_FROM_ENV=${PREFIX:-}
PREFIX=${PREFIX:-/usr/local}
PREFIX=${PREFIX%/}
case $PREFIX in /*) ;; *) PREFIX=$PWD/$PREFIX ;; esac

#
# Messaging
#

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Detect and remove artefacts CLI installs.

Options:
  -y, --yes      Proceed without confirmation: remove the first detected
                 install only (all detected installs with --all).
  --all          Remove all detected installs without confirmation.
  -h, --help     Show this help.

With one install, confirmation is a simple yes/no prompt. With several, an
option list is shown. If none are found under the default PREFIX, an
alternative can be entered. PREFIX defaults to /usr/local and can be set
in the environment.
EOF
}

die() {
  printf 'artefacts: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'artefacts: %s\n' "$*"
}

all=0
yes=0
help=0
for arg in "$@"; do
  case $arg in
    --all) all=1 ;;
    -y|--yes) yes=1 ;;
    -h|--help) help=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done
[ "$help" = 0 ] || { usage; exit 0; }

#
# Utils
#

# Escalate one command at a time, and say why that command needs it.
priv() {
  local why=$1
  shift
  [ "$(id -u)" -eq 0 ] && { "$@"; return; }
  log "sudo: $why"
  sudo "$@"
}

remove_path() {
  [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
  rm -f -- "$1" 2>/dev/null ||
    priv "remove $1 (uninstall)" rm -f -- "$1"
}

remove_empty_dir() {
  [ -d "$1" ] || return 0
  [ -z "$(ls -A "$1" 2>/dev/null)" ] || return 0
  rmdir "$1" 2>/dev/null ||
    priv "remove the empty $1 directory" rmdir "$1"
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


share=$PREFIX/share/artefacts
bin=$PREFIX/bin
link=$bin/artefacts

declare -a kinds=() versions=() paths=()
count=0

detect() {
  local f v

  kinds=()
  versions=()
  paths=()
  count=0

  if command -v dpkg >/dev/null 2>&1; then
    v=$(dpkg-query -W -f='${Version}' artefacts 2>/dev/null || true)
    if [ -n "$v" ]; then
      kinds[count]=package
      versions[count]=$v
      paths[count]=''
      count=$((count + 1))
    fi
  fi

  for f in "$share"/artefacts-*; do
    [ -f "$f" ] || continue
    v=${f##*/artefacts-}
    kinds[count]=binary
    versions[count]=$v
    paths[count]=$f
    count=$((count + 1))
  done
}

interactive() {
  [ "$all" = 0 ] && [ "$yes" = 0 ] && [ -t 0 ]
}

ask_prefix() {
  local answer
  printf 'artefacts: checked the native package manager and %s.\n' "$PREFIX"
  printf 'No install found. Try a different PREFIX? [y/N] '
  read -r answer || return 1
  case $answer in
    y|Y|yes|YES) ;;
    *) return 1 ;;
  esac
  printf 'PREFIX: '
  read -r answer || return 1
  [ -n "$answer" ] || return 1

  PREFIX=$answer
  PREFIX=${PREFIX%/}
  case $PREFIX in /*) ;; *) PREFIX=$PWD/$PREFIX ;; esac
  share=$PREFIX/share/artefacts
  bin=$PREFIX/bin
  link=$bin/artefacts
  detect
}

confirm_one() {
  local answer
  printf 'artefacts: detected: %s %s' "${kinds[0]}" "${versions[0]}"
  [ -n "${paths[0]}" ] && printf '  %s' "${paths[0]}"
  printf '\n'
  printf 'Uninstall this install? [y/N] '
  read -r answer || return 1
  case $answer in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

choose() {
  local i answer
  selected=()

  if ! interactive; then
    if [ "$all" = 1 ]; then
      log 'no confirmation requested; uninstalling all installs'
      for ((i = 0; i < count; i++)); do
        selected+=("$i")
      done
    else
      log 'no confirmation requested; uninstalling first install'
      selected=(0)
    fi
    return 0
  fi

  if [ "$count" -eq 1 ]; then
    confirm_one || return 1
    selected=(0)
    return 0
  fi

  printf 'artefacts: detected installations:\n'
  for ((i = 0; i < count; i++)); do
    printf '  %d) %-7s %s' "$((i + 1))" "${kinds[$i]}" "${versions[$i]}"
    [ -n "${paths[$i]}" ] && printf '  %s' "${paths[$i]}"
    printf '\n'
  done
  printf '  a) all\n  q) quit\n'
  printf 'Select [q]: '
  read -r answer || answer=q

  case $answer in
    a|A|all|ALL)
      for ((i = 0; i < count; i++)); do
        selected+=("$i")
      done
      return 0
      ;;
    ''|q|Q|quit|QUIT) return 1 ;;
    *[!0-9]*) die 'invalid selection' ;;
  esac

  if [ "$answer" -lt 1 ] || [ "$answer" -gt "$count" ]; then
    die 'selection out of range'
  fi
  selected=("$((answer - 1))")
}

remove_package() {
  priv 'remove the artefacts package from system directories' \
    dpkg -r artefacts
}

remove_binary() {
  local path=$share/artefacts-$1
  [ -f "$path" ] || return 0
  rm -f -- "$path" 2>/dev/null ||
    priv "remove $path (uninstall)" rm -f -- "$path"
}

sync_link() {
  local remaining=() f v

  for f in "$share"/artefacts-*; do
    [ -f "$f" ] || continue
    v=${f##*/artefacts-}
    remaining+=("$v")
  done

  [ -e "$link" ] || [ -L "$link" ] || return 0

  if [ ${#remaining[@]} -eq 0 ]; then
    remove_path "$link"
    return 0
  fi

  v=$share/artefacts-${remaining[0]}
  if [ "$(readlink "$link" 2>/dev/null)" != "$v" ]; then
    point_link "$v" "$link"
  fi
}

#
# Main
#

default_prefix=1
[ -z "$PREFIX_FROM_ENV" ] || default_prefix=0
asked_prefix=0

detect
while [ "$count" -eq 0 ]; do
  if [ "$default_prefix" = 1 ] && [ "$asked_prefix" = 0 ] &&
     interactive && ask_prefix; then
    asked_prefix=1
    continue
  fi
  log "nothing to uninstall (checked the native package manager and $PREFIX)"
  exit 0
done

choose || { log 'nothing uninstalled'; exit 0; }

for i in "${selected[@]}"; do
  if [ "${kinds[$i]}" = package ]; then
    remove_package
  else
    remove_binary "${versions[$i]}"
    log "removed binary artefacts ${versions[$i]}"
  fi
done

sync_link
remove_empty_dir "$share"
log 'artefacts uninstalled'
