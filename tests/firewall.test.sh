#!/bin/sh
# Host-side tests for tools/firewall.sh — the §7 reachability control.
#
# No device and no netfilter: the tool is driven against a fake iptables that
# keeps the rule table in a file. That is enough to test what is actually
# error-prone here — chain creation, rule order, verification, idempotence,
# removal, and the failure path when the kernel lacks the owner match.
#
# What it cannot test: netfilter itself, and whether Android's kernel ships
# xt_owner (a Phase 0 probe). A green run here means the rule set is right, not
# that the device enforces it; docs/security.md has the on-device procedure.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
FW="$REPO/tools/firewall.sh"
REAL_ID=$(command -v id 2>/dev/null || true)
APP_UID=10123

[ -f "$FW" ] || { echo "firewall.sh not found at $FW" >&2; exit 1; }

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
    *) fail "$1" "expected to contain [$2] in: $3" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "expected NOT to contain [$2] in: $3" ;;
    *) pass "$1" ;;
  esac
}

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
TMP=""
trap cleanup EXIT INT TERM

# --- fake iptables ----------------------------------------------------------

make_env() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fw-test.XXXXXX") || exit 1
  FW_STATE="$TMP/rules"
  FW_LOG="$TMP/invocations"
  # The built-in chains exist before anything is created, exactly as on a device.
  {
    for f in "$FW_STATE" "$FW_STATE.v6"; do
      {
        printf 'chain PREROUTING\n'
        printf 'chain INPUT\n'
        printf 'chain FORWARD\n'
        printf 'chain OUTPUT\n'
        printf 'chain POSTROUTING\n'
      } >"$f"
    done
  }
  : >"$FW_LOG"
  mkdir -p "$TMP/bin"

  cat >"$TMP/bin/iptables" <<'EOS'
#!/bin/sh
# Fake iptables: just enough CLI to hold a rule table in a file, so the tool's
# logic is testable without netfilter. State lines are "chain NAME" and
# "rule NAME <args>".
# One table per program: a device has both iptables and ip6tables, and if they
# shared a state file the v6 side would see the v4 chains already present.
case "$0" in
  *ip6tables) state="${FW_STATE:?}.v6" ;;
  *) state="${FW_STATE:?}" ;;
esac
printf '%s %s\n' "$0" "$*" >>"${FW_LOG:-/dev/null}"
cmd=${1:-}
shift

ensure_chain() {
  grep -q "^chain $1\$" "$state" || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
}

owner_ok() {
  if [ "${FW_FAIL_OWNER:-0}" = 1 ]; then
    case " $* " in
      *" --uid-owner "*) echo "iptables: owner: Invalid argument" >&2; exit 1 ;;
    esac
  fi
}

case "$cmd" in
  -N)
    grep -q "^chain $1\$" "$state" && { echo "iptables: Chain already exists." >&2; exit 1; }
    printf 'chain %s\n' "$1" >>"$state"
    ;;
  -F)
    ensure_chain "$1"
    grep -v "^rule $1 " "$state" >"$state.new"; mv "$state.new" "$state"
    ;;
  -X)
    ensure_chain "$1"
    grep -q "^rule $1 " "$state" && { echo "iptables: Directory not empty." >&2; exit 1; }
    grep -v "^chain $1\$" "$state" >"$state.new"; mv "$state.new" "$state"
    ;;
  -A)
    chain=$1; shift
    owner_ok "$@"
    ensure_chain "$chain"
    printf 'rule %s %s\n' "$chain" "$*" >>"$state"
    ;;
  -I)
    chain=$1; shift 2 # drop the chain and the position; position is not modelled
    owner_ok "$@"
    ensure_chain "$chain"
    printf 'rule %s %s\n' "$chain" "$*" >>"$state"
    ;;
  -C)
    chain=$1; shift
    grep -qxF "rule $chain $*" "$state" || exit 1
    ;;
  -D)
    chain=$1; shift
    grep -qxF "rule $chain $*" "$state" || { echo "iptables: Bad rule (does a matching rule exist in that chain?)." >&2; exit 1; }
    awk -v target="rule $chain $*" 'BEGIN { done = 0 } { if (!done && $0 == target) { done = 1; next } print }' "$state" >"$state.new"
    mv "$state.new" "$state"
    ;;
  -S)
    ensure_chain "$1"
    sed -n "s/^rule $1 /-A $1 /p" "$state"
    ;;
  *)
    echo "fake iptables: unsupported invocation: $cmd $*" >&2
    exit 2
    ;;
