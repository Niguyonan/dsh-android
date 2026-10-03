#!/bin/sh
# Host-side tests for the payload pipeline: tools/mkpayload.sh and
# android/payload/bootstrap.sh.
#
# This is the path by which root-executed scripts reach a phone, so the tests are
# about what *cannot* get through as much as what can:
#
#   * the archive carries exactly the manifested files — no AppleDouble junk from
#     the macOS host that built it, no tests/, no docs/, no path that escapes the
#     install directory (../, /etc)
#   * the bootstrap verifies every file by digest *before* installing any of it,
#     and refuses to install anything at all when it cannot verify
#   * it makes the install directory safe: a root-owned one whose mode is not
#     0700 is fixed, because on a first run the app's own mkdir created it under
#     the su shell's umask and refusing it meant refusing ourselves. What it
#     cannot fix — another uid's directory, a symlink, a chmod that did not take
#     — ends in exit 7 with nothing installed, and with `fail base` on the
#     protocol so the app can say which check refused instead of blaming the
#     payload
#   * a truncated transfer and a tampered file both end in exit 6 with nothing
#     installed, rather than a half-installed tree that mostly works
#   * the payload id is content-addressed: same tree, same id; changed byte,
#     changed id
#
# The device is stubbed, not simulated: `id` and `stat` are shell scripts in a
# directory put first on PATH, so `uid 0` and `mode 700` can be arranged on a
# development host that is neither. The mode cases stub `id` alone and use the
# real filesystem: the failure that reached a phone was a real directory with a
# real mode, and a stubbed stat agrees with whatever the script believes.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
MK="$REPO/tools/mkpayload.sh"
BOOT="$REPO/android/payload/bootstrap.sh"

[ -f "$MK" ] || { echo "mkpayload.sh not found at $MK" >&2; exit 1; }
[ -f "$BOOT" ] || { echo "bootstrap.sh not found at $BOOT" >&2; exit 1; }

# --- tiny test framework ----------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '     %s\n' "$2"
  return 0
}

skip() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf 'skip %s (%s)\n' "$1" "${2:-}"
}

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 8)" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "did not expect [$2] in: $(printf '%s' "$3" | tail -n 8)" ;;
    *) pass "$1" ;;
  esac
}

# --- environment ------------------------------------------------------------

