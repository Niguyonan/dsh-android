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
#   su -c 'S=/data/local/dsh/.stage; rm -rf "$S"; (umask 077; mkdir -p "$S") &&
#          tar -xf - -C "$S" && exec sh "$S/bootstrap.sh" --from "$S" setup --app-uid 10123'
#
# --from is the other half of that command, not a convenience. The tar in front of
# it has read stdin to the end by the time this file starts, so a run left to
# extract the payload itself reads an empty stream, says `tar: Not tar`, and stops
# at "the payload did not extract" — on a phone, right after the install directory
# had passed, which is exactly what one reported. With --from the stage that tar
# just filled is the payload, and it goes through the same digest check as any
# other source: what is handed over is verified, not trusted because the app
# unpacked it.
#
# Every word of that is a constant in android/src/.../Shell.java, except the uid,
# which the app validates as numeric before it goes anywhere near a shell.
#
# What it does, in order:
#
#   1. refuse to run as anything but root (exit 2), so the app can tell "no root
#      granted" from every other failure with one number
#   2. make DSH_BASE safe before installing into it: it is where root-executed
#      scripts live, so it has to be a real directory, owned by root, that nobody
#      else can write to. A root-owned directory whose group or other write bits
#      are set is closed here rather than refused. It used to be refused, and on
#      a first run that directory had just been created by the app's own mkdir
#      under whatever umask the su shell was started with — so the setup refused
#      the directory it had made a line earlier and the person holding the phone,
#      who has no terminal by design, had nowhere to go. What cannot be fixed
#      still refuses: an owner that is not root, a symlink, a chmod that did not
#      take. See tests/payload.test.sh for both halves of that, and for the shell
#      on a phone whose arithmetic read the mode as decimal rather than octal
#   3. extract the tar, then verify every file against payload.sha256 *before*
#      installing any of it. A payload that arrived truncated fails here, by
#      digest, instead of half-installing and half-working
#   4. install with compare-then-rename, never by writing in place: bin/dshd may
#      be the running supervisor, and a shell reads its own script incrementally,
#      so truncating it under a live process makes the next line it parses come
#      from the new file at the old offset. Every directory it installs into is
#      made safe first, and a symlinked one is refused: a link there decides where
#      root writes
#   5. exec dshd, preserving its exit status
#
# Why the payload is an uncompressed tar: the only extractor guaranteed here is
# tar, and asking it for gzip support is one more thing that can be missing on
# the one path that has no fallback. It is the APK's asset compression that makes
# the file small, not gzip.
#
# Progress goes to stdout in the same `##dshd` protocol bin/dshd speaks, with the
# literal nonce `pre`, because these steps happen before dshd exists to have a
# nonce of its own. Every refusal is emitted as `fail <step> <reason>` on that
# protocol, not only as prose: the app renders the reason it is given, and a
# refusal that reached only the log pane left the screen saying "the payload did
# not verify" for what was in fact a directory mode.
#
# exit: 0 ok · 2 not root · 6 the payload did not verify or could not be
#       installed · 7 the install directory is not safe · otherwise dshd's own
#       status

set -u

umask 077

EXIT_NOT_ROOT=2
EXIT_PAYLOAD=6
EXIT_BASE=7

: "${DSH_BASE:=/data/local/dsh}"
STAGE="$DSH_BASE/.stage"
MANIFEST="payload.sha256"

FROM=""
# The step a refusal is attributed to, so the app can say which check refused.
CURRENT_STEP=pre

# --- output -----------------------------------------------------------------

boot_emit() {
  printf '##dshd pre %s\n' "$*"
}

# Announces a step and remembers its name: a later refusal is attributed to it,
# which is the difference between a screen that says "the install directory is
# not safe" and one that says "the payload did not verify".
boot_step() {
  CURRENT_STEP=$1
  shift
  boot_emit "step $CURRENT_STEP $*"
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
  boot_emit "fail $CURRENT_STEP $(printf '%s' "$*" | tr '\n' ' ')"
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
  boot_step root "checking for root"
  uid=$(id -u 2>/dev/null)
  if [ "$uid" != 0 ]; then
    boot_die "$EXIT_NOT_ROOT" "the shell is uid ${uid:-unknown}, not root: grant the app root in your root manager (Magisk, KernelSU or KernelSU-Next), then tap Set up again"
  fi
  boot_emit "ok root"
}

