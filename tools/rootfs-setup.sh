#!/system/bin/sh
# rootfs-setup.sh — Phase 1: assemble the glibc arm64 rootfs (D1).
#
# D1 is the whole strategy: a glibc rootfs in a real chroot makes upstream's
# stock `linux-arm64` artifacts valid verbatim, so there is no native code to
# rebuild and no fork to maintain. This script builds that rootfs. It is not a
# convenience wrapper — nothing downstream works until it has run.
#
#   1. preflight: root, and a *functional* test that the target path executes
#      what is written to it. That check is repeated here rather than trusted
#      from Phase 0 because failing it after a 30 MB download is a waste, and
#      because a noexec path only shows up when something is executed.
#   2. fetch the Ubuntu base tarball (glibc — Alpine/musl is explicitly the wrong
#      answer here, plan §5 Phase 1) and verify it against the release's
#      SHA256SUMS.
#   3. extract into $DSH_ROOTFS and create the skeleton (proc, sys, dev,
#      dev/pts, tmp, workspace, state).
#   4. install glibc Node from the official linux-arm64 tarball, verified against
#      SHASUMS256.txt, at a version satisfying `^22.19.0 || >=24.0.0`.
#   5. write /etc/resolv.conf and /etc/hosts so apt and npm can reach the
#      network, using Android's own DNS properties rather than a guess.
#   6. Gate P1: inside a chroot, `node -v` reports a supported version and libc
#      introspection reports glibc — the check the plan specifies verbatim.
#
# Two choices worth stating:
#
#   * Node is fetched as **.tar.gz**, not .tar.xz. Node publishes both for
#     linux-arm64, and Android's toybox `tar` handles gzip while xz needs
#     BusyBox. BusyBox is present on Magisk and on KernelSU/KernelSU-Next
#     (/data/adb/*/bin/busybox) but it is not something to depend on when a
#     gzip URL exists.
#   * The base image is a **point release that moves**. Rather than hardcode
#     ubuntu-base-24.04.5-base-arm64.tar.gz and have it 404 next month, the
#     newest matching tarball is discovered from the release directory and then
#     verified against SHA256SUMS, which is the file that actually matters.
#
# usage: rootfs-setup.sh [options]
#   --base-file PATH     use a local base tarball instead of downloading
#   --base-sha256 HASH   expected hash for --base-file (default: verify against
#                        the release's SHA256SUMS, or skip with a warning)
#   --node-file PATH     use a local Node tarball instead of downloading
#   --node-sha256 HASH   expected hash for --node-file
#   --node-version V     Node version to install (default: v24.21.0)
#   --base-release R     Ubuntu base release (default: 24.04)
#   --force              replace an existing rootfs
#   --skip-node          base rootfs only
#   --skip-verify        do not run the P0/P1 gate checks (loudly reported)
#   --dry-run            print what would happen; change nothing
#
# exit: 0 ok · 1 usage/config · 2 not root · 3 prerequisite failed
#       4 download or checksum failure · 5 extraction/staging failure
#       6 Gate P1 failed

set -u

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

: "${DSH_BASE:=/data/local/dsh}"
: "${DSH_ROOTFS:=$DSH_BASE/rootfs}"
: "${DSH_STATE:=$DSH_BASE/state}"
: "${DSH_WORKSPACE:=$DSH_BASE/workspace}"
: "${DSH_LOG:=$DSH_BASE/log}"

BASE_RELEASE=24.04
NODE_VERSION=v24.21.0
UBUNTU_ARCH=arm64
BASE_FILE=""
BASE_SHA256=""
NODE_FILE=""
NODE_SHA256=""
FORCE=0
SKIP_NODE=0
SKIP_VERIFY=0
DRY_RUN=0

BASE_URL="${DSH_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/$BASE_RELEASE/release}"
NODE_URL="https://nodejs.org/dist/$NODE_VERSION"

DOWNLOAD_DIR="$DSH_BASE/download"
STAGE_DIR="$DSH_BASE/.stage.$$"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '%s rootfs-setup: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$*"; }
warn() { log "WARNING: $*"; }

die() {
  code=$1
  shift
  printf 'rootfs-setup: ERROR: %s\n' "$*" >&2
  exit "$code"
}

have() { command -v "$1" >/dev/null 2>&1; }