TMP=""
BACKUP=""
cleanup() {
  # Anything this suite edited in the working tree is put back, whatever happened.
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$REPO/android/payload/bootstrap.sh"
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# A platform where the caller is root and owns a 0700 tree. $1 is the uid to
# report, $2 the mode, $3 the owner — so a case can arrange "not root", "someone
# else's directory", or "world-writable".
stub_platform() {
  uid=$1
  mode=$2
  owner=$3
  mkdir -p "$TMP/bin"
  {
    printf '#!/bin/sh\n'
    printf 'echo %s\n' "$uid"
  } >"$TMP/bin/id"
  {
    printf '#!/bin/sh\n'
    printf 'case "$1 $2" in\n'
    printf '  "-c %%a") echo %s ;;\n' "$mode"
    printf '  "-c %%u") echo %s ;;\n' "$owner"
    printf '  *) exit 1 ;;\n'
    printf 'esac\n'
  } >"$TMP/bin/stat"
  chmod 755 "$TMP/bin/id" "$TMP/bin/stat"
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The bootstrap with the platform stubbed, its payload on stdin.
run_bootstrap() {
  base=$1
  shift
  cat "$ASSETS/payload.tar" | PATH="$TMP/bin:$PATH" DSH_BASE="$base" sh "$BOOT" "$@" 2>&1
}

run_bootstrap_file() {
  base=$1
  tarfile=$2
  shift 2
  cat "$tarfile" | PATH="$TMP/bin:$PATH" DSH_BASE="$base" sh "$BOOT" "$@" 2>&1
}

# Only the two identities a development host cannot arrange are faked: `id -u`
# reports 0, and stat's owner reports 0. Everything else is real — stat's *mode*,
# chmod, the filesystem — so the mode arithmetic and the read-back after chmod are
# the real thing. That is deliberate: the failure that reached a phone was a real
# directory with a real mode, and a stubbed mode agrees with whatever the script
# believes.
REAL_STAT=$(command -v stat)
case "$REAL_STAT" in /*) ;; *) REAL_STAT=/usr/bin/stat ;; esac

write_root_stub() {
  mkdir -p "$1"
  printf '#!/bin/sh\ncase "$1" in -u) echo 0 ;; *) exit 1 ;; esac\n' >"$1/id"
  {
    printf '#!/bin/sh\n'
    printf 'case "$1 $2" in\n'
    printf '  "-c %%u") echo 0 ;;\n'
    printf '  *) exec %s "$@" ;;\n' "$REAL_STAT"
    printf 'esac\n'
  } >"$1/stat"
  chmod 755 "$1/id" "$1/stat"
}

stub_root_owner() { write_root_stub "$TMP/bin-root"; }

run_bootstrap_real() {
  base=$1
  shift
  cat "$ASSETS/payload.tar" | PATH="$TMP/bin-root:$PATH" DSH_BASE="$base" sh "$BOOT" "$@" 2>&1
}

host_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# `version` is the verb that exercises the whole bootstrap and stops at the hand
# over: it installs everything, then asks the real bin/dshd for one line, without
# touching a rootfs, a mount, or the network.
HANDOFF="version"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/payload-test.XXXXXX") || exit 1
ASSETS="$TMP/assets"

# --- mkpayload --------------------------------------------------------------

printf '\n== mkpayload ==\n'

out=$(sh "$MK" --out "$ASSETS" 2>&1)
rc=$?
check "mkpayload exits 0" "0" "$rc"
check "payload.tar is written" "yes" "$([ -f "$ASSETS/payload.tar" ] && echo yes || echo no)"
check "payload.id is written" "yes" "$([ -f "$ASSETS/payload.id" ] && echo yes || echo no)"

ID=$(cat "$ASSETS/payload.id")
check "payload.id looks like a sha256" "64" "$(printf '%s' "$ID" | wc -c | tr -d ' ')"

MANIFEST=$(tar -xOf "$ASSETS/payload.tar" payload.sha256 2>/dev/null)
inside=$(printf '%s\n' "$MANIFEST" | sed -n 's/^# payload-id: //p')
check "the manifest carries the same id" "$ID" "$inside"

members=$(tar -tf "$ASSETS/payload.tar" | sed -e 's|^\./||' | grep -v '/$' | grep . | LC_ALL=C sort)
expected=$(printf '%s\n' \
  bin/dshd \
  boot/service.d/dshd.sh \
  bootstrap.sh \
  guard/guard.mjs \
  payload.sha256 \
  tools/confinement-check.sh \
  tools/firewall.sh \
  tools/install-harness.sh \
  tools/probe.sh \
  tools/rootfs-setup.sh | LC_ALL=C sort)
check "the archive carries exactly the expected files" "$expected" "$members"

lacks "no AppleDouble members" "._" "$(tar -tf "$ASSETS/payload.tar")"

case "$(tar -tf "$ASSETS/payload.tar" | grep -E '^(/|\.\./)' || true)" in
  '') pass "no absolute or parent-relative member" ;;
  *) fail "no absolute or parent-relative member" "$(tar -tf "$ASSETS/payload.tar" | grep -E '^(/|\.\./)')" ;;
esac

case "$(tar -tf "$ASSETS/payload.tar" | grep -E '(^|/)\.\.(/|$)' || true)" in
  '') pass "no member escapes the install directory" ;;
  *) fail "no member escapes the install directory" "$(tar -tf "$ASSETS/payload.tar")" ;;
esac

lacks "tests/ is not shipped to a phone" "tests/" "$members"
lacks "docs/ is not shipped to a phone" "docs/" "$members"

declared=$(printf '%s\n' "$MANIFEST" | sed -n 's/^# files: //p')
counted=$(printf '%s\n' "$MANIFEST" | grep -cE '^[0-7]{3,4} [0-9a-f]{64} ')
check "the manifest's file count matches its lines" "$declared" "$counted"

# The id is a digest of this body, so the body's order is what keeps the id still
# while the archive's bytes move: two tar implementations write directory members
# in the filesystem's readdir order, which is not the same order on two machines —
# see the measurement in docs/engineering.md. The body's order is the list in
# mkpayload.sh, a literal in the script, and it is *not* sorted: an earlier version
# of these comments said "sorted", and writing this check is what disproved it.
# Being about provenance, it catches an implementation that walks the filesystem
# only on a filesystem whose readdir order differs from the list; the cross-host
# guard is the id comparison between a local build and the one CI makes, which is
# how all of this was found.
manifest_lines=$(printf '%s\n' "$MANIFEST" | grep -E '^[0-7]{3,4} [0-9a-f]{64} ')
check "the manifest's order is mkpayload.sh's list, not the filesystem's" \
  "$(sed -n '/^MANIFEST_FILES="/,/^"$/p' "$MK" | awk 'NF==3 { print $3 }')" \
  "$(printf '%s\n' "$manifest_lines" | awk '{ print $3 }')"

# Every tool dshd drives must be in the payload, derived from dshd rather than
# listed here: adding a step that runs a tool nobody ships is the mistake this
# catches. One name is expected to be missing, and it is named rather than
# filtered out: doctor.sh is a Phase 6 tool that `dshd doctor` runs only "if
# installed", so its absence is the designed state. Any second name failing this
# check is a real omission.
driven=$(grep -o '\$DSH_BASE/tools/[a-z-]*\.sh' "$REPO/bin/dshd" | sed 's|.*/||' | LC_ALL=C sort -u)
missing=""
for tool in $driven; do
  printf '%s\n' "$members" | grep -qx "tools/$tool" || missing="$missing $tool"
done
check "the only tool missing from the payload is the optional doctor.sh" " doctor.sh" "$missing"

# --- id stability -----------------------------------------------------------

printf '\n== payload id ==\n'

cp "$ASSETS/payload.tar" "$TMP/first.tar"
# A second apart on purpose: a tar header stores whole seconds, so two builds in
# the same one agree even when the archive carries the clock. This check spent a
# while proving nothing for that reason, and the flake it caused showed up in a
# different suite.
sleep 1
sh "$MK" --out "$ASSETS" --quiet
check "a rebuild produces the same id" "$ID" "$(cat "$ASSETS/payload.id")"
if cmp -s "$TMP/first.tar" "$ASSETS/payload.tar"; then
  pass "a rebuild a second later is byte-identical"
else
  fail "a rebuild a second later is byte-identical" \
    "$(cmp -l "$TMP/first.tar" "$ASSETS/payload.tar" 2>&1 | head -2 | tr '\n' ' ')"
fi

# The same tree, built somewhere else in the world. `touch -t` reads its argument
# as *local* time, so the fixed mtime was only fixed within one timezone: the
# released 0.1.1 APK, built on a UTC runner, differed from the build of the same
# commit on this machine at byte 104 -- the first header's mtime field -- while
# `payload.id`, which is over the manifest body and not over the tar bytes,
# matched. Two zones that are nowhere near each other, so the check cannot pass
# because the host happens to agree with itself.
TZ=UTC-14 sh "$MK" --out "$TMP/tz-a" --quiet
TZ=UTC+12 sh "$MK" --out "$TMP/tz-b" --quiet
if cmp -s "$TMP/tz-a/payload.tar" "$TMP/tz-b/payload.tar"; then
  pass "the archive does not depend on the builder's timezone"
else
  fail "the archive does not depend on the builder's timezone" \
    "$(cmp -l "$TMP/tz-a/payload.tar" "$TMP/tz-b/payload.tar" 2>&1 | head -2 | tr '\n' ' ')"
fi
check "and neither does the id" "$(cat "$TMP/tz-a/payload.id")" "$(cat "$TMP/tz-b/payload.id")"

# And the value itself, read out of the first header: 2000-01-01T00:00:00Z in
# octal, which is what `TZ=UTC0 touch -t 200001010000` produces. Stated as bytes
# rather than as "the two builds agree", because two builds agreeing is also what
# a wrong-but-consistent mtime looks like.
check "the first member's mtime is the UTC epoch, not the builder's" "07033241600" \
  "$(dd if="$ASSETS/payload.tar" bs=1 skip=136 count=11 2>/dev/null)"

BACKUP="$TMP/bootstrap.sh.orig"
cp "$REPO/android/payload/bootstrap.sh" "$BACKUP"
printf '\n# a byte that was not there before\n' >>"$REPO/android/payload/bootstrap.sh"
sh "$MK" --out "$ASSETS" --quiet
changed=$(cat "$ASSETS/payload.id")
cp "$BACKUP" "$REPO/android/payload/bootstrap.sh"
BACKUP=""
sh "$MK" --out "$ASSETS" --quiet
restored=$(cat "$ASSETS/payload.id")

case "$changed" in
  "$ID") fail "one changed byte changes the id" "the id did not move" ;;
  *) pass "one changed byte changes the id" ;;
