#!/bin/sh
# mkpayload.sh — build the payload the APK ships and installs on the device.
#
# The payload is the whole on-device runtime in one tar: bin/dshd, the tools it
# drives, the guard, the boot script, and the bootstrap that installs them. The
# app reads android/assets/payload.tar, pipes it to `su`, and runs
# android/payload/bootstrap.sh out of the extracted copy — so this script decides
# what exists on a device, and the app never carries a second copy of anything.
#
# Two files come out, and they answer different questions:
#
#   payload.tar         what gets installed
#   payload.id          content address of the manifest, by which the app and
#                       `dshd setup --check` decide whether the device is
#                       running the payload this APK shipped
#
# The whole artifact is reproducible: fixed member order, fixed modes, fixed
# mtimes, and no build timestamp anywhere in it, so two builds of the same tree
# produce the same bytes and a comparison can prove what a device would install.
#
# The id is a digest of the manifest body — mode, digest and path per file,
# sorted — not of the tar bytes. Tar bytes carry mtimes and a member order no two
# tar implementations agree on; the manifest is what verification actually
# depends on, so the manifest is what gets a stable name.
#
# The archive is written and then *checked*, rather than trusted: `tar` on the
# machine that happens to run this can add members nobody asked for (macOS ships
# a `._name` AppleDouble beside every file carrying extended attributes), and a
# stray member here is a stray file installed as root on a phone. The check
# compares the archive's members against the manifest and refuses to write an
# artifact that disagrees — see tests/payload.test.sh, which feeds this path a
# tree designed to produce exactly that junk.
#
# usage: mkpayload.sh [--out DIR] [--check] [--quiet]
#
#   --out DIR   where to write (default android/assets)
#   --check     build into a temporary directory and compare with what is
#               already there; writes nothing, exits 4 when it is stale
#   --quiet     only errors
#
# exit: 0 ok · 1 usage · 2 a source file is missing · 3 tar failed or the
#       archive does not match the manifest · 4 --check found a stale payload
#
# POSIX sh: this never runs on a phone, but it runs on both a macOS and a Linux
# development host, so no bashisms, and `sh -n tools/mkpayload.sh` checks it.

set -u

die() {
  rc=$1
  shift
  printf 'mkpayload: %s\n' "$*" >&2
  exit "$rc"
}

have() { command -v "$1" >/dev/null 2>&1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd) || die 1 "cannot locate the repository root"
OUT="$ROOT/android/assets"
CHECK=0
QUIET=0

log() {
  [ "$QUIET" = 1 ] || printf '%s\n' "$*"
}

# The payload's contents, as `mode source destination`. A deliberate list, not
# "everything in git": the device needs the runtime, and shipping the tests and
# docs to a phone would make the artifact root installs unreviewable.
# tests/payload.test.sh holds it to two rules — every tool bin/dshd drives must
# be here, and nothing may be here that is not part of the runtime.
MANIFEST_FILES="
0755 bin/dshd bin/dshd
0755 tools/probe.sh tools/probe.sh
0755 tools/rootfs-setup.sh tools/rootfs-setup.sh
0755 tools/install-harness.sh tools/install-harness.sh
0755 tools/firewall.sh tools/firewall.sh
0755 tools/confinement-check.sh tools/confinement-check.sh
0644 guard/guard.mjs guard/guard.mjs
0755 boot/service.d/dshd.sh boot/service.d/dshd.sh
0755 android/payload/bootstrap.sh bootstrap.sh
"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      shift
      OUT=${1:-}
      ;;
    --check) CHECK=1 ;;
    --quiet) QUIET=1 ;;
    -h | --help)
      sed -n '2,46p' "$0" | sed -e 's/^#//' -e 's/^ //'
      exit 0
      ;;
    *) die 1 "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

sha256_of() {
  out=$( { have sha256sum && sha256sum "$1" 2>/dev/null | cut -d' ' -f1; } 2>/dev/null )
  [ -n "$out" ] || out=$( { have shasum && shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; } 2>/dev/null )
  [ -n "$out" ] || out=$( { have openssl && openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; } 2>/dev/null )
  # An empty digest is not a digest: it would go into the manifest as a blank
  # field and every file would then "match" it. Fail here instead.
  [ -n "$out" ] || die 1 "cannot hash $1 (no working sha256sum, shasum or openssl on this host)"
  printf '%s\n' "$out"
}

