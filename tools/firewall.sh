#!/system/bin/sh
# firewall.sh — §7, second half: keep every other app UID off both ports.
#
# The guard (guard/guard.mjs) is *authentication* on 3081. It does not make 3080
# unreachable: the harness still listens on loopback, and any app on the device
# holding INTERNET can talk to 127.0.0.1:3080 directly, which bypasses the guard
# completely. That is why §7 names two controls and not one — the guard is what
# an attacker must get past, this script is whether they can reach it at all.
#
# Rules live in one dedicated chain per table, so `remove` and `status` act on
# chain membership instead of pattern-matching rule text, and can never disturb
# rules another tool installed. The accepted set is deliberately small:
#
#   --uid-owner <app>   the WebView app: the only unprivileged UID allowed near
#                       the guard port
#   --uid-owner 0       dshd's own children. The guard's hop to 3080 comes from
#                       root inside the rootfs, so root must be allowed or the
#                       mitigation would cut the harness off from its own guard
#   everything else on those ports   REJECT
#
# REJECT, not DROP: a silent drop looks like a hung network to the other app and
# leaves nothing in its logs, while a reject is immediate and self-explaining.
#
# `apply` verifies its own work with -C before reporting success, because "the
# rules were installed" and "the rules are in effect" are different claims and
# only the second one is worth anything. A control that is assumed rather than
# tested is not a control (§7).
#
# usage: firewall.sh <apply|remove|status|print> [--uid N] [--ports a,b]
#
#   apply    create/refresh the chain and the OUTPUT jumps, then verify them
#   remove   delete the jumps and the chain; idempotent
#   status   report whether the rule set is present and verified
#   print    print the exact commands apply would run, and change nothing
#
# env:   DSH_APP_UID, DSH_HARNESS_PORT (default 3080), DSH_GUARD_PORT (3081)
#        FIREWALL_DRY_RUN=1 — same as `print`
#
# exit:  0 ok / enforced · 1 usage or config error · 2 not root
#        3 iptables unavailable · 4 apply or verify failed · 5 not enforced
#
# POSIX sh: this runs under Magisk's mksh on the device and under /bin/sh in
# tests/firewall.test.sh. `sh -n tools/firewall.sh` syntax-checks it.

set -u

CHAIN=DSH_ANDROID

: "${DSH_APP_UID:=}"
: "${DSH_HARNESS_PORT:=3080}"
: "${DSH_GUARD_PORT:=3081}"
: "${FIREWALL_DRY_RUN:=0}"

IP4=$(command -v iptables 2>/dev/null || true)
IP6=$(command -v ip6tables 2>/dev/null || true)

log() { printf 'firewall: %s\n' "$*"; }

# Notices go to stderr, so `print`'s stdout is exactly the commands and
# `print > rules.txt` is a usable rule set.
notice() { printf 'firewall: %s\n' "$*" >&2; }

die() {
  code=$1
  shift
  printf 'firewall: ERROR: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<EOF
firewall.sh — §7: keep every other app UID off the harness and guard ports

usage: firewall.sh <apply|remove|status|print> [--uid N] [--ports a,b]

  apply    install the rule set and verify it (needs root)
  remove   take the rule set out (needs root)
  status   report whether other app UIDs are actually blocked (needs root)
  print    show the commands apply would run; changes nothing, needs no root

env: DSH_APP_UID (the app's uid) · DSH_HARNESS_PORT=$DSH_HARNESS_PORT ·
     DSH_GUARD_PORT=$DSH_GUARD_PORT · FIREWALL_DRY_RUN=1 for print

exit: 0 ok · 1 usage/config · 2 not root · 3 no iptables · 4 apply failed ·
      5 not enforced
EOF
}

# --- the rule set: defined once, used by apply, verify and print -------------
#
# Each function emits the *body* of one rule (no -A and no chain), because the
# same body is what apply passes to -A and what verify passes to -C. The bodies
# contain no spaces inside an argument, which is what makes the unquoted
# expansions below safe.

rule_body_app() {
  printf -- '-o lo -p tcp --dport %s -m owner --uid-owner %s -j ACCEPT' "$1" "$DSH_APP_UID"
}

rule_body_root() {
  printf -- '-o lo -p tcp --dport %s -m owner --uid-owner 0 -j ACCEPT' "$1"
}

rule_body_reject() {
  printf -- '-o lo -p tcp --dport %s -j REJECT' "$1"
}

RULE_KINDS="rule_body_app rule_body_root rule_body_reject"

# Validated in the main shell, never in a command substitution: `$(...)` runs in
# a subshell, so a die() inside it would kill the subshell and let the caller
# carry on with an empty port list — which is exactly how `apply` would install
# a chain with no rules in it and report success.
PORTS=""
validate_ports() {
  PORTS=""
  for p in "$DSH_HARNESS_PORT" "$DSH_GUARD_PORT"; do
    case "$p" in
      '' | *[!0-9]*) die 1 "not a port number: '$p'" ;;
    esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die 1 "port out of range: $p"
    case " $PORTS " in
      *" $p "*) ;;
      *) PORTS="$PORTS $p" ;;
    esac
  done
  PORTS=${PORTS# }
}