esac
check "restoring the byte restores the id" "$ID" "$restored"

check "--check accepts what it just built" "0" "$(sh "$MK" --out "$ASSETS" --check >/dev/null 2>&1; echo $?)"
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$ASSETS/payload.id"
check "--check rejects a mismatched id" "4" "$(sh "$MK" --out "$ASSETS" --check >/dev/null 2>&1; echo $?)"
sh "$MK" --out "$ASSETS" --quiet

# --- bootstrap: the happy path ----------------------------------------------

printf '\n== bootstrap install ==\n'

stub_platform 0 700 0
BASE="$TMP/base"
out=$(run_bootstrap "$BASE" "$HANDOFF")
rc=$?
check "bootstrap hands over to dshd" "0" "$rc"
contains "it reports the root check" "##dshd pre ok root" "$out"
contains "it reports the payload step" "##dshd pre step payload" "$out"
contains "it reports the payload verified" "##dshd pre ok payload" "$out"
contains "and dshd answers" "1" "$out"

check "bin/dshd is installed" "yes" "$([ -f "$BASE/bin/dshd" ] && echo yes || echo no)"
check "bin/dshd is executable" "yes" "$([ -x "$BASE/bin/dshd" ] && echo yes || echo no)"
check "the guard is installed" "yes" "$([ -f "$BASE/guard/guard.mjs" ] && echo yes || echo no)"
check "the manifest lands in the base" "yes" "$([ -f "$BASE/payload.sha256" ] && echo yes || echo no)"

