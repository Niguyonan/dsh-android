#!/bin/sh
# Host-side tests for tools/probe.sh — the Phase 0 gate.
#
# The probes themselves need a device; what is tested here is everything around
# them, because that is where a diagnostic tool does its damage: the argument
# contract, that it refuses to run without root (the probes are about what the su
# context may do), that it survives a host with none of Android's facilities
# instead of dying half way, that its verdicts follow the evidence, and that it
# is non-destructive — the one probe that touches netfilter must use its own
# scratch chain and clean up after itself.
#
# What it cannot test is the device: whether your kernel has Landlock, xt_owner,
# or a mountable SELinux context for su. That is what the script is for.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
PROBE="$REPO/tools/probe.sh"
REAL_ID=$(command -v id 2>/dev/null || true)

[ -f "$PROBE" ] || { echo "probe.sh not found at $PROBE" >&2; exit 1; }

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
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 5)" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "expected NOT to contain [$2]" ;;
    *) pass "$1" ;;
  esac
}

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
TMP=""
trap cleanup EXIT INT TERM

# --- environment ------------------------------------------------------------
#
# A host is not a device, so everything device-shaped is stubbed: `id` so the
# root gate passes, `su` so no password prompt can ever appear, and `iptables`
# so the owner-match probe has something to answer with.

make_env() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe-test.XXXXXX") || exit 1
  mkdir -p "$TMP/bin" "$TMP/dsh" "$TMP/adb/ksu/bin"
  : >"$TMP/iptables.log"

  cat >"$TMP/bin/id" <<EOF
#!/bin/sh
case "\${1:-}" in
  -u) printf '0\n' ;;
  *) exec "$REAL_ID" "\$@" ;;
esac
EOF
  chmod +x "$TMP/bin/id"

  # Never a real su: it would prompt for a password on a host and hang the suite.
  cat >"$TMP/bin/su" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$TMP/bin/su"

  # KernelSU, so the root section has something to detect.
  cat >"$TMP/adb/ksud" <<'EOF'
#!/bin/sh
printf 'v1.0.6 (uapi: 2)\n'
EOF
  chmod +x "$TMP/adb/ksud"

  make_iptables ok
}

# make_iptables ok        → the owner match is accepted (a capable kernel)
# make_iptables no-owner  → the owner match is rejected (no xt_owner)
make_iptables() {
  mode=$1
  cat >"$TMP/bin/iptables" <<EOF
#!/bin/sh
printf '%s %s\n' "\$0" "\$*" >>"$TMP/iptables.log"
case "\$*" in
  *FWMODE*) exit 0 ;;
esac
if [ "$mode" = "no-owner" ]; then
  case "\$*" in
    *--uid-owner*) echo "iptables: owner: Invalid argument" >&2; exit 1 ;;
  esac
fi
case "\${1:-}" in
  --version) printf 'iptables v1.8.7 (legacy)\n' ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/iptables"
}

probe() {
  PATH="$TMP/bin:$PATH" DSH_ADB="$TMP/adb" DSH_BASE="$TMP/dsh" DSH_ROOTFS="$TMP/dsh/rootfs" \
    /bin/sh "$PROBE" "$@"
}

# ===========================================================================

case_syntax() {
  if sh -n "$PROBE" 2>/dev/null; then pass "probe.sh parses under sh -n"; else fail "probe.sh parses under sh -n"; fi
}

case_contract() {
  make_env
  out=$(probe --help 2>&1)
  check "--help exits 0" "0" "$?"
  contains "help says how to use it" "usage: probe.sh" "$out"

  probe --nope >/dev/null 2>&1
  check "an unknown argument exits 1" "1" "$?"

  probe --save >/dev/null 2>&1
  check "--save without a path exits 1" "1" "$?"
}

case_refuses_non_root() {
  make_env
  # No id double: this is the real uid of the test runner.
  out=$(PATH="$TMP/bin-nothing:$PATH" DSH_ADB="$TMP/adb" DSH_BASE="$TMP/dsh" /bin/sh "$PROBE" 2>&1)
  rc=$?
  if [ "$(id -u)" = 0 ]; then
    check "running as root skips the refusal" "0" "0"
  else
    check "refuses to run without root" "2" "$rc"
    contains "and says why root is required" "must run as root" "$out"
  fi
}

# The whole script, start to finish, on a system that has none of Android's
# facilities. This is the test that catches an unguarded command or an unset
# variable in a branch no device would reach.
case_survives_a_host() {
  make_env
  out=$(probe 2>&1)
  rc=$?
  contains "produces the verdict block" "VERDICTS (gate P0)" "$out"
  contains "reports the P0 storage verdict" "P0 storage" "$out"
  contains "detects the root solution" "solution: kernelsu" "$out"
  contains "reports D3" "D3 confine" "$out"
  contains "reports the terminal verdict" "Terminal (D6)" "$out"
  contains "reports the §7 verdict" "§7 firewall" "$out"
  contains "summarises with a result line" "RESULT:" "$out"
  # A host has no proc/devpts from a su context: the run must fail loudly, not
  # quietly claim everything is fine.
  check "a host with no mountable context exits 1" "1" "$rc"
}

case_xt_owner_verdict_follows_evidence() {
  make_env
  make_iptables ok
  out=$(probe 2>&1)
  contains "a working owner match is reported as available" "§7 firewall   : AVAILABLE" "$out"

  make_env
  make_iptables no-owner
  out=$(probe 2>&1)
  contains "a missing owner match is reported as unavailable" "§7 firewall   : UNAVAILABLE" "$out"
  contains "and it is a critical failure" "critical probe(s) failed" "$out"
}

case_probe_is_non_destructive() {
  make_env
  make_iptables ok
  probe >/dev/null 2>&1

  used=$(cat "$TMP/iptables.log")
  contains "the scratch chain is created" "DSH_PROBE" "$used"
  contains "the scratch chain is removed" "-X DSH_PROBE" "$used"
  lacks "it never touches the real §7 chain" "DSH_ANDROID" "$used"
  lacks "it never touches built-in chains" "OUTPUT" "$used"
}

case_save_writes_a_report() {
  make_env
  probe --save "$TMP/report.txt" >/dev/null 2>&1
  if [ -s "$TMP/report.txt" ]; then pass "--save writes the report to a file"; else fail "--save writes the report to a file"; fi
  contains "the saved report holds the verdicts" "VERDICTS (gate P0)" "$(cat "$TMP/report.txt")"
}

# ===========================================================================

case_syntax
case_contract
case_refuses_non_root
case_survives_a_host
case_xt_owner_verdict_follows_evidence
case_probe_is_non_destructive
case_save_writes_a_report

printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