sha256_of_string() {
  if have sha256sum; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif have shasum; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# --- work area and the file list --------------------------------------------
#
# The list goes into a file and every loop reads it with a redirection rather
# than through a pipe: `printf ... | while read` runs the loop in a subshell, so
# a die() inside it would end the subshell, print the error, and let the build
# carry on with a half-populated payload. Same reason for the accumulator in
# manifest_body().

TMP=$(mktemp -d "${TMPDIR:-/tmp}/dsh-payload.XXXXXX") || die 1 "cannot create a work directory"
STAGE="$TMP/stage"
LIST="$TMP/files"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

printf '%s\n' "$MANIFEST_FILES" | grep . >"$LIST" || die 1 "the file list is empty"
mkdir -p "$STAGE" || die 1 "cannot create $STAGE"

stage_files() {
  while read -r mode src dst; do
    [ -f "$ROOT/$src" ] || die 2 "$src is not in the working tree"
    dest_dir="$STAGE/$(dirname "$dst")"
    mkdir -p "$dest_dir" || die 1 "cannot create $dest_dir"
    cp "$ROOT/$src" "$STAGE/$dst" || die 1 "cannot copy $src"
    chmod "$mode" "$STAGE/$dst" || die 1 "cannot chmod $dst"
  done <"$LIST"
}

# <mode> <sha256> <path>, sorted by path, which is also the order the id covers.
BODY=""
build_body() {
  BODY=""
  while read -r mode src dst; do
    sum=$(sha256_of "$STAGE/$dst") || die 3 "cannot hash $dst"
    BODY="$BODY$mode $sum $dst
"
  done <"$LIST"
  [ -n "$BODY" ] || die 3 "the manifest body is empty"
}

# --- archive ----------------------------------------------------------------

# BSD tar and GNU tar spell "do not record the packager" differently, and only
# BSD tar has the macOS metadata switches. Detected, not assumed — the failure
# mode of the wrong guess is silent extra members — and then verified, because
# detection is still a guess.
tar_cmd() {
  archive=$1
  shift
  if tar --help 2>&1 | grep -q -- '--uid'; then
    COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs \
      --uid 0 --gid 0 --uname root --gname root \
      -cf "$archive" -C "$STAGE" "$@"
  else
    tar --owner=0 --group=0 --numeric-owner -cf "$archive" -C "$STAGE" "$@"
  fi
}

verify_archive() {
  archive=$1
  tar -tf "$archive" >"$TMP/members" 2>/dev/null || die 3 "cannot list the archive just written"
  # Directory members are the paths' own prefixes and carry no content; compare
  # the file members only.
  sed -e 's|^\./||' "$TMP/members" | grep -v '/$' | grep . | LC_ALL=C sort -u >"$TMP/actual"
  # The manifest is in the archive and is not listed *in itself*: it is the one
  # member that cannot carry its own digest. Named here so the exception is one
  # visible line rather than a hole in the comparison.
  {
    awk '{print $3}' "$LIST"
    printf '%s\n' payload.sha256
  } | LC_ALL=C sort -u >"$TMP/expected"

  unexpected=$(LC_ALL=C comm -13 "$TMP/expected" "$TMP/actual")
  if [ -n "$unexpected" ]; then
    printf 'mkpayload: the archive contains members the manifest does not list:\n' >&2
    printf '  %s\n' $unexpected >&2
    die 3 "refusing to write an artifact that would install files nobody reviewed"
  fi
  missing=$(LC_ALL=C comm -23 "$TMP/expected" "$TMP/actual")
  if [ -n "$missing" ]; then
    printf 'mkpayload: the archive is missing manifested files:\n' >&2
    printf '  %s\n' $missing >&2
    die 3 "the archive does not match the manifest"
  fi
  return 0
}

build() {
  dest=$1
  stage_files
  build_body
  id=$(sha256_of_string "$BODY") || die 3 "cannot compute the payload id"
  count=$(printf '%s\n' "$BODY" | grep -c .)

  {
    printf '# dsh-android payload — verified by bootstrap.sh before anything is installed\n'
    printf '# payload-id: %s\n' "$id"
    printf '# files: %s\n' "$count"
    printf '# dshd-version: %s\n' "$(sed -n 's/^DSHD_VERSION=//p' "$STAGE/bin/dshd" | head -n 1)"
    printf '# the files below are the manifest: <mode> <sha256> <path>\n'
    printf '%s\n' "$BODY"
  } >"$STAGE/payload.sha256" || die 3 "cannot write the manifest"

  # One fixed timestamp for every member, applied *after* the last file has been
  # written -- and to directories as well as files. Both details were learned the
  # hard way: `find -type f` leaves directory entries carrying the build clock,
  # and doing it before the manifest is written leaves the manifest's own header
  # carrying it. A tar header stores whole seconds, so two builds in the same one
  # agree either way, which is how a reproducibility check passes while proving
  # nothing and then fails a byte-for-byte comparison a second later.
  find "$STAGE" -exec touch -t 200001010000 {} + 2>/dev/null ||
    touch -t 200001010000 "$STAGE" "$STAGE"/* "$STAGE"/*/* 2>/dev/null || true

  mkdir -p "$dest" || die 1 "cannot create $dest"
  tar_cmd "$dest/payload.tar" bin tools guard boot bootstrap.sh payload.sha256 || die 3 "tar failed"
  verify_archive "$dest/payload.tar"
  printf '%s\n' "$id" >"$dest/payload.id" || die 1 "cannot write $dest/payload.id"
  return 0
}

if [ "$CHECK" = 1 ]; then
  fresh_dir="$TMP/check"
  build "$fresh_dir"
  fresh=$(cat "$fresh_dir/payload.id")
  if [ ! -f "$OUT/payload.id" ]; then
    die 4 "no payload in $OUT — run tools/mkpayload.sh"
  fi
  current=$(cat "$OUT/payload.id")
  if [ "$fresh" != "$current" ]; then
    printf 'mkpayload: the payload is stale\n  built:   %s\n  on disk: %s\n' "$fresh" "$current" >&2
    exit 4
  fi
  log "payload is up to date ($current)"
  exit 0
fi

build "$OUT"
log "payload: $OUT/payload.tar ($(wc -c <"$OUT/payload.tar" | tr -d ' ') bytes)"
log "payload id: $(cat "$OUT/payload.id")"