# The manager's BusyBox, which is the reliable source of sha256sum/xz/wget on a
# device where toybox may lack them. KernelSU and KernelSU-Next share
# /data/adb/ksu; Magisk uses /data/adb/magisk.
busybox_bin() {
  if have busybox; then
    command -v busybox
    return 0
  fi
  for c in "${DSH_ADB:-/data/adb}/ksu/bin/busybox" "${DSH_ADB:-/data/adb}/magisk/busybox"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# sha256 of a file, through whatever the platform provides. Returns non-zero when
# nothing can compute it, and every caller treats that as fatal: an unverified
# 30 MB rootfs is exactly the kind of thing that fails three phases later.
sha256_of() {
  f=$1
  if have sha256sum; then
    sha256sum "$f" 2>/dev/null | cut -d' ' -f1
    return 0
  fi
  if have shasum; then
    shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1
    return 0
  fi
  if have openssl; then
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
    return 0
  fi
  bb=$(busybox_bin) && "$bb" sha256sum "$f" 2>/dev/null | cut -d' ' -f1
}

fetch() {
  url=$1
  dest=$2
  log "fetching $url"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would write $dest"
    return 0
  fi
  if have curl; then
    curl -fsSL --retry 2 -o "$dest" "$url" && return 0
  fi
  if have wget; then
    wget -q -O "$dest" "$url" && return 0
  fi
  bb=$(busybox_bin) && "$bb" wget -q -O "$dest" "$url" && return 0
  return 1
}

# Pull the expected hash for $2 out of a sums file. Handles both "hash  name"
# (Node) and "hash *name" / "hash  ./name" (Ubuntu, and the BSD-style star).
expected_hash() {
  sums=$1
  name=$2
  awk -v want="$name" '
    {
      n = $2
      sub(/^\*/, "", n)
      sub(/^\.\//, "", n)
      if (n == want) { print $1; found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$sums"
}

verify_file() {
  file=$1
  expected=$2
  label=$3
  if [ -z "$expected" ]; then
    warn "no checksum available for $label — continuing unverified"
    return 0
  fi
  actual=$(sha256_of "$file") || die 4 "cannot compute a sha256 for $label: no sha256sum, shasum, openssl or BusyBox available"
  if [ "$actual" != "$expected" ]; then
    die 4 "$label checksum mismatch:
    expected $expected
    actual   $actual
  The download is corrupt or the file is not what it claims to be. Nothing was installed."
  fi
  log "$label verified (sha256 ${actual%${actual#????????????}}…)"
}

# A path that executes what is written to it. Not a mount-table check: noexec
# can be in the options without appearing where you looked, and it only shows up
# when something runs.
check_executable() {
  dir=$1
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$dir" || die 3 "cannot create $dir"
  marker="$dir/.exec-check.$$"
  printf '#!%s\nprintf ok\n' "$(command -v sh)" >"$marker" 2>/dev/null || die 3 "cannot write to $dir"
  chmod +x "$marker" 2>/dev/null
  out=$("$marker" 2>&1)
  rc=$?
  rm -f "$marker"
  if [ "$rc" != 0 ] || [ "$out" != "ok" ]; then
    die 3 "$dir does not execute what is written to it (noexec?) — Node cannot run from there, so D1 cannot work on this path. See plan §6; move DSH_BASE to a path that executes."
  fi
  log "$dir executes what is written to it"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

preflight() {
  [ "$DRY_RUN" = 1 ] || [ "$(id -u 2>/dev/null)" = 0 ] || die 2 "must run as root: the chroot, the mounts and the tarball ownership all need it"

  missing=""
  for c in tar mkdir chmod printf date; do
    have "$c" || missing="$missing $c"
  done
  [ -n "$missing" ] && die 3 "missing required commands:$missing"
  if ! have gzip && ! busybox_bin >/dev/null 2>&1; then
    warn "no gzip and no BusyBox: tar may not be able to unpack the base image"
  fi

  check_executable "$DSH_BASE"

  if [ -e "$DSH_ROOTFS/bin" ] && [ "$FORCE" != 1 ]; then
    die 5 "$DSH_ROOTFS already looks like a rootfs. Re-run with --force to replace it (its state and workspace are elsewhere and are not touched)."
  fi
}

# Discover the newest ubuntu-base-<release>.*-base-<arch>.tar.gz rather than
# hardcoding a point release that will disappear.
#
# What this function prints on stdout is the file name and nothing else, because
# the caller captures it: `name=$(discover_base_file)`. That is not a style
# preference. `fetch` logs the URL it is about to read on stdout, so the listing
# fetch below put its own log line into the name — and the device asked for
#
#   https://…/release/2026-10-04T12:31:11+0800 rootfs-setup: fetching https://…/release/
#   ubuntu-base-24.04.5-base-arm64.tar.gz
#
# a URL with a newline in it, which curl refused ("URL rejected: Malformed input
# to a URL function") and BusyBox wget answered with 400 Bad Request, while the
# step's error message blamed the network. `>&2` is the whole fix: the log line is
# still printed, on the stream that is not the return value.
discover_base_file() {
  listing="$DOWNLOAD_DIR/.listing"
  fetch "$BASE_URL/" "$listing" >&2 || die 4 "cannot list $BASE_URL/ (no network, or no curl/wget)"
  # Compared numerically rather than with `sort -V`, which toybox's sort does not
  # promise: lexically 24.04.10 sorts before 24.04.9, which is exactly the bug
  # that would pin an old point release forever.
  name=$(sed -n "s/.*\(ubuntu-base-[0-9][0-9.]*-base-$UBUNTU_ARCH\.tar\.gz\).*/\1/p" "$listing" \
    | sort -u \
    | awk '
        {
          split($0, parts, "-")
          n = split(parts[3], num, ".")
          score = 0
          for (i = 1; i <= 4; i++) score = score * 1000 + (num[i] + 0)
          if (score >= best) { best = score; name = $0 }
        }
        END { if (name != "") print name }
      ')
  [ -n "$name" ] || die 4 "no ubuntu-base-*-base-$UBUNTU_ARCH.tar.gz found at $BASE_URL/"
  printf '%s\n' "$name"
}

step_base() {
  log "phase 1a: base rootfs (Ubuntu $BASE_RELEASE, $UBUNTU_ARCH, glibc)"
  if [ -n "$BASE_FILE" ]; then
    [ -f "$BASE_FILE" ] || die 1 "--base-file $BASE_FILE does not exist"
    base_path=$BASE_FILE
    verify_file "$base_path" "$BASE_SHA256" "base tarball"
  else
    mkdir -p "$DOWNLOAD_DIR"
    name=$(discover_base_file)
    log "newest base image: $name"
    base_path="$DOWNLOAD_DIR/$name"
    if [ "$DRY_RUN" = 1 ]; then
      log "dry-run: would download $BASE_URL/$name"
    else
      [ -f "$base_path" ] || fetch "$BASE_URL/$name" "$base_path" || die 4 "cannot download $BASE_URL/$name"
      sums="$DOWNLOAD_DIR/SHA256SUMS.base"
      [ -f "$sums" ] || fetch "$BASE_URL/SHA256SUMS" "$sums" || die 4 "cannot download $BASE_URL/SHA256SUMS (needed to verify the base image)"
      verify_file "$base_path" "$(expected_hash "$sums" "$name")" "base tarball"
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would extract $base_path into $DSH_ROOTFS"
    return 0
  fi
  [ "$FORCE" = 1 ] && [ -d "$DSH_ROOTFS" ] && { log "removing the existing rootfs (--force)"; rm -rf "$DSH_ROOTFS"; }
  mkdir -p "$DSH_ROOTFS"
  log "extracting into $DSH_ROOTFS"
  tar -xzf "$base_path" -C "$DSH_ROOTFS" || die 5 "extraction failed (out of space? gzip support in tar?)"
  [ -x "$DSH_ROOTFS/bin/sh" ] || die 5 "$DSH_ROOTFS/bin/sh is missing after extraction — the tarball is not a usable rootfs"
}

step_skeleton() {
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would create the skeleton"; return 0; }
  log "phase 1b: skeleton"
  for d in proc sys dev dev/pts dev/shm tmp run workspace state opt/dsh-android usr/local; do
    mkdir -p "$DSH_ROOTFS/$d"
  done
  # The guard ships inside the rootfs because dshd starts it from in there.
  if [ -f "$DSH_BASE/guard/guard.mjs" ]; then
    cp "$DSH_BASE/guard/guard.mjs" "$DSH_ROOTFS/opt/dsh-android/guard.mjs"
    log "installed guard.mjs into the rootfs"
  fi
  chmod 1777 "$DSH_ROOTFS/tmp" 2>/dev/null
  chmod 755 "$DSH_ROOTFS/root" 2>/dev/null
}

step_resolv() {
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would write resolv.conf"; return 0; }
  log "phase 1c: DNS"
  mkdir -p "$DSH_ROOTFS/etc"
  # Ubuntu base ships resolv.conf as a symlink into /run on some releases, and
  # writing through it would create the target rather than the file.
  [ -L "$DSH_ROOTFS/etc/resolv.conf" ] && rm -f "$DSH_ROOTFS/etc/resolv.conf"

  dns=""
  if have getprop; then
    dns=$(getprop 2>/dev/null | sed -n 's/.*\[\(net\.[a-zA-Z0-9_.]*dns[0-9]*\)\]: \[\([0-9a-fA-F:.]*\)\].*/\2/p' | sort -u)
  fi
  if [ -z "$dns" ]; then
    warn "no DNS servers found in Android properties; falling back to 1.1.1.1 and 8.8.8.8"
    dns="1.1.1.1
8.8.8.8"
  fi
  {
    printf '# written by rootfs-setup.sh — Android has no /etc/resolv.conf of its own,\n'
    printf '# so apt and npm inside the chroot need this file to exist.\n'
    for s in $dns; do printf 'nameserver %s\n' "$s"; done
  } >"$DSH_ROOTFS/etc/resolv.conf" || die 3 "cannot write $DSH_ROOTFS/etc/resolv.conf"
  log "resolv.conf: $(tr '\n' ' ' <"$DSH_ROOTFS/etc/resolv.conf" | sed 's/#.*//')"

  if [ ! -f "$DSH_ROOTFS/etc/hosts" ]; then
    printf '127.0.0.1 localhost\n::1 localhost\n' >"$DSH_ROOTFS/etc/hosts"
  fi
  # APT inside the chroot is the Phase 2 install path; a missing sources.list is
  # a confusing failure later, so say something now.
  [ -f "$DSH_ROOTFS/etc/apt/sources.list" ] || [ -f "$DSH_ROOTFS/etc/apt/sources.list.d/ubuntu.sources" ] \
    || warn "no apt sources found in the rootfs — 'apt-get update' will need /etc/apt/sources.list"
}

step_node() {
  [ "$SKIP_NODE" = 1 ] && { log "phase 1d: skipped (--skip-node)"; return 0; }
  log "phase 1d: glibc Node ($NODE_VERSION, linux-$UBUNTU_ARCH)"

  # .tar.gz on purpose: see the header.
  node_name="node-$NODE_VERSION-linux-$UBUNTU_ARCH.tar.gz"
  if [ -n "$NODE_FILE" ]; then
    [ -f "$NODE_FILE" ] || die 1 "--node-file $NODE_FILE does not exist"
    node_path=$NODE_FILE
    verify_file "$node_path" "$NODE_SHA256" "node tarball"
  else
    mkdir -p "$DOWNLOAD_DIR"
    node_path="$DOWNLOAD_DIR/$node_name"
    if [ "$DRY_RUN" = 1 ]; then
      log "dry-run: would download $NODE_URL/$node_name"
    else
      [ -f "$node_path" ] || fetch "$NODE_URL/$node_name" "$node_path" || die 4 "cannot download $NODE_URL/$node_name"
      sums="$DOWNLOAD_DIR/SHASUMS256.txt"
      [ -f "$sums" ] || fetch "$NODE_URL/SHASUMS256.txt" "$sums" || die 4 "cannot download $NODE_URL/SHASUMS256.txt (needed to verify Node)"
      verify_file "$node_path" "$(expected_hash "$sums" "$node_name")" "node tarball"
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would install Node into $DSH_ROOTFS/usr/local"
    return 0
  fi

  # Extract to a staging directory and move the payload, rather than relying on
  # --strip-components, which toybox tar does not promise.
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR" || die 5 "cannot create $STAGE_DIR"
  tar -xzf "$node_path" -C "$STAGE_DIR" || { rm -rf "$STAGE_DIR"; die 5 "cannot extract the Node tarball (gzip support in tar?)"; }
  top=$(find "$STAGE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
  [ -n "$top" ] || { rm -rf "$STAGE_DIR"; die 5 "the Node tarball did not contain a top-level directory"; }

  mkdir -p "$DSH_ROOTFS/usr/local"
  # A tar file rather than a pipe: a failed `cd` inside a pipeline would be
  # hidden by the last command's status, and this step must not fail silently.
  if ! (cd "$top" && tar -cf "$STAGE_DIR/node.tar" .); then
    rm -rf "$STAGE_DIR"
    die 5 "cannot stage the Node payload"
  fi
  if ! tar -xf "$STAGE_DIR/node.tar" -C "$DSH_ROOTFS/usr/local"; then
    rm -rf "$STAGE_DIR"
    die 5 "cannot install Node into $DSH_ROOTFS/usr/local"
  fi
  rm -rf "$STAGE_DIR"
  [ -x "$DSH_ROOTFS/usr/local/bin/node" ] || die 5 "$DSH_ROOTFS/usr/local/bin/node is missing after install"
  log "installed Node into /usr/local inside the rootfs"
}

# Gate P1. Mounts first: node -v does not need /proc, but apt (Phase 2) does, and
# the plan's gate asks to confirm the mounts survive a re-chroot.
step_verify() {
  if [ "$SKIP_VERIFY" = 1 ]; then
    warn "--skip-verify: NOT running Gate P1. The rootfs is unverified: do not treat it as working until 'dshd start' has proved it on this device."
    return 0
  fi
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would run Gate P1"; return 0; }

  log "phase 1e: Gate P1 (chroot: node -v, and libc introspection)"
  if [ -x "$DSH_BASE/bin/dshd" ]; then
    # The mounts belong to dshd; asking it to make them means the runtime and
    # this check cannot drift apart.
    log "asking dshd for the bind mounts"
    sh "$DSH_BASE/bin/dshd" mounts >/dev/null 2>&1 || warn "dshd mounts reported a problem; continuing"
  else
    mkdir -p "$DSH_ROOTFS/proc" "$DSH_ROOTFS/dev/pts"
    mount -t proc proc "$DSH_ROOTFS/proc" 2>/dev/null || warn "mount -t proc failed (needed later, not for this check)"
    mount -t devpts devpts "$DSH_ROOTFS/dev/pts" 2>/dev/null || warn "mount -t devpts failed (needed only for the PTY terminal)"
  fi

  [ "$SKIP_NODE" = 1 ] && return 0

  if ! out=$(chroot "$DSH_ROOTFS" /usr/local/bin/node -v 2>&1); then
    die 6 "Gate P1 failed: 'node -v' inside the chroot did not run: $out"
  fi
  log "node reports $out"
  ver=${out#v}
  major=${ver%%.*}
  minor=${ver#*.}
  minor=${minor%%.*}
  ok=0
  [ "$major" -ge 24 ] 2>/dev/null && ok=1
  if [ "$ok" = 0 ] && [ "$major" -eq 22 ] 2>/dev/null && [ "$minor" -ge 19 ] 2>/dev/null; then
    ok=1
  fi
  [ "$ok" = 1 ] || die 6 "Gate P1 failed: Node $out does not satisfy the harness's engines floor ^22.19.0 || >=24.0.0"

  libc=$(chroot "$DSH_ROOTFS" /usr/local/bin/node -p "process.report.getReport().header.glibcVersionRuntime || 'MUSL/OTHER — D1 is broken'" 2>&1)
  case "$libc" in
    *MUSL* | *broken* | '') die 6 "Gate P1 failed: libc introspection says '$libc' — D1 requires glibc" ;;
  esac
  log "glibc: $libc"

  # "Confirm the mounts survive a re-chroot" (plan §5 Phase 1).
  if out=$(chroot "$DSH_ROOTFS" /bin/sh -c 'test -r /proc/mounts && head -n 1 /proc/mounts' 2>&1); then
    log "re-chroot sees /proc: $out"
  else
    warn "a re-chroot could not read /proc/mounts: $out"
  fi

  log "Gate P1 PASSED: node $out (glibc $libc)"
}

summary() {
  log ""
  log "rootfs:     $DSH_ROOTFS"
  log "state:      $DSH_STATE   (in-chroot /state — created by dshd, not here)"
  log "workspace:  $DSH_WORKSPACE   (in-chroot /workspace)"
  log "downloads:  $DOWNLOAD_DIR (re-runs reuse them; safe to delete)"
  log ""
  if [ "$SKIP_VERIFY" = 1 ] || [ "$SKIP_NODE" = 1 ]; then
    log "PARTIAL: the rootfs was not verified end to end. Re-run without --skip-verify/--skip-node before Phase 2."
  else
    log "next: sh $DSH_BASE/tools/install-harness.sh   (Phase 2: install the harness at a pinned version)"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-file) shift; BASE_FILE=${1:-} ;;
      --base-sha256) shift; BASE_SHA256=${1:-} ;;
      --node-file) shift; NODE_FILE=${1:-} ;;
      --node-sha256) shift; NODE_SHA256=${1:-} ;;
      --node-version) shift; NODE_VERSION=${1:-} ;;
      --base-release) shift; BASE_RELEASE=${1:-}; BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/$BASE_RELEASE/release" ;;
      --force) FORCE=1 ;;
      --skip-node) SKIP_NODE=1 ;;
      --skip-verify) SKIP_VERIFY=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) die 1 "unknown argument '$1' (try --help)" ;;
    esac
    shift
  done

  [ -n "$NODE_VERSION" ] || die 1 "--node-version needs a value"
  case "$NODE_VERSION" in v*) : ;; *) NODE_VERSION="v$NODE_VERSION" ;; esac

  preflight
  step_base
  step_skeleton
  step_resolv
  step_node
  step_verify
  summary
}

main "$@"
