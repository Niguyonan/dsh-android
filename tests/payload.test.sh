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
#   * it refuses a install directory that another uid could write to, because
#     that uid would then decide what root runs next
#   * a truncated transfer and a tampered file both end in exit 6 with nothing
#     installed, rather than a half-installed tree that mostly works
#   * the payload id is content-addressed: same tree, same id; changed byte,
#     changed id
#
# The device is stubbed, not simulated: `id` and `stat` are shell scripts in a
# directory put first on PATH, so `uid 0` and `mode 700` can be arranged on a
# development host that is neither.
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

sh "$MK" --out "$ASSETS" --quiet
check "a rebuild produces the same id" "$ID" "$(cat "$ASSETS/payload.id")"

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

stub_platform 0 777 0
BASE5="$TMP/base-world"
mkdir -p "$BASE5"
out=$(run_bootstrap "$BASE5" "$HANDOFF")
rc=$?
check "a world-writable base exits 6" "6" "$rc"
contains "and names the reason" "group or other writable" "$out"

stub_platform 0 700 501
BASE6="$TMP/base-other-owner"
mkdir -p "$BASE6"
out=$(run_bootstrap "$BASE6" "$HANDOFF")
rc=$?
check "a base owned by another uid exits 6" "6" "$rc"
contains "and names the reason" "not root" "$out"

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

out=$(PATH="$TMP/bin:$PATH" sh "$BOOT" --from "$TMP/nothing-here" "$HANDOFF" 2>&1)
rc=$?
check "a --from directory without a manifest exits 6" "6" "$rc"

printf '\n%d checks, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
