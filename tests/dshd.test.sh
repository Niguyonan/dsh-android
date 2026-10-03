#!/bin/sh
# Host-side lifecycle tests for bin/dshd. POSIX sh, no root, no device.
#
# What these prove here: the exit-code contract the APK's health check reads,
# the dry-run mutation path, posture resolution, token handling, stale-PID
# sweeping, log rotation, the supervisor loop, and — the one that matters most —
# the pair semantics: kill either child and the other is torn down and the pair
# comes back, with the pid file naming the process that actually holds the port.
#
# What they cannot prove: anything kernel-level. Mounts, devpts, chroot,
# Landlock and SELinux are Phase 0 probes on the device, not host tests.
#
# The root-only paths (start/stop) are exercised through an `id` double and
# DSHD_NO_CHROOT=1, which switches off every privileged operation (mount,
# chroot) — so nothing here needs or grants privilege. `bin/dshd`'s only root
# check is `id -u`; see the "not root" case below for the real refusal.
#
# Run directly, or through tests/run.sh.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
DSHD="$REPO/bin/dshd"
NODE_BIN=$(command -v node 2>/dev/null || true)
REAL_ID=$(command -v id 2>/dev/null || true)

[ -f "$DSHD" ] || { echo "dshd not found at $DSHD" >&2; exit 1; }

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
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf 'skip %s (%s)\n' "$1" "${2:-}"
}

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

# contains <name> <needle> <haystack>
contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain [$2] in: $3" ;;
  esac
}

# lacks <name> <needle> <haystack>
lacks() {
  case "$3" in
    *"$2"*) fail "$1" "expected NOT to contain [$2] in: $3" ;;
    *) pass "$1" ;;
  esac
}

# wait_until <ticks> <command...> — poll at 0.25s, so ticks/4 seconds.
wait_until() {
  ticks=$1
  shift
  i=0
  while [ "$i" -lt "$ticks" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# Tolerant on purpose: a pid file can vanish mid-restart, and "no pid" is a
# legitimate answer here rather than an error.
pid_of() { [ -f "$1" ] && tr -dc '0-9' <"$1" 2>/dev/null; return 0; }

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# status output with runs of spaces squeezed, so assertions do not depend on the
# column padding of printf '%-11s'.
squeeze() { printf '%s\n' "$1" | tr -s ' '; }

# The pid actually listening on a loopback port, per lsof. Empty when lsof is
# unavailable. This is how the pid file is held to account: on some shells a
# backgrounded function makes $! a wrapper subshell, which would name a process
# that does not hold the port.
port_owner() {
  [ -n "${1:-}" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n 1
}

port_open() {
  [ -n "${1:-}" ] || return 1
  command -v nc >/dev/null 2>&1 || return 1
  nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

free_port() {
  "$NODE_BIN" -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>console.log(p))})' 2>/dev/null
}

# --- environment ------------------------------------------------------------

TMP=""
SUPERVISOR_PID=""

# A fresh install tree: every path dshd owns, none of it outside $TMP.
env_new() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/dshd-test.XXXXXX") || exit 1
  DSH_BASE="$TMP/dsh"
  DSH_ROOTFS="$DSH_BASE/rootfs"
  DSH_STATE="$DSH_BASE/state"
  DSH_WORKSPACE="$DSH_BASE/workspace"
  DSH_ETC="$DSH_BASE/etc"
  DSH_LOG="$DSH_BASE/log"
  DSH_RUN="$DSH_BASE/run"
  mkdir -p "$DSH_ROOTFS" "$DSH_STATE" "$DSH_WORKSPACE" "$DSH_ETC" "$DSH_LOG" "$DSH_RUN"

  DSH_HARNESS_PORT=$(free_port)
  DSH_GUARD_PORT=$(free_port)
  DSHD_NO_CHROOT=1
  DSHD_DRY_RUN=1

  # Fast enough to test, slow enough to observe.
  DSH_POLL_INTERVAL=0.2
  DSH_START_TIMEOUT=30
  DSH_STOP_TIMEOUT=5
  DSH_LAUNCH_TIMEOUT=10
  DSH_BACKOFF_MIN=0
  DSH_BACKOFF_MAX=0
  DSH_LOG_MAX_BYTES=1000
  DSH_LOG_KEEP=2

  export DSH_BASE DSH_ROOTFS DSH_STATE DSH_WORKSPACE DSH_ETC DSH_LOG DSH_RUN \
    DSH_HARNESS_PORT DSH_GUARD_PORT DSHD_NO_CHROOT DSHD_DRY_RUN \
    DSH_POLL_INTERVAL DSH_START_TIMEOUT DSH_STOP_TIMEOUT DSH_BACKOFF_MIN \
    DSH_BACKOFF_MAX DSH_LOG_MAX_BYTES DSH_LOG_KEEP DSH_LAUNCH_TIMEOUT

  # A fake /data/adb, so root detection is hermetic: a host that happens to have
  # Magisk or KernelSU installed must not change what these tests measure.
  DSH_ADB="$TMP/adb"
  export DSH_ADB
  mkdir -p "$DSH_ADB"

  # Per-case hygiene: one case's exports must not decide the next case's
  # behaviour (the firewall cases set DSH_FIREWALL=on on purpose).
  unset DSH_PERMISSION_MODE 2>/dev/null || true
  DSH_FIREWALL=off
  DSH_APP_UID=""
  export DSH_FIREWALL DSH_APP_UID

  # The supervisor re-executes itself; give it an executable shim up front.
  make_self_shim
}

