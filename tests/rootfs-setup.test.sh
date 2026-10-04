#!/bin/sh
# Host-side tests for tools/rootfs-setup.sh (Phase 1).
#
# The downloads are stubbed with local tarballs, which is the point: what is
# tested here is the part that goes wrong on a real device — a corrupt download
# that is not caught, a re-run that silently clobbers a rootfs, a resolver file
# written through a symlink, DNS not found and no fallback, and a verification
# step that "passes" because it never ran.
#
# What it cannot test is the device: whether the path executes, whether the
# chroot works, and whether the resulting Node is really glibc on aarch64. Those
# are Gate P1, and tools/probe.sh answers the first two.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
SETUP="$REPO/tools/rootfs-setup.sh"
REAL_ID=$(command -v id 2>/dev/null || true)

[ -f "$SETUP" ] || { echo "rootfs-setup.sh not found at $SETUP" >&2; exit 1; }

# --- tiny test framework ----------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0

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

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 4)" ;;
  esac
}

skip_note() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'skip %s (%s)\n' "$1" "$2"
}

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
TMP=""
trap cleanup EXIT INT TERM

# --- environment ------------------------------------------------------------

make_env() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/rootfs-test.XXXXXX") || exit 1
  mkdir -p "$TMP/bin" "$TMP/dsh"
  BASE="$TMP/dsh"

  # The script insists on root; the tests do not have it and must not need it,
  # because nothing here touches the real filesystem.
  cat >"$TMP/bin/id" <<EOF
#!/bin/sh
case "\${1:-}" in
  -u) printf '0\n' ;;
  *) exec "$REAL_ID" "\$@" ;;
esac
EOF
  chmod +x "$TMP/bin/id"

  # A stand-in "rootfs": enough for the script's own sanity checks, and cheap.
  make_base_tarball "$TMP/base-good.tar.gz"
  make_base_tarball "$TMP/base-other.tar.gz" other
}

# A tarball shaped like ubuntu-base-*: bin/sh plus one marker file so a test can
# prove which archive was unpacked.
make_base_tarball() {
  dest=$1
  marker=${2:-base-good}
  stage="$TMP/pack.$$"
  rm -rf "$stage"
  mkdir -p "$stage/bin" "$stage/etc" "$stage/usr/local/bin"
  printf '#!/bin/sh\nexit 0\n' >"$stage/bin/sh"
  chmod +x "$stage/bin/sh"
  printf '%s\n' "$marker" >"$stage/etc/dsh-test-marker"
  (cd "$stage" && tar -czf "$dest" .)
  rm -rf "$stage"
}