installed_sum=$(sha256_of_file "$BASE/bin/dshd")
manifest_sum=$(printf '%s\n' "$MANIFEST" | awk '$3 == "bin/dshd" { print $2 }')
check "the installed file matches the manifest digest" "$manifest_sum" "$installed_sum"

out=$(run_bootstrap "$BASE" "$HANDOFF")
contains "a second run updates nothing" "0 updated" "$out"
contains "a second run keeps every file" "9 unchanged" "$out"

# --- bootstrap: tampering ---------------------------------------------------

printf '\n== bootstrap refuses a bad payload ==\n'

FROM="$TMP/from"
mkdir -p "$FROM"
tar -xf "$ASSETS/payload.tar" -C "$FROM" || fail "cannot extract the payload for tampering"
printf '\n# tampered\n' >>"$FROM/tools/firewall.sh"
BASE2="$TMP/base-tampered"
out=$(PATH="$TMP/bin:$PATH" DSH_BASE="$BASE2" sh "$BOOT" --from "$FROM" "$HANDOFF" 2>&1)
rc=$?
check "a tampered file exits 6" "6" "$rc"
contains "and says which file" "tools/firewall.sh does not match the manifest" "$out"
check "and installs nothing" "no" "$([ -e "$BASE2/bin" ] && echo yes || echo no)"