env_free() {
  [ -n "$TMP" ] || return 0
  if [ -n "$SUPERVISOR_PID" ] && alive "$SUPERVISOR_PID"; then
    kill -KILL "$SUPERVISOR_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
  TMP=""
  SUPERVISOR_PID=""
}

cleanup() { env_free; }
trap cleanup EXIT INT TERM

# dshd <args...> — always via `sh`, because the file's shebang is Android's.
dshd() { sh "$DSHD" "$@"; }

# ===========================================================================
# 1. Argument and exit-code contract
# ===========================================================================

case_syntax() {
  if sh -n "$DSHD" 2>/dev/null; then pass "bin/dshd parses under sh -n"; else fail "bin/dshd parses under sh -n"; fi
}

case_contract() {
  out=$(dshd version 2>&1)
  check "dshd version prints the schema version" "1" "$out"

  dshd help >/dev/null 2>&1
  check "dshd help exits 0" "0" "$?"

  out=$(dshd help 2>&1)
  contains "usage lists the device commands" "start" "$out"

  dshd definitely-not-a-command >/dev/null 2>&1
  check "an unknown command exits 1" "1" "$?"
}

case_not_root() {
  if [ "$(id -u)" = 0 ]; then
    skip "not-root refusal exits 2" "running as root"
    return 0
  fi
  env_new
  DSHD_DRY_RUN=0
  export DSHD_DRY_RUN
  out=$(dshd stop 2>&1)
  rc=$?
  check "not-root refusal exits 2 (the APK's health check reads this)" "2" "$rc"
  contains "not-root refusal explains itself" "must run as root" "$out"
}

# ===========================================================================
# 2. Status, token, posture
# ===========================================================================

case_status_fresh() {
  env_new
  out=$(dshd status 2>&1)
  rc=$?
  out=$(squeeze "$out")
  check "status on a fresh install exits 3 (not running)" "3" "$rc"
  contains "status reports the supervisor as stopped" "supervisor: stopped" "$out"
  contains "status reports the token as absent" "token: absent" "$out"
  contains "status reports confinement as unresolved" "confinement: unresolved (run tools/confinement-check.sh)" "$out"
  contains "status defaults to workspace-write" "permission: workspace-write" "$out"
  contains "status shows the in-chroot path model" "(in-chroot /state)" "$out"
  # The solution is "none" on any host; the parenthetical is the SELinux context,
  # which is `unknown` where there is no /proc, `unconfined` on a Linux box with
  # SELinux off, and a real domain on a device. Asserting the context pinned this
  # to the machine it was written on.
  contains "status names the root solution" "root: none (" "$out"
}

case_token_absent() {
  env_new
  out=$(dshd token 2>&1)
  rc=$?
  check "dshd token without a token exits 1" "1" "$rc"
  contains "dshd token says what to do" "no token yet" "$out"
}

case_posture() {
  env_new

  printf 'permission_mode=danger-full-access\nconfinement=none (Landlock unavailable; disclosed)\n' \
    >"$DSH_STATE/posture.conf"
  out=$(squeeze "$(dshd status 2>&1)")
  contains "posture.conf pins the permission mode" "permission: danger-full-access" "$out"
  contains "posture.conf reports the confinement verdict" "confinement: none (Landlock unavailable; disclosed)" "$out"

  # The environment is the operator override and must beat the file.
  DSH_PERMISSION_MODE=workspace-write
  export DSH_PERMISSION_MODE
  out=$(squeeze "$(dshd status 2>&1)")
  contains "the environment overrides posture.conf" "permission: workspace-write" "$out"
  unset DSH_PERMISSION_MODE
}

# ===========================================================================
# 3. start, in dry-run: what it must do, and what it must refuse to do
# ===========================================================================

case_start_dry_run() {
  env_new
  out=$(dshd start 2>&1)
  rc=$?
  check "dry-run start exits 0" "0" "$rc"
  contains "dry-run start says it did not spawn" "dry-run: supervisor not spawned" "$out"
  contains "dry-run start announces the token it would mint" "dry-run: would generate" "$out"

  if [ -d "$DSH_LOG" ]; then pass "dry-run start creates the skeleton directories"; else fail "dry-run start creates the skeleton directories"; fi
  if [ -f "$DSH_RUN/supervisor.pid" ]; then
    fail "dry-run start writes no supervisor pid file"
  else
    pass "dry-run start writes no supervisor pid file"
  fi
  # Fail-closed: a dry run must not mint a credential as a side effect.
  if [ -f "$DSH_STATE/guard.token" ]; then
    fail "dry-run start does not create the guard token"
  else
    pass "dry-run start does not create the guard token"
  fi
}