# A mode with its leading zeros removed, so the 700 one stat prints and the 0700
# another might compare equal. A mode is only ever handled as this string; every
# test below is on its digits, and none of them computes with it.
#
# That is the whole reason these two helpers exist. What a number with a leading
# zero *means* is the shell's decision, not ours: 0700 is 448 to dash and bash
# and 700 to the sh Android ships — mksh's, or toybox sh's, depending on the
# device — whose arithmetic reads it as decimal. So `$((mode & 022))` is 0 for an
# already-correct 0700 directory on a development host and 20 on a phone, and 20
# is nonzero: the phone refused its own install directory, exit 7, "the group or
# other write bits could not be closed on it", over a directory that had no write
# bits to close, with no terminal anywhere on the device to see why. Host tests
# cannot catch that by being thorough (they were, and it passed every one); they
# catch it by running the cases under a shell that reads leading zeros as
# decimal, which is what tests/payload.test.sh now does.
mode_digits() {
  digits=$1
  while [ "${digits#0}" != "$digits" ]; do
    digits=${digits#0}
  done
  [ -n "$digits" ] || digits=0
  printf '%s\n' "$digits"
}

# Whether group or other can write. In a mode string those bits are the `2`s of
# the last two octal digits, so a digit of 2, 3, 6 or 7 in either of those two
# positions is the entire test — no arithmetic for a shell to read differently,
# and no mask to get wrong. The setuid and setgid bits are not write bits and are
# deliberately not part of it: "2700" is a directory nobody but root can write,
# and this has nothing to say about it. ${1%??} is the mode without its last two
# digits, so for "2700" the two compared are "00" and not "27".
others_can_write() {
  rest=${1%??}
  last_two=${1#"$rest"}
  case "$last_two" in
    *[2367]*) return 0 ;;
  esac
  return 1
}

# Closes the group and other write bits on a directory root will run scripts
# from, then re-reads the mode rather than trusting chmod's exit status. Sets
# $TIGHTENED_FROM and $TIGHTENED_TO to the before and after modes, or leaves
# $TIGHTENED_FROM empty when there was nothing to do. Returns non-zero only when
# the directory is still writable by somebody else afterwards: continuing would
# mean root running whatever that somebody puts there. A directory that merely
# stayed group-readable is not a hole, and refusing over it would be the dead end
# this function exists to remove.
TIGHTENED_FROM=""
TIGHTENED_TO=""
tighten_dir() {
  dir=$1
  TIGHTENED_FROM=""
  TIGHTENED_TO=""
  mode=$(mode_of "$dir") || return 1
  mode=$(mode_digits "$mode")

  [ "$mode" = 700 ] && return 0

  chmod 700 "$dir" 2>/dev/null
  after=$(mode_of "$dir") || return 1
  after=$(mode_digits "$after")

  # Fatal first, whatever chmod claimed: if somebody other than root can still
  # write here, nothing below matters.
  others_can_write "$after" && return 1

  if [ "$after" = "$mode" ]; then
    # No write bits left and the chmod changed nothing — it failed, or the
    # directory was already closed to writing. Nothing to report, no claim to make.
    return 0
  fi
  TIGHTENED_FROM=$mode
  TIGHTENED_TO=$after

  if others_can_write "$mode"; then
    boot_warn "$dir was mode $mode: group- or other-writable, so another uid could replace the scripts root runs. It is mode $after now."
  else
    boot_warn "$dir was mode $mode; it is mode $after now, like the rest of the install"
  fi
  return 0
}

# The directory root will execute from. Owner and mode are the control: another
# uid that can write here is another uid that chooses what root runs.
#
# A mode that can be fixed is fixed. Refusing it outright is what this did first,
# and on a first run the directory it refused had just been created by the app's
# own `mkdir -p` under the su shell's umask — so the app was handed a setup that
# could not proceed and a screen that blamed the payload, on a device whose owner
# has no terminal by design.
check_base() {
  boot_step base "checking $DSH_BASE"

  # Not followed: `[ -d ]` and stat(1) both follow symlinks, so everything below
  # would be describing the target and not the path root is handed.
  if [ -L "$DSH_BASE" ]; then
    boot_die "$EXIT_BASE" "$DSH_BASE is a symlink: root runs scripts from this path, and it has to be a real directory root owns, not a link to one. Remove the link as root, then tap Set up again"
  fi

  if [ ! -e "$DSH_BASE" ]; then
    # -m 700 as well as the umask: this directory decides what root executes, and
    # its mode is not something to leave to whoever happened to call us. The
    # plain mkdir is the fallback for a mkdir without -m.
    mkdir -m 700 "$DSH_BASE" 2>/dev/null || mkdir "$DSH_BASE" 2>/dev/null ||
      boot_die "$EXIT_BASE" "cannot create $DSH_BASE"
    chmod 700 "$DSH_BASE" 2>/dev/null
    boot_emit "ok base created $DSH_BASE, mode $(mode_of "$DSH_BASE" 2>/dev/null)"
    return 0
  fi

  [ -d "$DSH_BASE" ] || boot_die "$EXIT_BASE" "$DSH_BASE exists and is not a directory"

  base_mode=$(mode_of "$DSH_BASE") || boot_die "$EXIT_BASE" "cannot read the mode of $DSH_BASE (no usable stat)"
  base_owner=$(owner_of "$DSH_BASE") || boot_die "$EXIT_BASE" "cannot read the owner of $DSH_BASE (no usable stat)"

  if [ "$base_owner" != "$(id -u)" ]; then
    boot_die "$EXIT_BASE" "$DSH_BASE is owned by uid $base_owner, not root: whoever owns it decides which scripts root runs, so this refuses to install into it. Remove it as root (a file manager running as root, or a recovery shell), then tap Set up again"
  fi

  if ! tighten_dir "$DSH_BASE"; then
    boot_die "$EXIT_BASE" "$DSH_BASE is mode $base_mode and the group or other write bits could not be closed on it: another uid could replace the scripts root runs. Remove it as root, then tap Set up again"
  fi

  if [ -n "$TIGHTENED_FROM" ]; then
    boot_emit "ok base $DSH_BASE was mode $TIGHTENED_FROM, now $TIGHTENED_TO"
  else
    boot_emit "ok base $DSH_BASE mode $base_mode, owner root"
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
  while read -r mode sum file; do
    # Comments carry the `#` in $mode, not in $file: reading the line splits it
    # into three words, so testing only the third word let every header line
    # through as a file named after the rest of the sentence. Blank lines leave
    # every one of them empty. The name is `file` and not `path` because zsh and
    # ksh93 tie `path` to PATH: a read into it replaces the search path, and the
    # sha256 and tr below then "do not exist". Android's sh does not tie them —
    # checked on a device — but the payload is POSIX sh, and a test that runs it
    # under a shell with that arithmetic would otherwise fail for this instead.
    [ -n "$mode" ] || continue
    [ -n "$file" ] || continue
    case "$mode" in *"#"*) continue ;; esac
    [ -f "$STAGE/$file" ] || boot_die "$EXIT_PAYLOAD" "$file is listed in the manifest but missing from the payload"
    actual=$(sha256_of "$STAGE/$file") ||
      boot_die "$EXIT_PAYLOAD" "cannot compute a sha256 on this device: no sha256sum, shasum, openssl or BusyBox. Refusing to install unverified files."
    if [ "$actual" != "$sum" ]; then
      boot_die "$EXIT_PAYLOAD" "$file does not match the manifest (expected ${sum%${sum#??????}}…, got ${actual%${actual#??????}}…)"
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
  while read -r mode sum file; do
    # The same three-word split as verify_payload, and the same reason for the
    # name: `path` is PATH in the shells that tie them, and this loop reads a
    # file name into it.
    [ -n "$mode" ] || continue
    [ -n "$file" ] || continue
    case "$mode" in *"#"*) continue ;; esac
    src="$STAGE/$file"
    dst="$DSH_BASE/$file"
    dir=$(dirname "$dst")
    # A symlinked install directory is not one we made, and it decides where root
    # writes. Refused rather than followed.
    if [ -L "$dir" ]; then
      boot_die "$EXIT_BASE" "the install directory $dir is a symlink: root would be writing wherever it points, so this refuses to install through it. Remove it as root, then tap Set up again"
    fi
    mkdir -p "$dir" || boot_die "$EXIT_PAYLOAD" "cannot create $dir"
    tighten_dir "$dir" ||
      boot_die "$EXIT_BASE" "the install directory $dir is writable by group or other and that could not be closed: another uid could replace what root runs. Remove it as root, then tap Set up again"
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

  boot_step payload "installing the app's payload"
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