# --- running (or printing) netfilter commands -------------------------------

run_ipt() {
  bin=$1
  shift
  if [ "$FIREWALL_DRY_RUN" = 1 ]; then
    printf '%s %s\n' "$bin" "$*"
    return 0
  fi
  if out=$("$bin" "$@" 2>&1); then
    [ -n "$out" ] && printf 'firewall:   %s\n' "$out"
    return 0
  fi
  printf 'firewall:   %s %s -> %s\n' "$bin" "$*" "$out" >&2
  return 1
}

# Best-effort netfilter call, for the cases that are expected to fail in normal
# operation: creating a chain that already exists, or deleting one that was
# never created. Silent unless we are printing.
try_ipt() {
  bin=$1
  shift
  if [ "$FIREWALL_DRY_RUN" = 1 ]; then
    printf '%s %s\n' "$bin" "$*"
    return 0
  fi
  "$bin" "$@" >/dev/null 2>&1 || true
}

require_root() {
  [ "$FIREWALL_DRY_RUN" = 1 ] && return 0
  [ "$(id -u)" = 0 ] || die 2 "must run as root: netfilter rules need CAP_NET_ADMIN"
}

require_iptables() {
  [ -n "$IP4" ] || die 3 "iptables not found — without it there is no way to keep other app UIDs off 127.0.0.1:$DSH_GUARD_PORT. Report this in the Phase 0 ledger; the guard alone is not the §7 mitigation."
}

# Every table we can configure. IPv6 is best-effort: the harness binds 127.0.0.1
# only, so a ::1 rule is belt-and-braces rather than the control.
tables() {
  printf '%s\n' "${IP4:-iptables}"
  [ -n "$IP6" ] && printf '%s\n' "$IP6"
  return 0
}

apply_table() {
  bin=$1
  try_ipt "$bin" -N "$CHAIN"
  run_ipt "$bin" -F "$CHAIN" || die 4 "$bin -F $CHAIN failed"
  for port in $PORTS; do
    for kind in $RULE_KINDS; do
      # shellcheck disable=SC2086  # deliberate word splitting: see above
      run_ipt "$bin" -A "$CHAIN" $($kind "$port") \
        || die 4 "$bin rejected the rule set (missing xt_owner? see the Phase 0 probe ledger)"
    done
  done
  for port in $PORTS; do
    if [ "$FIREWALL_DRY_RUN" = 1 ] || ! "$bin" -C OUTPUT -o lo -p tcp --dport "$port" -j "$CHAIN" >/dev/null 2>&1; then
      run_ipt "$bin" -I OUTPUT 1 -o lo -p tcp --dport "$port" -j "$CHAIN" \
        || die 4 "$bin could not hook the $CHAIN chain into OUTPUT for port $port"
    fi
  done
}

verify_table() {
  bin=$1
  missing=0
  for port in $PORTS; do
    for kind in $RULE_KINDS; do
      # shellcheck disable=SC2086
      if ! "$bin" -C "$CHAIN" $($kind "$port") >/dev/null 2>&1; then
        log "NOT PRESENT in $bin: -A $CHAIN $($kind "$port")"
        missing=1
      fi
    done
  done
  for port in $PORTS; do
    if ! "$bin" -C OUTPUT -o lo -p tcp --dport "$port" -j "$CHAIN" >/dev/null 2>&1; then
      log "NOT PRESENT in $bin: -I OUTPUT -o lo -p tcp --dport $port -j $CHAIN"
      missing=1
    fi
  done
  return $missing
}

remove_table() {
  bin=$1
  for port in $PORTS; do
    # Delete every copy of the jump: a previous apply may have been interrupted.
    guard=0
    while "$bin" -C OUTPUT -o lo -p tcp --dport "$port" -j "$CHAIN" >/dev/null 2>&1; do
      run_ipt "$bin" -D OUTPUT -o lo -p tcp --dport "$port" -j "$CHAIN" || break
      guard=$((guard + 1))
      [ "$guard" -lt 10 ] || break
    done
  done
  try_ipt "$bin" -F "$CHAIN"
  try_ipt "$bin" -X "$CHAIN"
}

cmd_apply() {
  # print needs no iptables: reviewing the rule set on a machine that has none
  # is the point of print.
  [ "$FIREWALL_DRY_RUN" = 1 ] || require_iptables
  case "$DSH_APP_UID" in
    '' | *[!0-9]*)
      die 1 "apply needs the app's uid: --uid N or DSH_APP_UID (got '${DSH_APP_UID}'). Without it the rule set cannot allow the app, and allowing everyone is not a mitigation." ;;
  esac
  for bin in $(tables); do
    apply_table "$bin"
  done
  if [ "$FIREWALL_DRY_RUN" = 1 ]; then
    notice "dry run — nothing was applied, and nothing is enforced"
    return 0
  fi
  verify
}