case_start_idempotent() {
  env_new
  printf '%s\n' "$$" >"$DSH_RUN/supervisor.pid"
  out=$(dshd start 2>&1)
  rc=$?
  check "start with a live supervisor exits 0" "0" "$rc"
  contains "start with a live supervisor does not spawn a second one" "already running" "$out"
}

case_stale_pid() {
  env_new
  DSHD_DRY_RUN=0
  export DSHD_DRY_RUN

  # A pid that cannot be alive: this shell's last background job, long reaped.
  (exit 0) &
  dead=$!
  wait "$dead" 2>/dev/null
  printf '%s\n' "$dead" >"$DSH_RUN/supervisor.pid"

  out=$(dshd status 2>&1)
  rc=$?
  check "status with a dead supervisor pid still exits 3" "3" "$rc"
  contains "status reports the supervisor as stopped" "supervisor:  stopped" "$out"
  if [ -f "$DSH_RUN/supervisor.pid" ]; then
    fail "status sweeps the stale pid file"
  else
    pass "status sweeps the stale pid file"
  fi
}

# ===========================================================================
# 4. Log rotation
# ===========================================================================

case_rotation() {
  env_new
  DSHD_DRY_RUN=0
  export DSHD_DRY_RUN

  # Under the limit: untouched. A running child holds the old fd, so a rotation
  # that is not needed is pure risk.
  printf 'small\n' >"$DSH_LOG/guard.log"
  dshd rotate >/dev/null 2>&1
  if [ -f "$DSH_LOG/guard.log.1" ]; then
    fail "an undersized log is left alone"
  else
    pass "an undersized log is left alone"
  fi

  # Over the limit (DSH_LOG_MAX_BYTES=1000 in the test env): rotated and
  # truncated in place, with older generations shifted.
  i=0
  while [ "$i" -lt 200 ]; do printf 'xxxxxxxxxx\n'; i=$((i + 1)); done >"$DSH_LOG/harness.log"
  printf 'generation one\n' >"$DSH_LOG/harness.log.1"
  dshd rotate >/dev/null 2>&1

  if [ -f "$DSH_LOG/harness.log.1" ]; then pass "an oversized log is rotated to .1"; else fail "an oversized log is rotated to .1"; fi
  check "the new generation is empty" "0" "$(wc -c <"$DSH_LOG/harness.log" | tr -d ' ')"
  contains "the previous generation shifted to .2" "generation one" "$(cat "$DSH_LOG/harness.log.2" 2>/dev/null)"
}

# ===========================================================================
# 5. The supervisor loop, in dry-run: crash detection, backoff, clean stop
# ===========================================================================

case_supervise_loop() {
  env_new
  log="$TMP/supervise.log"
  dshd supervise >"$log" 2>&1 &
  SUPERVISOR_PID=$!

  if wait_until 40 grep -q "supervisor started" "$log"; then
    pass "supervise starts and announces itself"
  else
    fail "supervise starts and announces itself" "$(cat "$log")"
  fi

  # No children exist in dry-run, so the loop must notice immediately rather
  # than sit on two pid files that never appear.
  if wait_until 40 grep -q "restarting pair" "$log"; then
    pass "supervise detects missing children and restarts the pair"
  else
    fail "supervise detects missing children and restarts the pair" "$(cat "$log")"
  fi

  : >"$DSH_RUN/stop"
  if wait_until 40 sh -c "! kill -0 $SUPERVISOR_PID 2>/dev/null"; then
    pass "supervise exits when the stop file appears"
  else
    fail "supervise exits when the stop file appears" "$(cat "$log")"
  fi
  wait "$SUPERVISOR_PID" 2>/dev/null
  check "supervise exits 0 after a clean stop" "0" "$?"
  contains "supervise logs its exit" "supervisor exiting" "$(cat "$log")"
  SUPERVISOR_PID=""
}

# ===========================================================================
# 6. The real thing: supervisor + stand-in harness + the actual guard
# ===========================================================================
#
# This is where the pair semantics are proven rather than asserted. Children are
# really spawned, really killed, and really restarted; the ports are really
# bound and really released.