esac
exit 0
EOS
  chmod +x "$TMP/bin/iptables"
  # ip6tables too. The tool uses it when it exists, and it exists on a GitHub
  # runner even though it does not exist on the macOS host this suite was
  # written on -- so without this the suite passed here and failed there, with
  # `print` (run with a scrubbed PATH) disagreeing with `apply` (run with the
  # full one) about rules nobody had stubbed.
  cp "$TMP/bin/iptables" "$TMP/bin/ip6tables"

  # firewall.sh refuses to touch netfilter as non-root; the tests are not root.
  cat >"$TMP/bin/id" <<EOF
#!/bin/sh
case "\${1:-}" in
  -u) printf '0\n' ;;
  *) exec "$REAL_ID" "\$@" ;;
esac
EOF
  chmod +x "$TMP/bin/id"
}

fw() {
  PATH="$TMP/bin:$PATH" FW_STATE="$FW_STATE" FW_LOG="$FW_LOG" sh "$REPO/tools/firewall.sh" "$@"
}

# Mutating invocations only, for comparing print against a real apply run.
mutations() { grep -E ' -(N|F|A|I|D|X)( |$)' "$FW_LOG"; }

# ===========================================================================

case_syntax() {
  if sh -n "$FW" 2>/dev/null; then pass "firewall.sh parses under sh -n"; else fail "firewall.sh parses under sh -n"; fi
}

case_usage() {
  make_env
  fw >/dev/null 2>&1
  check "no command prints usage and exits 0" "0" "$?"

  fw bogus >/dev/null 2>&1
  check "an unknown command exits 1" "1" "$?"

  out=$(fw apply 2>&1)
  check "apply without a uid exits 1" "1" "$?"
  contains "apply without a uid says why it matters" "allowing everyone is not a mitigation" "$out"

  out=$(fw print --uid "$APP_UID" --ports 99999 2>&1)
  check "an out-of-range port exits 1" "1" "$?"
  contains "an out-of-range port is named" "port out of range: 99999" "$out"
}

case_print_needs_nothing() {
  make_env
  # Deliberately not root and with no iptables anywhere on PATH: print exists so
  # the rule set can be reviewed on a machine that has neither.
  out=$(PATH="$TMP/bin:/usr/bin:/bin" sh "$FW" print --uid "$APP_UID" 2>&1)
  check "print works without root and without iptables" "0" "$?"
  contains "print shows the app's allow rule" \
    "-A DSH_ANDROID -o lo -p tcp --dport 3081 -m owner --uid-owner $APP_UID -j ACCEPT" "$out"
  contains "print shows root's allow rule (the guard's hop to the harness)" \
    "-A DSH_ANDROID -o lo -p tcp --dport 3080 -m owner --uid-owner 0 -j ACCEPT" "$out"
  contains "print shows the reject" "-A DSH_ANDROID -o lo -p tcp --dport 3080 -j REJECT" "$out"
  contains "print shows the OUTPUT hook" "-I OUTPUT 1 -o lo -p tcp --dport 3081 -j DSH_ANDROID" "$out"
  contains "print admits that nothing is enforced" "nothing was applied, and nothing is enforced" "$out"
}

case_print_is_what_apply_runs() {
  make_env
  fw apply --uid "$APP_UID" >/dev/null 2>&1
  applied=$(mutations)
  printed=$(fw print --uid "$APP_UID" 2>/dev/null)
  check "print matches what apply actually ran" "$applied" "$printed"
}