# Verify after applying, and report what is actually in effect.
verify() {
  enforced=1
  for bin in $(tables); do
    verify_table "$bin" || enforced=0
  done
  [ "$enforced" = 1 ] || die 4 "the rule set did not verify; other app UIDs may still reach 127.0.0.1:$DSH_GUARD_PORT"
  log "enforced and verified: uid $DSH_APP_UID and root may reach port(s) $PORTS, every other uid is rejected"
}

cmd_remove() {
  require_iptables
  for bin in $(tables); do
    remove_table "$bin"
  done
  if [ "$FIREWALL_DRY_RUN" = 1 ]; then
    notice "dry run — nothing was removed"
    return 0
  fi
  log "removed: other app UIDs are no longer blocked (§7 mitigation is OFF)"
}

# Structural check for `status`, which has to work without being told the uid —
# a health check should not need configuring before it can say whether a control
# is in place. It inspects the rule set, reports the uid baked into it, and
# treats "the rules allow some other uid" as *not enforced*: for this app, it
# is not. Sets $ALLOWED_UID.
status_table() {
  bin=$1
  if ! rules=$("$bin" -S "$CHAIN" 2>/dev/null); then
    printf '%s: chain %s ABSENT\n' "$bin" "$CHAIN"
    return 1
  fi
  printf '%s: chain %s present\n' "$bin" "$CHAIN"
  printf '%s\n' "$rules" | sed 's/^/  /'

  ok=1
  uids=""
  for port in $PORTS; do
    printf '%s\n' "$rules" | grep -qE -- "-p tcp --dport $port -j REJECT\$" \
      || { log "$bin: nothing rejects other uids on port $port"; ok=0; }
    printf '%s\n' "$rules" | grep -qE -- "--dport $port -m owner --uid-owner 0 -j ACCEPT\$" \
      || { log "$bin: root may not reach port $port, so the guard cannot reach the harness"; ok=0; }
    uid=$(printf '%s\n' "$rules" | sed -n "s/.*--dport $port -m owner --uid-owner \([0-9][0-9]*\) -j ACCEPT\$/\1/p" | grep -v '^0$' | head -n 1)
    if [ -n "$uid" ]; then uids="$uids $uid"; else
      log "$bin: no app uid is allowed to reach port $port"
      ok=0
    fi
  done
  for port in $PORTS; do
    "$bin" -C OUTPUT -o lo -p tcp --dport "$port" -j "$CHAIN" >/dev/null 2>&1 \
      || { log "$bin: $CHAIN is not hooked into OUTPUT for port $port, so the rules are never reached"; ok=0; }
  done

  # shellcheck disable=SC2086  # deliberate word splitting
  ALLOWED_UID=$(printf '%s\n' $uids | sort -u | head -n 1)
  if [ "$(printf '%s\n' $uids | sort -u | wc -l | tr -d ' ')" != 1 ]; then
    log "$bin: the ports do not agree on which uid is allowed ($uids)"
    ok=0
  fi
  [ "$ok" = 1 ] || return 1

  # The rule set may be complete and still not be *this* app's mitigation.
  if [ -n "$DSH_APP_UID" ] && [ "$ALLOWED_UID" != "$DSH_APP_UID" ]; then
    log "$bin: the rules allow uid $ALLOWED_UID but DSH_APP_UID is $DSH_APP_UID — the app would be rejected"
    return 1
  fi
  return 0
}

cmd_status() {
  require_iptables
  enforced=1
  ALLOWED_UID=""
  for bin in $(tables); do
    status_table "$bin" || enforced=0
  done
  if [ "$enforced" = 1 ]; then
    log "enforced: only uid ${ALLOWED_UID:-?} and root can reach the loopback ports; every other uid is rejected"
    return 0
  fi
  log "NOT enforced: another app on this device can reach the harness directly and bypass the guard"
  return 5
}

# --- entry point ------------------------------------------------------------

main() {
  cmd=${1:-}
  [ $# -gt 0 ] && shift

  uid_arg=""
  ports_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --uid) shift; uid_arg=${1:-} ;;
      --ports) shift; ports_arg=${1:-} ;;
      -h | --help) usage; exit 0 ;;
      *) die 1 "unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$uid_arg" ] && DSH_APP_UID=$uid_arg
  if [ -n "$ports_arg" ]; then
    DSH_HARNESS_PORT=${ports_arg%%,*}
    case "$ports_arg" in
      *,*) DSH_GUARD_PORT=${ports_arg##*,} ;;
      *) DSH_GUARD_PORT=$DSH_HARNESS_PORT ;;
    esac
  fi

  validate_ports

  case "$cmd" in
    apply) require_root; cmd_apply ;;
    remove) require_root; cmd_remove ;;
    status) require_root; cmd_status ;;
    print)
      # Same code path as apply, with the mutations printed instead of run: the
      # rule set you review is the rule set that gets applied.
      FIREWALL_DRY_RUN=1
      cmd_apply
      ;;
    help | --help | -h | '') usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