# Stand-in harness: a loopback listener. `dshd` only needs `web --no-open
# --port N` to bind the port, so this exercises readiness, liveness and restart
# without installing the harness itself.
make_rootfs_shims() {
  mkdir -p "$DSH_ROOTFS/usr/local/bin" "$DSH_ROOTFS/opt/dsh-android"

  cat >"$DSH_ROOTFS/opt/harness-standin.js" <<'EOS'
const net = require('node:net')
const port = Number(process.argv[2] || 3080)
// The launch-token line, because it is the contract dshd depends on: the real
// harness prints exactly this to stdout, and dshd refuses to start a guard
// without it. A stand-in that stayed silent would test a system that cannot
// exist on a device.
const LAUNCH_TOKEN = 'standin_launch_token_0123456789abcdefghijkl'
// Behave like a server, not like a script: a killed peer is not a crash.
const server = net.createServer((socket) => {
  socket.on('error', () => {})
  socket.end('stand-in harness\n')
})
server.on('error', (err) => {
  console.error(`stand-in harness: ${err.message}`)
  process.exit(1)
})
server.listen(port, '127.0.0.1', () => {
  console.log(`dsh web: http://127.0.0.1:${port}/?token=${LAUNCH_TOKEN}`)
})
EOS

  cat >"$DSH_ROOTFS/usr/local/bin/dsh" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then printf 'stand-in-harness 0.0.0\n'; exit 0; fi
port=3080
while [ \$# -gt 0 ]; do
  case "\$1" in --port) shift; port=\$1 ;; esac
  shift
done
exec "$NODE_BIN" "$DSH_ROOTFS/opt/harness-standin.js" "\$port"
EOF

  # A node shim, so the guard child is found through the rootfs the way the
  # device finds it, on a host whose node lives somewhere else entirely.
  cat >"$DSH_ROOTFS/usr/local/bin/node" <<EOF
#!/bin/sh
exec "$NODE_BIN" "\$@"
EOF

  cp "$REPO/guard/guard.mjs" "$DSH_ROOTFS/opt/dsh-android/guard.mjs"
  chmod +x "$DSH_ROOTFS/usr/local/bin/dsh" "$DSH_ROOTFS/usr/local/bin/node"

  # Dev-mode path model: without a chroot, in_rootfs_path() prefixes DSH_ROOTFS,
  # so an in-rootfs path must be reachable *under* the rootfs. On the device the
  # bind mount is what makes that true — dshd mounts $DSH_STATE at
  # $DSH_ROOTFS/state — so the shim is that mount point, not a copy of the host
  # spelling. Getting this wrong is how the guard's token path stayed broken on
  # devices while this suite passed: prefixing a *host* path happens to resolve
  # here and cannot resolve inside a real chroot.
  mkdir -p "$DSH_ROOTFS"
  ln -sfn "$DSH_STATE" "$DSH_ROOTFS/state"
}

# Root-only commands, without root: `id -u` is the only check that gates them,
# and DSHD_NO_CHROOT=1 keeps every privileged operation switched off.
make_id_double() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/id" <<EOF
#!/bin/sh
case "\${1:-}" in
  -u) printf '0\n' ;;
  *) exec "$REAL_ID" "\$@" ;;
esac
EOF
  chmod +x "$TMP/bin/id"
  PATH="$TMP/bin:$PATH"
  export PATH
}

# The supervisor re-executes itself; on a host it cannot exec bin/dshd directly,
# because its shebang is Android's /system/bin/sh.
make_self_shim() {
  cat >"$TMP/dshd-self" <<EOF
#!/bin/sh
exec /bin/sh "$DSHD" "\$@"
EOF
  chmod +x "$TMP/dshd-self"
  DSHD_SELF="$TMP/dshd-self"
  export DSHD_SELF
}

