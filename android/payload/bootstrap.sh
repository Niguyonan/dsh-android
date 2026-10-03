#!/system/bin/sh
# bootstrap.sh — the payload's own entry point, and the first thing of ours that
# runs on a device.
#
# It runs before anything is installed, so it cannot use anything of ours, and it
# stands alone on purpose: POSIX sh, no sourced helpers, and only commands the
# root solution itself provides (toybox, or Magisk's/KernelSU's BusyBox).
#
# The app runs it like this, with the payload's tar on stdin:
#
#   su -c 'S=/data/local/dsh/.stage; rm -rf "$S"; mkdir -p "$S" &&
#          tar -xf - -C "$S" && exec sh "$S/bootstrap.sh" setup --app-uid 10123'
#
# Every word of that is a constant in android/src/.../Shell.java, except the uid,
# which the app validates as numeric before it goes anywhere near a shell.
#
# What it does, in order:
#
#   1. refuse to run as anything but root (exit 2), so the app can tell "no root
#      granted" from every other failure with one number
#   2. refuse a DSH_BASE that another uid could write to. This directory is where
#      root-executed scripts live: if anything but root owns it, or anyone else
#      can write in it, then whoever that is decides what root runs next
#   3. extract the tar, then verify every file against payload.sha256 *before*
#      installing any of it. A payload that arrived truncated fails here, by
#      digest, instead of half-installing and half-working
#   4. install with compare-then-rename, never by writing in place: bin/dshd may
#      be the running supervisor, and a shell reads its own script incrementally,
#      so truncating it under a live process makes the next line it parses come
#      from the new file at the old offset
#   5. exec dshd, preserving its exit status
#
# Why the payload is an uncompressed tar: the only extractor guaranteed here is
# tar, and asking it for gzip support is one more thing that can be missing on
# the one path that has no fallback. It is the APK's asset compression that makes
# the file small, not gzip.
#
# Progress goes to stdout in the same `##dshd` protocol bin/dshd speaks, with the
# literal nonce `pre`, because these steps happen before dshd exists to have a
# nonce of its own.
#
# exit: 0 ok · 2 not root · 6 the payload did not verify or could not be
#       installed · otherwise dshd's own status

set -u

umask 077

EXIT_NOT_ROOT=2
EXIT_PAYLOAD=6

: "${DSH_BASE:=/data/local/dsh}"
STAGE="$DSH_BASE/.stage"
MANIFEST="payload.sha256"

FROM=""

# --- output -----------------------------------------------------------------

boot_emit() {
  printf '##dshd pre %s\n' "$*"
}

boot_say() {
  printf '%s\n' "$*"
}

boot_pass() { boot_say "[PASS] $*"; }
boot_warn() { boot_say "[WARN] $*"; }
boot_fail() { boot_say "[FAIL] $*"; }