setup() {
  PATH="$TMP/bin:$PATH" DSH_BASE="$BASE" DSH_ROOTFS="$BASE/rootfs" \
    DSH_STATE="$BASE/state" DSH_WORKSPACE="$BASE/workspace" DSH_LOG="$BASE/log" \
    /bin/sh "$SETUP" "$@"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# ===========================================================================

case_syntax() {
  if sh -n "$SETUP" 2>/dev/null; then pass "rootfs-setup.sh parses under sh -n"; else fail "rootfs-setup.sh parses under sh -n"; fi
}

case_contract() {
  make_env
  setup --help >/dev/null 2>&1
  check "--help exits 0" "0" "$?"
  out=$(setup --help 2>&1)
  contains "help documents the options" "--base-file" "$out"
  contains "help says why glibc and not musl" "musl is explicitly the wrong" "$out"

  setup --nope >/dev/null 2>&1
  check "an unknown argument exits 1" "1" "$?"

  out=$(setup --base-file "$TMP/does-not-exist.tar.gz" --skip-node --skip-verify 2>&1)
  check "a missing --base-file exits 1" "1" "$?"
  contains "and names the path" "does not exist" "$out"
}

case_refuses_non_root() {
  make_env
  if [ "$(id -u)" = 0 ]; then
    pass "not-root refusal (running as root, nothing to refuse)"
    return 0
  fi
  # No id double: this is the runner's real uid.
  out=$(DSH_BASE="$BASE" DSH_ROOTFS="$BASE/rootfs" /bin/sh "$SETUP" 2>&1)
  check "refuses to run without root" "2" "$?"
  contains "and says what needs root" "must run as root" "$out"
}

case_extract_and_skeleton() {
  make_env
  out=$(setup --base-file "$TMP/base-good.tar.gz" --skip-node --skip-verify 2>&1)
  check "a local base tarball installs" "0" "$?"

  if [ -x "$BASE/rootfs/bin/sh" ]; then pass "the base image is unpacked"; else fail "the base image is unpacked"; fi
  if [ -f "$BASE/rootfs/etc/dsh-test-marker" ]; then pass "the unpacked content is the archive given"; else fail "the unpacked content is the archive given"; fi

  for d in proc sys dev dev/pts dev/shm tmp run workspace state opt/dsh-android usr/local; do
    if [ -d "$BASE/rootfs/$d" ]; then pass "skeleton: $d"; else fail "skeleton: $d"; fi
  done

  contains "resolv.conf is written" "nameserver" "$(cat "$BASE/rootfs/etc/resolv.conf" 2>/dev/null)"
  contains "hosts is written" "127.0.0.1 localhost" "$(cat "$BASE/rootfs/etc/hosts" 2>/dev/null)"

  # --skip-verify must say so. A verification step that quietly does not run is
  # how an unverified rootfs gets treated as a working one.
  contains "skipping Gate P1 is reported loudly" "NOT running Gate P1" "$out"
  contains "and the summary repeats it" "PARTIAL" "$out"
}

case_checksum() {
  make_env
  good=$(sha_of "$TMP/base-good.tar.gz")

  out=$(setup --base-file "$TMP/base-good.tar.gz" --base-sha256 "$good" --skip-node --skip-verify 2>&1)
  check "a matching checksum passes" "0" "$?"

  make_env
  out=$(setup --base-file "$TMP/base-good.tar.gz" --base-sha256 "0000000000000000000000000000000000000000000000000000000000000000" --skip-node --skip-verify 2>&1)
  check "a mismatched checksum exits 4" "4" "$?"
  contains "and says the download is not what it claims" "not what it claims to be" "$out"
  if [ -d "$BASE/rootfs/bin" ]; then
    fail "nothing is installed when the checksum fails"
  else
    pass "nothing is installed when the checksum fails"
  fi

  # No checksum at all: allowed for a local file, but never silent.
  make_env
  out=$(setup --base-file "$TMP/base-good.tar.gz" --skip-node --skip-verify 2>&1)
  contains "an unverified local file warns rather than pretends" "continuing unverified" "$out"
}

case_never_clobbers() {
  make_env
  setup --base-file "$TMP/base-good.tar.gz" --skip-node --skip-verify >/dev/null 2>&1

  out=$(setup --base-file "$TMP/base-other.tar.gz" --skip-node --skip-verify 2>&1)
  check "a second run over an existing rootfs exits 5" "5" "$?"
  contains "and says how to replace it" "--force" "$out"
  contains "and the marker is untouched" "base-good" "$(cat "$BASE/rootfs/etc/dsh-test-marker" 2>/dev/null)"

  out=$(setup --base-file "$TMP/base-other.tar.gz" --force --skip-node --skip-verify 2>&1)
  check "--force replaces it" "0" "$?"
  check "with the new archive" "other" "$(cat "$BASE/rootfs/etc/dsh-test-marker" 2>/dev/null)"
}

case_resolv_symlink() {
  make_env
  # Some Ubuntu base releases ship resolv.conf as a symlink into /run; writing
  # through it would create the target and leave the file the chroot actually
  # reads missing. The image is patched to reproduce that shape.
  stage="$TMP/pack-symlink"
  rm -rf "$stage"
  mkdir -p "$stage/bin" "$stage/etc" "$stage/run/systemd/resolve"
  printf '#!/bin/sh\nexit 0\n' >"$stage/bin/sh"
  chmod +x "$stage/bin/sh"
  ln -s /run/systemd/resolve/stub-resolv.conf "$stage/etc/resolv.conf"
  (cd "$stage" && tar -czf "$TMP/base-symlink.tar.gz" .)
  rm -rf "$stage"

  out=$(setup --base-file "$TMP/base-symlink.tar.gz" --skip-node --skip-verify 2>&1)
  check "a symlinked resolv.conf still installs" "0" "$?"
  if [ -L "$BASE/rootfs/etc/resolv.conf" ]; then
    fail "the symlink is replaced by a real file"
  else
    pass "the symlink is replaced by a real file"
  fi
  contains "and the chroot's resolv.conf has nameservers" "nameserver" "$(cat "$BASE/rootfs/etc/resolv.conf" 2>/dev/null)"
}

case_dry_run_changes_nothing() {
  make_env
  out=$(setup --base-file "$TMP/base-good.tar.gz" --dry-run 2>&1)
  check "dry-run exits 0" "0" "$?"
  contains "dry-run says what it would do" "dry-run: would extract" "$out"
  if [ -d "$BASE/rootfs" ]; then fail "dry-run creates no rootfs"; else pass "dry-run creates no rootfs"; fi
}

case_dns_fallback() {
  make_env
  # No getprop on a host, so the fallback path is what runs; assert it happens
  # and is announced rather than being silently a guess.
  out=$(setup --base-file "$TMP/base-good.tar.gz" --skip-node --skip-verify 2>&1)
  contains "a device with no DNS properties is told about the fallback" "no DNS servers found" "$out"
  body=$(cat "$BASE/rootfs/etc/resolv.conf" 2>/dev/null)
  contains "the fallback resolvers are written" "nameserver 1.1.1.1" "$body"
}

# The one case where the script reads a *listing* rather than a file named on the
# command line — which is what a device does, and what "install the newest
# ubuntu-base" means. The network is the stubbed part: a `curl` in the test's PATH
# answers the three URLs `fetch` asks for, from files the test wrote. Everything
# else is the script's own code, including `discover_base_file` and the log line
# that used to end up inside the file name.
#
# It is here because every other case hands the script a local tarball, so nothing
# ran discovery: `fetch` logs on stdout, the caller captures stdout, and the name
# came back as
#
#   "2026-10-04T12:31:11+0800 rootfs-setup: fetching https://…/release/\n
#    ubuntu-base-24.04.5-base-arm64.tar.gz"
#
# — a URL with a timestamp and a newline in it. On the phone, curl refused it
# ("URL rejected: Malformed input to a URL function") and BusyBox wget answered
# 400 Bad Request, and the step's error message blamed the network.
case_discovers_from_a_listing() {
  make_env
  make_base_tarball "$TMP/base-older.tar.gz" older
  make_base_tarball "$TMP/base-newest.tar.gz" newest
  # Two point releases in the listing, the newer one *first* so that taking the
  # newest cannot be an accident of order — and 24.04.5 against 24.04.10, which
  # lexically sorts the wrong way, is the comparison the script does by hand.
  cat >"$TMP/listing.txt" <<'EOF'
<a href="ubuntu-base-24.04.5-base-arm64.tar.gz">ubuntu-base-24.04.5-base-arm64.tar.gz</a>
<a href="ubuntu-base-24.04.10-base-arm64.tar.gz">ubuntu-base-24.04.10-base-arm64.tar.gz</a>
<a href="ubuntu-base-24.04.1-base-arm64.tar.gz">ubuntu-base-24.04.1-base-arm64.tar.gz</a>
EOF
  printf '%s  %s\n' "$(sha_of "$TMP/base-newest.tar.gz")" "ubuntu-base-24.04.10-base-arm64.tar.gz" \
    >"$TMP/SHA256SUMS"

  # A curl that logs nothing and answers by destination, the way the real one
  # answers by URL: fetch's own `log` line is what the test is about.
  cat >"$TMP/bin/curl" <<EOF
#!/bin/sh
dest=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; dest=\$1 ;;
  esac
  shift
done
case "\$dest" in
  */.listing) cp "$TMP/listing.txt" "\$dest" ;;
  *SHA256SUMS) cp "$TMP/SHA256SUMS" "\$dest" ;;
  *) cp "$TMP/base-newest.tar.gz" "\$dest" ;;