case_real_pair() {
  if [ -z "$NODE_BIN" ]; then
    skip "supervisor pair semantics" "node is not installed"
    return 0
  fi
  if ! command -v nc >/dev/null 2>&1; then
    skip "supervisor pair semantics" "nc is needed for host port checks"
    return 0
  fi

  env_new
  DSHD_DRY_RUN=0
  export DSHD_DRY_RUN
  make_rootfs_shims
  make_id_double
  make_self_shim

  out=$(dshd start 2>&1)
  rc=$?
  check "start with real children exits 0" "0" "$rc"
  contains "start waits for readiness on both ports" "ready after" "$out"

  harness_pid=$(pid_of "$DSH_RUN/harness.pid")
  guard_pid=$(pid_of "$DSH_RUN/guard.pid")
  SUPERVISOR_PID=$(pid_of "$DSH_RUN/supervisor.pid")
  if alive "$harness_pid" && alive "$guard_pid" && alive "$SUPERVISOR_PID"; then
    pass "start leaves a live supervisor, harness and guard"
  else
    fail "start leaves a live supervisor, harness and guard" \
      "supervisor=$SUPERVISOR_PID harness=$harness_pid guard=$guard_pid"
  fi

  if port_open "$DSH_HARNESS_PORT" && port_open "$DSH_GUARD_PORT"; then
    pass "both loopback ports are bound"
  else
    fail "both loopback ports are bound" "harness=$DSH_HARNESS_PORT guard=$DSH_GUARD_PORT"
  fi

  # The token must exist, and must not be readable by anyone else.
  if [ -s "$DSH_STATE/guard.token" ]; then pass "start generates the guard token"; else fail "start generates the guard token"; fi
  perms=$(ls -l "$DSH_STATE/guard.token" 2>/dev/null | cut -c1-10)
  check "the guard token is 0600" "-rw-------" "$perms"

  out=$(dshd status 2>&1)
  rc=$?
  out=$(squeeze "$out")
  check "status on a running system exits 0" "0" "$rc"
  contains "status sees the harness listening" "harness: running" "$out"
  contains "status sees the guard listening" "guard: running" "$out"
  lacks "status reports no missing port" "not listening" "$out"

  # The pid file must name the process that actually holds the port, not a
  # wrapper subshell that SIGTERM can leave behind while the listener lives on.
  # Measured on /bin/sh: backgrounding a function makes $! exactly that wrapper.
  if command -v lsof >/dev/null 2>&1; then
    check "the harness pid is the process holding the harness port" \
      "$harness_pid" "$(port_owner "$DSH_HARNESS_PORT")"
    check "the guard pid is the process holding the guard port" \
      "$guard_pid" "$(port_owner "$DSH_GUARD_PORT")"
  else
    skip "the pid files name the listening processes" "no lsof"
  fi

  # Idempotence: a second start must not orphan a second pair.
  out=$(dshd start 2>&1)
  contains "a second start is a no-op" "already running" "$out"
  check "a second start does not replace the harness" "$harness_pid" "$(pid_of "$DSH_RUN/harness.pid")"

  # --- crash the harness (exactly what an OOM kill does) --------------------
  kill -9 "$harness_pid" 2>/dev/null
  if wait_until 60 sh -c "[ \"\$(tr -dc '0-9' <'$DSH_RUN/harness.pid')\" != '$harness_pid' ]"; then
    pass "the supervisor notices a killed harness and restarts the pair"
  else
    fail "the supervisor notices a killed harness and restarts the pair" \
      "harness.pid still $(cat "$DSH_RUN/harness.pid" 2>/dev/null)"
  fi
  new_harness=$(pid_of "$DSH_RUN/harness.pid")
  new_guard=$(pid_of "$DSH_RUN/guard.pid")
  # The old guard must not survive its partner: that is the pair invariant, and
  # it is also what keeps the guard port from being held twice.
  if [ "$new_guard" != "$guard_pid" ] && wait_until 20 port_open "$DSH_GUARD_PORT"; then
    pass "the restarted pair replaces the guard too"
  else
    fail "the restarted pair replaces the guard too" "guard was $guard_pid, now $new_guard"
  fi

  # --- crash the guard ------------------------------------------------------
  guard_pid=$(pid_of "$DSH_RUN/guard.pid")
  harness_pid=$(pid_of "$DSH_RUN/harness.pid")
  kill -9 "$guard_pid" 2>/dev/null
  if wait_until 60 sh -c "[ \"\$(tr -dc '0-9' <'$DSH_RUN/guard.pid')\" != '$guard_pid' ] && [ \"\$(tr -dc '0-9' <'$DSH_RUN/harness.pid')\" != '$harness_pid' ]"; then
    pass "a killed guard takes the harness down with it"
  else
    fail "a killed guard takes the harness down with it" \
      "guard $guard_pid->$(pid_of "$DSH_RUN/guard.pid"), harness $harness_pid->$(pid_of "$DSH_RUN/harness.pid")"
  fi

  # --- stop -----------------------------------------------------------------
  out=$(dshd stop 2>&1)
  rc=$?
  check "stop exits 0" "0" "$rc"
  contains "stop signals the supervisor" "signalling supervisor" "$out"
  if wait_until 40 sh -c "! nc -z 127.0.0.1 $DSH_HARNESS_PORT >/dev/null 2>&1 && ! nc -z 127.0.0.1 $DSH_GUARD_PORT >/dev/null 2>&1"; then
    pass "stop releases both ports"
  else
    fail "stop releases both ports"
  fi
  if [ -f "$DSH_RUN/harness.pid" ] || [ -f "$DSH_RUN/guard.pid" ] || [ -f "$DSH_RUN/supervisor.pid" ]; then
    fail "stop removes the pid files" "$(ls "$DSH_RUN")"
  else
    pass "stop removes the pid files"
  fi
  if [ -s "$DSH_STATE/guard.token" ]; then
    pass "stop keeps the token (sessions and credentials outlive a stop)"
  else
    fail "stop keeps the token (sessions and credentials outlive a stop)"
  fi
  SUPERVISOR_PID=""
}

# A SIGKILLed supervisor cannot clean up after itself. `status` must not report
# a dead supervisor as running, and `stop` must reap the orphans it left.
case_orphaned_children() {
  if [ -z "$NODE_BIN" ] || ! command -v nc >/dev/null 2>&1; then
    skip "orphan cleanup after a SIGKILLed supervisor" "needs node and nc"
    return 0
  fi

  env_new
  DSHD_DRY_RUN=0
  export DSHD_DRY_RUN
  make_rootfs_shims
  make_id_double
  make_self_shim

  dshd start >/dev/null 2>&1
  harness_pid=$(pid_of "$DSH_RUN/harness.pid")
  guard_pid=$(pid_of "$DSH_RUN/guard.pid")
  supervisor_pid=$(pid_of "$DSH_RUN/supervisor.pid")

  kill -9 "$supervisor_pid" 2>/dev/null
  if wait_until 40 sh -c "! kill -0 $supervisor_pid 2>/dev/null"; then
    pass "the supervisor is gone (SIGKILL, nothing reaped)"
  else
    fail "the supervisor is gone (SIGKILL, nothing reaped)"
  fi

  out=$(dshd status 2>&1)
  rc=$?
  out=$(squeeze "$out")
  check "status exits 3 after the supervisor dies" "3" "$rc"
  contains "status does not report a dead supervisor as running" "supervisor: stopped" "$out"
  if [ -f "$DSH_RUN/supervisor.pid" ]; then
    fail "status sweeps the stale supervisor pid"
  else
    pass "status sweeps the stale supervisor pid"
  fi

  out=$(dshd stop 2>&1)
  check "stop reaps the orphaned children" "0" "$?"
  if wait_until 40 sh -c "! kill -0 $harness_pid 2>/dev/null && ! kill -0 $guard_pid 2>/dev/null"; then
    pass "the orphans are gone"
  else
    fail "the orphans are gone" "harness=$harness_pid guard=$guard_pid"
  fi
  SUPERVISOR_PID=""
}