BASE3="$TMP/base-truncated"
head -c 4000 "$ASSETS/payload.tar" >"$TMP/truncated.tar"
out=$(run_bootstrap_file "$BASE3" "$TMP/truncated.tar" "$HANDOFF")
rc=$?
check "a truncated transfer exits 6" "6" "$rc"
check "and installs nothing" "no" "$([ -e "$BASE3/bin" ] && echo yes || echo no)"

BASE4="$TMP/base-nohash"
mkdir -p "$TMP/nohash"
for tool in sha256sum shasum openssl busybox; do
  printf '#!/bin/sh\nexit 127\n' >"$TMP/nohash/$tool"
  chmod 755 "$TMP/nohash/$tool"
done
out=$(cat "$ASSETS/payload.tar" | PATH="$TMP/nohash:$TMP/bin:$PATH" DSH_BASE="$BASE4" sh "$BOOT" "$HANDOFF" 2>&1)
rc=$?
check "no sha256 tool exits 6" "6" "$rc"
contains "and says why" "cannot compute a sha256" "$out"
check "and installs nothing" "no" "$([ -e "$BASE4/bin" ] && echo yes || echo no)"

# --- bootstrap: who owns the install directory ------------------------------

printf '\n== bootstrap checks the install directory ==\n'

# A stub that keeps reporting 777 whatever chmod does, so the read-back after
# chmod is what decides. Fail closed: a directory another uid can write is a
# directory that chooses what root runs next.
stub_platform 0 777 0
BASE5="$TMP/base-world"
mkdir -p "$BASE5"
out=$(run_bootstrap "$BASE5" "$HANDOFF")
rc=$?
check "a mode that will not close exits 7" "7" "$rc"
contains "and says the write bits could not be closed" "could not be closed" "$out"
contains "and the app is told which check refused" "##dshd pre fail base" "$out"
check "and installs nothing" "no" "$([ -e "$BASE5/bin" ] && echo yes || echo no)"

stub_platform 0 700 501
BASE6="$TMP/base-other-owner"
mkdir -p "$BASE6"
out=$(run_bootstrap "$BASE6" "$HANDOFF")
rc=$?
check "a base owned by another uid exits 7" "7" "$rc"
contains "and names the owner" "owned by uid 501, not root" "$out"
check "and installs nothing" "no" "$([ -e "$BASE6/bin" ] && echo yes || echo no)"

# --- bootstrap: a real directory with a real mode ---------------------------
#
# The stub above arranges a mode string; these use the filesystem, because the
# failure that reached a phone was a real 0775 directory created by the app's own
# `mkdir -p` under the umask the su shell happened to have. Refusing it was
# refusing a directory the app itself had just made, and what the person holding
# the phone saw was "the payload did not verify".

printf '\n== bootstrap fixes a directory it can fix ==\n'

stub_root_owner

REAL1="$TMP/real-775"
( umask 002; mkdir -p "$REAL1" )
out=$(run_bootstrap_real "$REAL1" "$HANDOFF")
rc=$?
check "a real 0775 base is fixed rather than refused" "0" "$rc"
fixed_mode=$(host_mode "$REAL1")
check "and ends up 0700" "700" "$fixed_mode"
check "and nobody else can write to it" "0" "$((0$fixed_mode & 022))"
contains "it says what the mode was" "was mode 775" "$out"
contains "and what it is now" "now 700" "$out"
contains "and the base step reports ok" "##dshd pre ok base" "$out"
check "and the payload is installed anyway" "yes" \
  "$([ -x "$REAL1/bin/dshd" ] && echo yes || echo no)"