case_apply_and_verify() {
  make_env
  out=$(fw apply --uid "$APP_UID" 2>&1)
  check "apply exits 0" "0" "$?"
  contains "apply verifies its own work" "enforced and verified" "$out"

  # The rule set, in order, per port: app, then root, then everyone else.
  for port in 3080 3081; do
    first=$(grep -n "^rule DSH_ANDROID .*--dport $port .*--uid-owner $APP_UID -j ACCEPT\$" "$FW_STATE" | head -n 1 | cut -d: -f1)
    second=$(grep -n "^rule DSH_ANDROID .*--dport $port .*--uid-owner 0 -j ACCEPT\$" "$FW_STATE" | head -n 1 | cut -d: -f1)
    third=$(grep -n "^rule DSH_ANDROID .*--dport $port -j REJECT\$" "$FW_STATE" | head -n 1 | cut -d: -f1)
    if [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ "$first" -lt "$second" ] && [ "$second" -lt "$third" ]; then
      pass "port $port allows the app and root before rejecting the rest"
    else
      fail "port $port allows the app and root before rejecting the rest" "lines: app=$first root=$second reject=$third"
    fi
  done

  check "apply hooks both ports into OUTPUT" "2" "$(grep -c '^rule OUTPUT ' "$FW_STATE")"

  # Idempotence: a restart must not stack jumps, or the chain is walked N times.
  fw apply --uid "$APP_UID" >/dev/null 2>&1
  check "a second apply does not duplicate the OUTPUT hooks" "2" "$(grep -c '^rule OUTPUT ' "$FW_STATE")"
  check "a second apply does not duplicate rules" "6" "$(grep -c '^rule DSH_ANDROID ' "$FW_STATE")"

  out=$(fw status 2>&1)
  check "status reports the rule set as enforced" "0" "$?"
  contains "status names the chain" "chain DSH_ANDROID present" "$out"
  contains "status reports the uid the rules actually allow" "only uid $APP_UID and root" "$out"

  # status must not need to be told the uid, but it must notice when the rules
  # allow a different one: that rule set is not this app's mitigation.
  out=$(fw status --uid 99999 2>&1)
  check "status detects a uid mismatch between the rules and the config" "5" "$?"
  contains "status explains the mismatch" "the rules allow uid $APP_UID but DSH_APP_UID is 99999" "$out"
}

case_status_detects_tampering() {
  make_env
  fw apply --uid "$APP_UID" >/dev/null 2>&1
  # Something (or someone) removes the reject: the tool must not keep claiming
  # the device is protected.
  grep -v '^rule DSH_ANDROID .* -j REJECT$' "$FW_STATE" >"$FW_STATE.new"
  mv "$FW_STATE.new" "$FW_STATE"

  out=$(fw status 2>&1)
  check "status exits 5 when the rule set is incomplete" "5" "$?"
  contains "status names what is missing" "nothing rejects other uids on port 3080" "$out"
  contains "status says the guard can be bypassed" "another app on this device can reach the harness directly" "$out"
}

case_apply_failure_is_loud() {
  make_env
  # What a kernel without xt_owner looks like: the owner match is rejected, so
  # no rule lands. This must fail, not "succeed" with an empty chain.
  out=$(FW_FAIL_OWNER=1 fw apply --uid "$APP_UID" 2>&1)
  check "apply exits 4 when netfilter rejects the rules" "4" "$?"
  contains "apply points at the Phase 0 probe ledger" "Phase 0 probe ledger" "$out"
  lacks "apply does not claim enforcement" "enforced and verified" "$out"
}

case_remove() {
  make_env
  fw apply --uid "$APP_UID" >/dev/null 2>&1

  out=$(fw remove 2>&1)
  check "remove exits 0" "0" "$?"
  contains "remove says the mitigation is off" "§7 mitigation is OFF" "$out"
  check "remove deletes the OUTPUT hooks" "0" "$(grep -c '^rule OUTPUT ' "$FW_STATE")"
  check "remove deletes the chain" "0" "$(grep -c '^chain DSH_ANDROID' "$FW_STATE")"

  fw remove >/dev/null 2>&1
  check "remove is idempotent" "0" "$?"

  out=$(fw status 2>&1)
  check "status exits 5 with no rule set at all" "5" "$?"
  contains "status says the chain is absent" "ABSENT" "$out"
}

case_single_port() {
  make_env
  out=$(fw print --uid "$APP_UID" --ports 3081,3081 2>&1)
  check "a duplicated port is collapsed" "1" \
    "$(printf '%s\n' "$out" | grep -v ip6tables | grep -c -- '-A DSH_ANDROID .*--dport 3081 -j REJECT')"
  out=$(fw print --uid "$APP_UID" --ports 3081 2>&1)
  contains "one port applies to both ends when only one is given" "-A DSH_ANDROID -o lo -p tcp --dport 3081 -m owner --uid-owner 0 -j ACCEPT" "$out"
  check "the single-port rule set has one reject per port" "1" \
    "$(printf '%s\n' "$out" | grep -v ip6tables | grep -c -- '--dport 3081 -j REJECT')"
}

# ===========================================================================

case_syntax
case_usage
case_print_needs_nothing
case_print_is_what_apply_runs
case_apply_and_verify
case_status_detects_tampering
case_apply_failure_is_loud
case_remove
case_single_port

printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