# ===========================================================================
# 7. Root solutions: Magisk, KernelSU, KernelSU-Next
# ===========================================================================
#
# KernelSU and KernelSU-Next share /data/adb/ksu and /data/adb/ksud (their
# ksud/src/defs.rs agree on WORKING_DIR and DAEMON_PATH), so they are one code
# path with two version strings. Magisk keeps /data/adb/magisk, and the two can
# be installed at once — the FAQ says KernelSU's su coexists with Magisk — so
# "both" is a state to report rather than an error.

case_root_solutions() {
  env_new
  mkdir -p "$DSH_ADB/ksu/bin"

  cat >"$DSH_ADB/ksud" <<'EOF'
#!/bin/sh
printf 'v1.0.6 (uapi: 2)\n'
EOF
  chmod +x "$DSH_ADB/ksud"
  out=$(dshd root 2>&1)
  contains "detects KernelSU from /data/adb/ksud" "solution:    kernelsu" "$out"
  contains "reports the KernelSU version" "kernelsu:    v1.0.6 (uapi: 2)" "$out"

  # Same paths, different version string: this is the only thing that separates
  # KernelSU-Next from KernelSU at the filesystem level.
  cat >"$DSH_ADB/ksud" <<'EOF'
#!/bin/sh
printf 'v3.0.0-ksunext (uapi: 2)\n'
EOF
  chmod +x "$DSH_ADB/ksud"
  out=$(dshd root 2>&1)
  contains "distinguishes KernelSU-Next" "solution:    kernelsu-next" "$out"

  # Magisk alone.
  rm -f "$DSH_ADB/ksud"
  rmdir "$DSH_ADB/ksu/bin" "$DSH_ADB/ksu"
  mkdir -p "$DSH_ADB/magisk"
  cat >"$DSH_ADB/magisk/magisk" <<'EOF'
#!/bin/sh
printf '27.0:MAGISK\n'
EOF
  chmod +x "$DSH_ADB/magisk/magisk"
  out=$(dshd root 2>&1)
  contains "detects Magisk from /data/adb/magisk" "solution:    magisk" "$out"
  contains "reports the Magisk version" "magisk:      27.0:MAGISK" "$out"

  # Both at once is a real configuration, not a broken one.
  mkdir -p "$DSH_ADB/ksu/bin"
  cat >"$DSH_ADB/ksud" <<'EOF'
#!/bin/sh
printf 'v1.0.6 (uapi: 2)\n'
EOF
  chmod +x "$DSH_ADB/ksud"
  out=$(dshd root 2>&1)
  contains "reports both when both are installed" "solution:    both" "$out"
  out=$(squeeze "$(dshd status 2>&1)")
  contains "status names both when both are installed" \
    "root: both magisk 27.0:MAGISK, kernelsu v1.0.6" "$out"
}