REAL0="$TMP/real-755"
( umask 022; mkdir -p "$REAL0" )
out=$(run_bootstrap_real "$REAL0" "$HANDOFF")
rc=$?
check "a 0755 base is tightened to 0700 too" "0" "$rc"
check "and ends up 0700" "700" "$(host_mode "$REAL0")"
lacks "and is not described as writable by others, because it was not" \
  "group- or other-writable" "$out"

REALN="$TMP/real-new"
out=$(run_bootstrap_real "$REALN" "$HANDOFF")
rc=$?
check "a base that does not exist is created" "0" "$rc"
check "and created 0700" "700" "$(host_mode "$REALN")"
contains "and it says so" "created $REALN, mode 700" "$out"

printf '\n== bootstrap refuses what it cannot fix ==\n'

# A base that is a symlink: every check below it would describe the target, and
# stat(1) would follow the link rather than look at the path root is handed.
REALT="$TMP/real-target"
mkdir -p "$REALT"
LINK="$TMP/base-link"
ln -s "$REALT" "$LINK"
out=$(run_bootstrap_real "$LINK" "$HANDOFF")
rc=$?
check "a symlinked base exits 7" "7" "$rc"
contains "and says it is a link" "is a symlink" "$out"
check "and installs nothing behind it" "no" "$([ -e "$REALT/bin" ] && echo yes || echo no)"

# An install directory that is a symlink: root would write wherever it points.
REALS="$TMP/real-symlink"
mkdir -p "$REALS/bin-target"
ln -s "$REALS/bin-target" "$REALS/bin"
out=$(run_bootstrap_real "$REALS" "$HANDOFF")
rc=$?
check "a symlinked install directory exits 7" "7" "$rc"
contains "and says why it will not follow it" "refuses to install through it" "$out"
check "and writes nothing through it" "no" \
  "$([ -e "$REALS/bin-target/dshd" ] && echo yes || echo no)"

# chmod that does not close the bits, on a directory that needs it. The mode is
# read back rather than trusted, so this is caught.
REAL4="$TMP/real-nofix"
( umask 002; mkdir -p "$REAL4" )
write_root_stub "$TMP/bin-nochmod"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin-nochmod/chmod"
chmod 755 "$TMP/bin-nochmod/chmod"
out=$(cat "$ASSETS/payload.tar" | PATH="$TMP/bin-nochmod:$PATH" DSH_BASE="$REAL4" \
  sh "$BOOT" "$HANDOFF" 2>&1)
rc=$?
check "a chmod that closes nothing exits 7" "7" "$rc"
check "and the directory is still 0775" "775" "$(host_mode "$REAL4")"
check "and installs nothing" "no" "$([ -e "$REAL4/bin" ] && echo yes || echo no)"

# --- bootstrap: not root ----------------------------------------------------

stub_platform 2000 700 2000
BASE7="$TMP/base-nonroot"
out=$(run_bootstrap "$BASE7" "$HANDOFF")
rc=$?
check "a non-root shell exits 2" "2" "$rc"
contains "and says so on the protocol" "##dshd pre fail root" "$out"
check "and touches nothing" "no" "$([ -e "$BASE7" ] && echo yes || echo no)"

# --- bootstrap: its own CLI -------------------------------------------------

stub_platform 0 700 0
out=$(PATH="$TMP/bin:$PATH" sh "$BOOT" --help 2>&1)
rc=$?
check "bootstrap --help exits 0" "0" "$rc"
contains "and explains the by-hand path" "--from DIR" "$out"

out=$(PATH="$TMP/bin:$PATH" DSH_BASE="$TMP/base-from-empty" sh "$BOOT" \
  --from "$TMP/nothing-here" "$HANDOFF" 2>&1)
rc=$?
check "a --from directory without a manifest exits 6" "6" "$rc"

printf '\n%d checks, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