esac
EOF
  chmod +x "$TMP/bin/curl"

  # DSH_BASE_URL is the mirror knob the script reads — what makes this case
  # possible without a network. The stub answers whatever it is asked, so the
  # assertion below is about the URL the script *built*, not about the answer.
  MIRROR="https://cdimage.example/ubuntu-base/releases/24.04/release"
  out=$(DSH_BASE_URL="$MIRROR" setup --skip-node --skip-verify 2>&1)
  rc=$?
  check "a listing is read and the base image installed from it" "0" "$rc"
  check "the newest point release wins, not the first line or the lexical order" "newest" \
    "$(cat "$BASE/rootfs/etc/dsh-test-marker" 2>/dev/null)"
  contains "and it is named on its own" "newest base image: ubuntu-base-24.04.10-base-arm64.tar.gz" "$out"
  contains "and fetched by that name" "$MIRROR/ubuntu-base-24.04.10-base-arm64.tar.gz" "$out"
  case "$out" in
    *"release/20"*) fail "the name carries no log line" "$(printf '%s' "$out" | head -n 3)" ;;
    *) pass "the name carries no log line" ;;
  esac
}

# ===========================================================================

case_syntax
case_contract
case_refuses_non_root
case_extract_and_skeleton
case_checksum
case_never_clobbers
case_resolv_symlink
case_dry_run_changes_nothing
case_dns_fallback
case_discovers_from_a_listing

printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