# KernelSU shells are not guaranteed to have `su` in PATH (tiann/KernelSU#2647),
# so the fallback to the KernelSU binary is the path that matters. Test it with
# a PATH that has no su at all, rather than trusting the host's.
case_su_resolution() {
  env_new
  mkdir -p "$DSH_ADB/ksu/bin" "$TMP/path"
  cat >"$DSH_ADB/ksud" <<'EOF'
#!/bin/sh
printf 'v1.0.6 (uapi: 2)\n'
EOF
  chmod +x "$DSH_ADB/ksud"
  cat >"$DSH_ADB/ksu/bin/su" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$DSH_ADB/ksu/bin/su"

  for c in tr head grep sed; do
    [ -n "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$TMP/path/$c"
  done

  out=$(PATH="$TMP/path" /bin/sh "$DSHD" root 2>&1)
  contains "finds the KernelSU su when PATH has none" "su:          $DSH_ADB/ksu/bin/su" "$out"

  # And with no su anywhere, it says so instead of printing a path that is not
  # there — the APK's token fetch depends on this being honest.
  rm -f "$DSH_ADB/ksu/bin/su"
  out=$(PATH="$TMP/path" /bin/sh "$DSHD" root 2>&1)
  contains "says so when there is no su at all" "NOT FOUND" "$out"
}

# ===========================================================================
# 8. Boot autostart (/data/adb/service.d on all three root solutions)
# ===========================================================================

case_boot_autostart() {
  env_new
  BOOT="$REPO/boot/service.d/dshd.sh"
  mkdir -p "$DSH_BASE/bin"
  cat >"$DSH_BASE/bin/dshd" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/dshd.calls"
exit 0
EOF
  chmod +x "$DSH_BASE/bin/dshd"
  make_id_double

  # Opt-in: without autostart=on in the config, nothing happens.
  out=$(KSU=true DSH_BASE="$DSH_BASE" DSH_AUTOSTART_WAIT=0 /bin/sh "$BOOT" 2>&1)
  check "autostart is off by default" "0" "$?"
  if [ -f "$TMP/dshd.calls" ]; then fail "autostart does not start dshd unless asked"; else pass "autostart does not start dshd unless asked"; fi

  printf 'autostart=on\n' >"$DSH_BASE/etc/dshd.conf"
  out=$(KSU=true DSH_BASE="$DSH_BASE" DSH_AUTOSTART_WAIT=0 /bin/sh "$BOOT" 2>&1)
  check "autostart=on exits 0" "0" "$?"
  check "autostart=on calls dshd start" "start" "$(cat "$TMP/dshd.calls" 2>/dev/null)"

  # KernelSU sets KSU=true in the scripts it runs; the log should say so, because
  # "which root solution ran this" is the first question when it misbehaves.
  contains "the autostart log names KernelSU" "dshd-autostart[KernelSU]" "$(cat "$DSH_LOG/autostart.log" 2>/dev/null)"

  # KernelSU runs general scripts only if they are executable; the script itself
  # must not be the reason it silently never runs.
  if [ -x "$BOOT" ]; then pass "the boot script is executable in the repo"; else fail "the boot script is executable in the repo"; fi

  # Not installed: a missing install is not an error at boot.
  rm -f "$DSH_BASE/bin/dshd"
  out=$(KSU=true DSH_BASE="$DSH_BASE" DSH_AUTOSTART_WAIT=0 /bin/sh "$BOOT" 2>&1)
  check "a missing install exits 0 quietly" "0" "$?"
  check "and prints nothing" "" "$out"
}

# ===========================================================================
# 9. §7 firewall integration
# ===========================================================================
#
# The rule set itself is tests/firewall.test.sh's job. What is tested here is the
# handover: dshd must refuse to start when told to apply rules it cannot find,
# and it must actually hand the script the uid and ports it needs. Before this
# was tested, `firewall.sh apply` received none of its inputs.

case_firewall_missing() {
  env_new
  DSH_FIREWALL=on
  export DSH_FIREWALL
  out=$(dshd start 2>&1)
  rc=$?
  check "DSH_FIREWALL=on with no script exits 1" "1" "$rc"
  contains "and names the file it wanted" "tools/firewall.sh is missing" "$out"
}

# Start the supervisor, let it install the firewall, then take it down again.
stop_quietly() {
  SUPERVISOR_PID=$(pid_of "$DSH_RUN/supervisor.pid")
  if alive "$SUPERVISOR_PID"; then
    kill -TERM "$SUPERVISOR_PID" 2>/dev/null
    wait_until 20 sh -c "! kill -0 $SUPERVISOR_PID 2>/dev/null"
  fi
  SUPERVISOR_PID=""
}

case_firewall_handover() {
  env_new
  DSHD_DRY_RUN=0
  DSH_FIREWALL=on
  DSH_APP_UID=10123
  DSH_START_TIMEOUT=1 # readiness is not the subject here; the handover is
  export DSHD_DRY_RUN DSH_FIREWALL DSH_APP_UID DSH_START_TIMEOUT
  make_id_double
  make_self_shim

  mkdir -p "$DSH_BASE/tools"
  cat >"$DSH_BASE/tools/firewall.sh" <<EOF
#!/bin/sh
# Stand-in: records what it was handed, and claims success.
env | grep -E '^DSH_' | sort >"$TMP/handover.env"
printf 'firewall: stand-in applied\n'
exit 0
EOF
  chmod +x "$DSH_BASE/tools/firewall.sh"

  out=$(dshd start 2>&1)
  contains "start reports the firewall step" "applying firewall rule (app uid: 10123)" "$out"

  handed=$(cat "$TMP/handover.env" 2>/dev/null)
  contains "the script receives the app uid" "DSH_APP_UID=10123" "$handed"
  contains "the script receives the harness port" "DSH_HARNESS_PORT=$DSH_HARNESS_PORT" "$handed"
  contains "the script receives the guard port" "DSH_GUARD_PORT=$DSH_GUARD_PORT" "$handed"
  contains "the script's own output reaches the log" "stand-in applied" "$out"
  stop_quietly

  # A script that fails must not be reported as a success.
  env_new
  DSHD_DRY_RUN=0
  DSH_FIREWALL=on
  DSH_APP_UID=10123
  DSH_START_TIMEOUT=1
  export DSHD_DRY_RUN DSH_FIREWALL DSH_APP_UID DSH_START_TIMEOUT
  make_id_double
  make_self_shim
  mkdir -p "$DSH_BASE/tools"
  cat >"$DSH_BASE/tools/firewall.sh" <<'EOF'
#!/bin/sh
printf 'iptables: owner: Invalid argument
' >&2
exit 4
EOF
  chmod +x "$DSH_BASE/tools/firewall.sh"

  out=$(dshd start 2>&1)
  contains "a failing firewall script is reported as incomplete" "the §7 mitigation is incomplete" "$out"
  contains "and its diagnosis survives into the log" "owner: Invalid argument" "$out"
  stop_quietly
}

# ===========================================================================
# 10. Device path model: what a child is told inside a real chroot
# ===========================================================================
#
# Everything above runs with DSHD_NO_CHROOT=1, where in_rootfs_path() *prefixes*
# the rootfs — so a host path handed to a child resolves here and cannot resolve
# on a device, where the state directory is a bind mount at /state. That is
# exactly how two fatal bugs lived in start_guard(): it pointed the guard at
# /data/local/dsh/state/guard.token, and it checked for the guard script at
# /opt/dsh-android/guard.mjs on the host, where neither exists inside a chroot.
# Both would have stopped the §7 control from ever starting on hardware, with a
# green suite. This case makes the difference observable without a device:
# DSHD_NO_CHROOT=0 for real, with `mount` and `chroot` stubbed to record argv.
case_chroot_argv() {
  env_new
  DSHD_NO_CHROOT=0
  DSHD_DRY_RUN=0
  export DSHD_NO_CHROOT DSHD_DRY_RUN
  make_rootfs_shims
  make_id_double
  make_self_shim

  # `chroot` records what it was asked to run and then stays alive, so the
  # supervisor sees a live pair instead of restarting it under the test.
  cat >"$TMP/bin/mount" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/mount.calls"
exit 0
EOF
  cat >"$TMP/bin/chroot" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/chroot.calls"
exec sleep 30
EOF
  chmod +x "$TMP/bin/mount" "$TMP/bin/chroot"

  # The launch-token line the real harness prints. Without it the guard step is
  # never reached: dshd waits, then refuses to start a guard it cannot
  # authenticate — correct, but not what this case is measuring.
  printf 'dsh web: http://127.0.0.1:%s/?token=%s\n' "$DSH_HARNESS_PORT" \
    "seeded_launch_token_0123456789abcdefghijkl" >"$DSH_LOG/harness.log"

  sh "$DSHD" supervise >/dev/null 2>&1 &
  sup=$!
  if wait_until 20 grep -q "guard.mjs" "$TMP/chroot.calls" 2>/dev/null; then
    pass "the guard is started under a chroot"
  else
    fail "the guard is started under a chroot" \
      "chroot was never asked to run the guard: $(cat "$TMP/chroot.calls" 2>/dev/null)"
  fi
  kill -TERM "$sup" 2>/dev/null
  wait "$sup" 2>/dev/null

  calls=$(cat "$TMP/chroot.calls" 2>/dev/null)
  guard_line=$(printf '%s\n' "$calls" | grep "guard.mjs" | tail -n 1)
  harness_line=$(printf '%s\n' "$calls" | grep -v "guard.mjs" | grep "dsh" | tail -n 1)

  # The argument must be the child's view of the file...
  contains "the guard is told to read its token at the in-rootfs path" \
    "--token-file /state/guard.token" "$guard_line"
  contains "and the harness token the same way" \
    "--upstream-token-file /state/harness.token" "$guard_line"
  # ...and not the host's view, which is what broke on devices.
  lacks "the guard is not handed the host path to the token" \
    "$DSH_STATE/guard.token" "$guard_line"
  # The harness is started with an in-rootfs binary, not a host path.
  contains "the harness runs from its in-rootfs path" "/usr/local/bin/dsh" "$harness_line"
  lacks "the harness is not run through a host path" "$DSH_ROOTFS/usr/local/bin/dsh" "$harness_line"

  # The state directory is a bind mount on a device; the same source must be
  # mounted there, or the child's /state would be an empty directory and the
  # token path above would be correct and still unreadable. Mounting lives in
  # `dshd mounts` (start calls it before spawning the supervisor), so ask for it
  # directly rather than waiting on a readiness the stubs never provide.
  sh "$DSHD" mounts >/dev/null 2>&1
  mounts=$(cat "$TMP/mount.calls" 2>/dev/null)
  contains "state is bind-mounted where the child expects it" \
    "bind $DSH_STATE $DSH_ROOTFS/state" "$mounts"
  contains "the workspace is bind-mounted too" \
    "bind $DSH_WORKSPACE $DSH_ROOTFS/workspace" "$mounts"

  # The captured token lands on the host side, root-only.
  if [ -s "$DSH_STATE/harness.token" ]; then
    pass "the harness launch token is captured for the guard"
  else
    fail "the harness launch token is captured for the guard"
  fi
  check "the captured launch token is 0600" "-rw-------" \
    "$(ls -l "$DSH_STATE/harness.token" 2>/dev/null | cut -c1-10)"
  check "the captured token is the one the harness printed" \
    "seeded_launch_token_0123456789abcdefghijkl" "$(cat "$DSH_STATE/harness.token" 2>/dev/null)"
}

# ===========================================================================

case_syntax
case_contract
case_not_root
case_status_fresh
case_token_absent
case_posture
case_start_dry_run
case_start_idempotent
case_stale_pid
case_rotation
case_supervise_loop
case_root_solutions
case_su_resolution
case_boot_autostart
case_firewall_missing
case_firewall_handover
case_real_pair
case_orphaned_children
case_chroot_argv

printf '\n%s run, %s failed, %s skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