boot_die() {
  rc=$1
  shift
  boot_fail "$*"
  printf 'bootstrap: %s\n' "$*" >&2
  exit "$rc"
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- platform helpers -------------------------------------------------------
#
# Deliberately a copy of rootfs-setup.sh's approach rather than a call into it:
# this file has to work before that one exists on the device. Same order, same
# refusal to guess.

sha256_of() {
  f=$1
  # Every branch is tried until one produces a digest, rather than the first one
  # *found* being trusted: a sha256sum that exists and fails (a broken symlink, a
  # shell function from the environment) would otherwise return an empty string,
  # and an empty digest compared against a manifest is a mismatch at best and a
  # silent pass at worst.
  out=$( { have sha256sum && sha256sum "$f" 2>/dev/null | cut -d' ' -f1; } 2>/dev/null )
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  out=$( { have shasum && shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1; } 2>/dev/null )
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  out=$( { have openssl && openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'; } 2>/dev/null )
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox busybox; do
    if [ -x "$bb" ] || have "$bb"; then
      out=$("$bb" sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
      [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
  done
  return 1
}

# stat(1) is toybox on Android and BSD on the machine the tests run on.
mode_of() {
  stat -c '%a' "$1" 2>/dev/null && return 0
  stat -f '%Lp' "$1" 2>/dev/null && return 0
  busybox stat -c '%a' "$1" 2>/dev/null && return 0
  return 1
}

owner_of() {
  stat -c '%u' "$1" 2>/dev/null && return 0
  stat -f '%u' "$1" 2>/dev/null && return 0
  busybox stat -c '%u' "$1" 2>/dev/null && return 0
  return 1
}

# --- the checks -------------------------------------------------------------

check_root() {
  boot_emit "step root checking for root"
  uid=$(id -u 2>/dev/null)
  if [ "$uid" != 0 ]; then
    boot_emit "fail root the shell is uid ${uid:-unknown}, not 0"
    boot_die "$EXIT_NOT_ROOT" "not root (uid ${uid:-unknown}): the app has to be granted root in Magisk/KernelSU first"
  fi
  boot_emit "ok root"
}

# The directory root will execute from. Owner and mode are the control: another
# uid that can write here is another uid that chooses what root runs.
check_base() {
  [ -e "$DSH_BASE" ] || return 0
  [ -d "$DSH_BASE" ] || boot_die "$EXIT_PAYLOAD" "$DSH_BASE exists and is not a directory"

  base_mode=$(mode_of "$DSH_BASE") || boot_die "$EXIT_PAYLOAD" "cannot read the mode of $DSH_BASE (no usable stat)"
  base_owner=$(owner_of "$DSH_BASE") || boot_die "$EXIT_PAYLOAD" "cannot read the owner of $DSH_BASE (no usable stat)"
  base_perm=$((0$base_mode))

  if [ "$base_owner" != "$(id -u)" ]; then
    boot_die "$EXIT_PAYLOAD" "$DSH_BASE is owned by uid $base_owner, not root: whoever owns it decides which scripts root runs, so this refuses to install into it"
  fi
  if [ $((base_perm & 022)) -ne 0 ]; then
    boot_die "$EXIT_PAYLOAD" "$DSH_BASE is mode $base_mode: group or other writable, so another uid could replace the scripts root runs"
  fi
  return 0
}

extract_payload() {
  if [ -n "$FROM" ]; then
    STAGE=$FROM
    [ -f "$STAGE/$MANIFEST" ] || boot_die "$EXIT_PAYLOAD" "no $MANIFEST in $STAGE"
    return 0
  fi
  rm -rf "$STAGE" || boot_die "$EXIT_PAYLOAD" "cannot clear $STAGE"
  mkdir -p "$STAGE" || boot_die "$EXIT_PAYLOAD" "cannot create $STAGE"
  tar -xf - -C "$STAGE" || boot_die "$EXIT_PAYLOAD" "the payload did not extract (truncated transfer, or no tar on this device)"
  [ -f "$STAGE/$MANIFEST" ] || boot_die "$EXIT_PAYLOAD" "the payload has no $MANIFEST"
  return 0
}

# Every file, by digest, before any of it is installed.
#
# Sets $VERIFIED_COUNT and dies on the first disagreement. Deliberately not a
# command substitution: a function that calls exit() inside $( ) exits only the
# subshell, so a digest mismatch would print loudly and then install anyway —
# the exact shape of failure this file exists to prevent.
VERIFIED_COUNT=0
verify_payload() {
  [ -f "$STAGE/$MANIFEST" ] || boot_die "$EXIT_PAYLOAD" "no manifest at $STAGE/$MANIFEST"
  VERIFIED_COUNT=0
  while read -r mode sum path; do
    # Comments carry the `#` in $mode, not in $path: reading the line splits it
    # into three words, so testing only $path let every header line through as a
    # file named after the rest of the sentence. Blank lines leave both empty.
    [ -n "$mode" ] || continue
    [ -n "$path" ] || continue
    case "$mode" in *"#"*) continue ;; esac
    [ -f "$STAGE/$path" ] || boot_die "$EXIT_PAYLOAD" "$path is listed in the manifest but missing from the payload"
    actual=$(sha256_of "$STAGE/$path") ||
      boot_die "$EXIT_PAYLOAD" "cannot compute a sha256 on this device: no sha256sum, shasum, openssl or BusyBox. Refusing to install unverified files."
    if [ "$actual" != "$sum" ]; then
      boot_die "$EXIT_PAYLOAD" "$path does not match the manifest (expected ${sum%${sum#??????}}…, got ${actual%${actual#??????}}…)"
    fi
    VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
  done <"$STAGE/$MANIFEST"
  [ "$VERIFIED_COUNT" -gt 0 ] || boot_die "$EXIT_PAYLOAD" "the manifest lists no files"
  return 0
}

# Compare-then-rename, never write-in-place. Same variables-not-subshell rule as
# verify_payload, for the same reason.
CHANGED=0
KEPT=0
install_payload() {
  CHANGED=0
  KEPT=0
  while read -r mode sum path; do
    # Comments carry the `#` in $mode, not in $path: reading the line splits it
    # into three words, so testing only $path let every header line through as a
    # file named after the rest of the sentence. Blank lines leave both empty.
    [ -n "$mode" ] || continue
    [ -n "$path" ] || continue
    case "$mode" in *"#"*) continue ;; esac
    src="$STAGE/$path"
    dst="$DSH_BASE/$path"
    dir=$(dirname "$dst")
    mkdir -p "$dir" || boot_die "$EXIT_PAYLOAD" "cannot create $dir"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      KEPT=$((KEPT + 1))
    else
      # The temporary lives beside the target so the rename cannot cross a
      # filesystem: rename(2) is what makes replacing a running script safe.
      tmp="$dst.new.$$"
      cp "$src" "$tmp" || boot_die "$EXIT_PAYLOAD" "cannot write $tmp"
      chmod "$mode" "$tmp" || boot_die "$EXIT_PAYLOAD" "cannot chmod $tmp"
      mv -f "$tmp" "$dst" || {
        rm -f "$tmp"
        boot_die "$EXIT_PAYLOAD" "cannot rename into $dst"
      }
      CHANGED=$((CHANGED + 1))
    fi
    chmod "$mode" "$dst" 2>/dev/null
  done <"$STAGE/$MANIFEST"
  cp "$STAGE/$MANIFEST" "$DSH_BASE/$MANIFEST" || boot_die "$EXIT_PAYLOAD" "cannot write $DSH_BASE/$MANIFEST"
  chmod 0644 "$DSH_BASE/$MANIFEST" 2>/dev/null
  return 0
}

boot_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        shift
        FROM=${1:-}
        ;;
      --base)
        shift
        DSH_BASE=${1:-}
        STAGE="$DSH_BASE/.stage"
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  check_root
  check_base

  boot_emit "step payload installing the app's payload"
  extract_payload
  verify_payload
  install_payload
  boot_pass "payload verified: $VERIFIED_COUNT files, $CHANGED updated, $KEPT unchanged"
  boot_emit "ok payload $VERIFIED_COUNT files verified, $CHANGED updated"

  [ -x "$DSH_BASE/bin/dshd" ] || boot_die "$EXIT_PAYLOAD" "$DSH_BASE/bin/dshd is not executable after install"

  exec sh "$DSH_BASE/bin/dshd" "$@"
}

# Running this file by path (a person, a support session) has no payload on
# stdin, so it says how it is meant to be called instead of failing obscurely.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  boot_say "bootstrap.sh — install the dsh-android payload and hand over to dshd"
  boot_say ""
  boot_say "  normally: the app pipes payload.tar to 'su -c' and runs this by path"
  boot_say "  by hand:  sh bootstrap.sh --from DIR <dshd verb...>"
  exit 0
fi

boot_main "$@"
