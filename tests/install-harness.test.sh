#!/bin/sh
# Host-side tests for tools/install-harness.sh (Phase 2).
#
# Two things are being tested. The first is the plumbing: which failures exit
# with which code, and that a re-run does not quietly reinstall over a working
# tree. The second is the reason this script exists — the *contract* it asserts
# before declaring the install good. That contract is the harness's auth
# behaviour, and the tests here drive it with a stand-in harness that can be told
# to satisfy it, ignore it, or bind the wrong interface. A smoke test that only
# ever sees a healthy server proves nothing, so the negative controls matter as
# much as the happy path.
#
# The chroot is stubbed rather than simulated: the stub maps `/usr/local/bin/node`
# to the same path under the fake rootfs and runs it on the host. That is enough
# to exercise every decision the script makes, and it keeps the real harness
# (and the real device) out of the loop.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
SETUP="$REPO/tools/install-harness.sh"
REAL_ID=$(command -v id 2>/dev/null || true)
NODE_BIN=$(command -v node 2>/dev/null || true)

[ -f "$SETUP" ] || { echo "install-harness.sh not found at $SETUP" >&2; exit 1; }

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
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 6)" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "did not expect [$2] in: $(printf '%s' "$3" | tail -n 6)" ;;
    *) pass "$1" ;;
  esac
}

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
TMP=""
trap cleanup EXIT INT TERM

# --- environment ------------------------------------------------------------

# A fake rootfs with the shape the script insists on, plus a stand-in harness
# whose behaviour each case chooses.
make_env() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-harness-test.XXXXXX") || exit 1
  DSH_BASE="$TMP/dsh"
  DSH_ROOTFS="$DSH_BASE/rootfs"
  DSH_STATE="$DSH_BASE/state"
  DSH_LOG="$DSH_BASE/log"
  export DSH_BASE DSH_ROOTFS DSH_STATE DSH_LOG

  mkdir -p "$DSH_ROOTFS/usr/local/bin" "$DSH_ROOTFS/bin" "$DSH_ROOTFS/etc" \
    "$DSH_ROOTFS/opt/dsh-android" "$DSH_ROOTFS/var/cache" "$DSH_ROOTFS/proc" \
    "$DSH_ROOTFS/tmp" "$TMP/bin" "$DSH_LOG" "$DSH_STATE"
  printf 'nameserver 1.1.1.1\n' >"$DSH_ROOTFS/etc/resolv.conf"

  # Per-case hygiene. The stand-ins read these from the environment, so a case
  # that exports one decides the next case's behaviour — which is how 32 checks
  # failed the first time this suite ran.
  unset VIEW_RESULT INSTALL_EXIT HARNESS_MODE HARNESS_VERSION 2>/dev/null || true

  # /bin/sh inside the rootfs, so `chroot <rootfs> /bin/sh -c ...` works through
  # the stub. An absolute symlink resolves against the host, which is the point.
  ln -sf /bin/sh "$DSH_ROOTFS/bin/sh"
  ln -sf "$NODE_BIN" "$DSH_ROOTFS/usr/local/bin/node"

  make_id_double
  make_chroot_stub
  make_npm_standin
  make_harness_standin
}

# The container the script insists on; nothing here needs real root.
make_id_double() {
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

# Run a command "inside" the rootfs: strip the env preamble, then map absolute
# paths onto the fake rootfs. Close enough to chroot for every decision the
# script makes, and it keeps the suite on the host.
make_chroot_stub() {
  cat >"$TMP/bin/chroot" <<'EOF'
#!/bin/sh
rootfs=$1
shift
if [ "${1:-}" = /usr/bin/env ]; then
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -i) shift ;;
      *=*) shift ;;
      *) break ;;
    esac
  done
fi
cmd=$1
shift
case "$cmd" in
  /*) cmd="$rootfs$cmd" ;;
esac
[ -x "$cmd" ] || { echo "chroot-stub: not executable: $cmd" >&2; exit 127; }

# Arguments too: inside a real chroot an in-rootfs path like
# /var/tmp/dsh-p2-smoke/probe.mjs resolves against the new root, and the smoke
# test passes exactly that to node. Mapped only when the target exists, so host
# paths the script legitimately reads (an absent /proc/net/tcp, say) stay as they
# are and keep their real behaviour.
n=$#
i=0
while [ "$i" -lt "$n" ]; do
  a=$1
  shift
  case "$a" in
    /*) [ -e "$rootfs$a" ] && a="$rootfs$a" ;;
  esac
  set -- "$@" "$a"
  i=$((i + 1))
done

exec "$cmd" "$@"
EOF
  chmod +x "$TMP/bin/chroot"

  # mount is only asked to succeed; the smoke test does not need real mounts.
  cat >"$TMP/bin/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/mount"
}

# npm, scripted per case. VIEW_RESULT is what `npm view` answers, INSTALL_EXIT is
# what `npm install` exits with. On a successful install it writes the `dsh`
# stand-in, which is what the script then checks for.
make_npm_standin() {
  cat >"$DSH_ROOTFS/usr/local/bin/npm" <<EOF
#!/bin/sh
case "\${1:-}" in
  view) printf '%s\n' "\${VIEW_RESULT:-0.2.0-rc.2}"; exit 0 ;;
  install)
    printf '%s\n' "\$*" >>"$TMP/npm-install.args"
    [ "\${INSTALL_EXIT:-0}" = 0 ] || exit "\$INSTALL_EXIT"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$DSH_ROOTFS/usr/local/bin/npm"
}

# The stand-in harness. HARNESS_MODE selects the contract it honours:
#   auth  — the real behaviour (401 / 303 + cookie)
#   open  — no auth at all; the probe must fail it
#   wild  — honours auth but binds 0.0.0.0; the probe must fail it
#   nohelp— `web --help` omits the flags, as a profile that failed to load would
#   silent— never prints the launch-token line, which dshd depends on
#   acceptall — accepts --host 0.0.0.0, which must fail the install
make_harness_standin() {
  cat >"$DSH_ROOTFS/opt/harness-standin.mjs" <<'EOS'
const http = await import('node:http').then((m) => m.default)
const mode = process.env.HARNESS_MODE || 'auth'
const port = Number(process.env.HARNESS_PORT || 0)
const token = 'standin-launch-token-0123456789abcdefghij'
const COOKIE = 'dsh-auth-stub'
http
  .createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const cookie = String(req.headers.cookie || '')
    if (mode === 'open') {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end('<!doctype html><html>wide open</html>')
      return
    }
    if (url.searchParams.getAll('token').length) {
      if (url.pathname === '/' && url.searchParams.get('token') === token) {
        res.writeHead(303, { location: './', 'set-cookie': `${COOKIE}=v1.x.y; Path=/; HttpOnly; SameSite=Strict` })
        res.end()
        return
      }
      res.writeHead(401)
      res.end('nope')
      return
    }
    if (url.pathname === '/' && cookie.includes(`${COOKIE}=`)) {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end('<!doctype html><html>ui</html>')
      return
    }
    if (url.pathname === '/api' && cookie.includes(`${COOKIE}=`)) {
      if (req.method === 'POST' && req.headers.origin && req.headers.origin !== `http://127.0.0.1:${port}`) {
        res.writeHead(403)
        res.end('fence')
        return
      }
      res.writeHead(404)
      res.end('no route')
      return
    }
    res.writeHead(401)
    res.end('dsh web authentication required')
  })
  .listen(port, mode === 'wild' ? '0.0.0.0' : '127.0.0.1', () => {
    if (mode !== 'silent') console.log(`dsh web: http://127.0.0.1:${port}/?token=${token}`)
  })
EOS

  cat >"$DSH_ROOTFS/usr/local/bin/dsh" <<EOF
#!/bin/sh
mode=\${HARNESS_MODE:-auth}
case "\${1:-}" in
  --version) printf '%s\n' "\${HARNESS_VERSION:-0.2.0-rc.2}"; exit 0 ;;
  web)
    shift
    port=0
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --help | -h)
          printf 'Usage: dsh --profile web [options]\n'
          [ "\$mode" = nohelp ] || printf '  --no-open  do not open the browser\n'
          printf '  --port <port>  listen port\n'
          exit 0
          ;;
        --host) shift; [ "\$1" = 0.0.0.0 ] && [ "\$mode" != acceptall ] && { printf 'error: --host 0.0.0.0 is intentionally not supported\n' >&2; exit 1; } ;;
        --port) shift; port=\$1 ;;
      esac
      shift
    done
    HARNESS_PORT="\$port" HARNESS_MODE="\$mode" exec "$NODE_BIN" "$DSH_ROOTFS/opt/harness-standin.mjs"
    ;;
esac
exit 0
EOF
  chmod +x "$DSH_ROOTFS/usr/local/bin/dsh"
}

install() { sh "$SETUP" "$@"; }

# Every case runs the script with the rootfs it just made and no apt, no libs.
run_install() {
  sh "$SETUP" --skip-libs --no-apt "$@"
}

# ===========================================================================
# 1. Preflight: the failures that must not touch anything
# ===========================================================================

case_preflight() {
  make_env
  rm -rf "$DSH_ROOTFS"
  out=$(run_install 2>&1)
  rc=$?
  check "a missing rootfs exits 3" "3" "$rc"
  contains "and names Phase 1" "run tools/rootfs-setup.sh" "$out"

  make_env
  rm -f "$DSH_ROOTFS/usr/local/bin/node"
  out=$(run_install 2>&1)
  rc=$?
  check "a rootfs with no Node exits 3" "3" "$rc"
  contains "and points at the missing binary" "no Node at" "$out"

  make_env
  cat >"$TMP/bin/id" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -u) printf '1000\n' ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF
  chmod +x "$TMP/bin/id"
  out=$(run_install 2>&1)
  rc=$?
  check "not root exits 2" "2" "$rc"
  contains "and says why root is needed" "must run as root" "$out"
}

case_args() {
  make_env
  out=$(run_install --smoke-port abc 2>&1)
  check "a non-numeric --smoke-port exits 1" "1" "$?"
  contains "and says so" "must be a number" "$out"

  out=$(run_install --nonsense 2>&1)
  check "an unknown argument exits 1" "1" "$?"
  contains "and suggests --help" "try --help" "$out"

  out=$(sh "$SETUP" --help 2>&1)
  check "--help exits 0" "0" "$?"
  contains "--help documents the pin" "--version V" "$out"
}

# ===========================================================================
# 2. Idempotence: an existing install is not silently replaced
# ===========================================================================

case_already_installed() {
  make_env
  mkdir -p "$DSH_ROOTFS/opt/dsh-android"
  printf 'version=0.1.0-rc.1\n' >"$DSH_ROOTFS/opt/dsh-android/harness.manifest"
  : >"$TMP/npm-install.args"

  out=$(run_install 2>&1)
  rc=$?
  check "an existing install exits 5" "5" "$rc"
  contains "and reports the installed version" "already installed" "$out"
  contains "and names the version it found" "0.1.0-rc.1" "$out"
  if [ -s "$TMP/npm-install.args" ]; then
    fail "an existing install is not reinstalled" "npm was invoked: $(cat "$TMP/npm-install.args")"
  else
    pass "an existing install is not reinstalled"
  fi

  # --force must actually replace it.
  out=$(run_install --force 2>&1)
  check "--force reinstalls" "0" "$?"
  check "and the manifest now names the pin" "0.2.0-rc.2" \
    "$(sed -n 's/^version=//p' "$DSH_ROOTFS/opt/dsh-android/harness.manifest")"
}

# ===========================================================================
# 3. The install step itself
# ===========================================================================

case_version_pin() {
  make_env
  # The registry answering with something other than the pin is the case that
  # matters: installing a different version than requested must be fatal, not a
  # note in a log.
  VIEW_RESULT=0.3.0-rc.1
  export VIEW_RESULT
  out=$(run_install 2>&1)
  rc=$?
  check "a registry that resolves elsewhere exits 4" "4" "$rc"
  contains "and refuses to install what it got" "refusing to install something other than the pin" "$out"

  make_env
  INSTALL_EXIT=1
  export INSTALL_EXIT
  out=$(run_install 2>&1)
  rc=$?
  check "a failed npm install exits 4" "4" "$rc"
  contains "and mentions the install scripts" "install script" "$out"
}

case_ignores_scripts() {
  make_env
  out=$(run_install 2>&1)
  rc=$?
  check "a happy-path install exits 0" "0" "$rc"
  contains "npm is asked to ignore install scripts" "--ignore-scripts" "$(cat "$TMP/npm-install.args" 2>/dev/null)"
  contains "and is given an exact version" "@deepseek-ai/dsh@0.2.0-rc.2" "$(cat "$TMP/npm-install.args" 2>/dev/null)"
  # The manifest is a record of what is installed; it is 0600 because it names
  # paths inside the harness home.
  check "the manifest records the pinned version" "0.2.0-rc.2" \
    "$(sed -n 's/^version=//p' "$DSH_ROOTFS/opt/dsh-android/harness.manifest")"
  check "the manifest is 0600" "-rw-------" \
    "$(ls -l "$DSH_ROOTFS/opt/dsh-android/harness.manifest" | cut -c1-10)"
  contains "the manifest records the Node it was built against" "node=v" \
    "$(cat "$DSH_ROOTFS/opt/dsh-android/harness.manifest")"
}

# ===========================================================================
# 4. Verification: the boot path and the bind refusal
# ===========================================================================

case_verify() {
  make_env
  HARNESS_VERSION=0.2.0-rc.99
  export HARNESS_VERSION
  out=$(run_install --skip-smoke 2>&1)
  rc=$?
  check "a dsh that reports another version exits 5" "5" "$rc"
  contains "and says the install is not the pin" "not the pin" "$out"

  make_env
  HARNESS_MODE=nohelp
  export HARNESS_MODE
  out=$(run_install --skip-smoke 2>&1)
  rc=$?
  check "a profile that does not load exits 5" "5" "$rc"
  contains "and reports that the web flags are missing" "did not print the web flags" "$out"

  # The load-bearing one: if a future version binds 0.0.0.0, that is an RCE
  # surface appearing silently, and the install must fail rather than pass.
  # A free port, because the stand-in has to actually reach the listen() call for
  # this to test what it claims to.
  make_env
  HARNESS_MODE=acceptall
  DSH_HARNESS_PORT=41744
  export HARNESS_MODE DSH_HARNESS_PORT
  out=$(run_install --skip-smoke 2>&1)
  rc=$?
  check "a version that accepts --host 0.0.0.0 exits 5" "5" "$rc"
  contains "and says what it means" "bind the agent surface to the network" "$out"

  # The other half of that control: a crash must not be read as a refusal. The
  # port is held by something else, so the flag-accepting stand-in dies with
  # EADDRINUSE after accepting it — the exact shape that made this check pass
  # when it was first written, on a host where 3080 happened to be busy.
  make_env
  BUSY=41745
  HARNESS_MODE=acceptall
  DSH_HARNESS_PORT=$BUSY
  export HARNESS_MODE DSH_HARNESS_PORT
  "$NODE_BIN" -e "require('net').createServer().listen($BUSY,'127.0.0.1')" &
  busy_pid=$!
  sleep 1
  out=$(run_install --skip-smoke 2>&1)
  rc=$?
  kill "$busy_pid" 2>/dev/null
  check "a crash is not mistaken for a refusal" "5" "$rc"
  contains "and the message says the refusal was not confirmed" "not a confirmed refusal" "$out"
}

# ===========================================================================
# 5. The smoke test: the contract, and the negative controls for it
# ===========================================================================

case_smoke_happy() {
  if [ -z "$NODE_BIN" ]; then
    skip "the smoke test" "node is not installed"
    return 0
  fi
  make_env
  out=$(run_install --smoke-port 41731 2>&1)
  rc=$?
  check "the smoke test passes against a contract-honouring harness" "0" "$rc"
  contains "it checks that / is refused" "GET / without a token is refused (status 401)" "$out"
  contains "it checks the launch-token bootstrap" "the launch token mints a session cookie (status 303" "$out"
  contains "it checks the session serves the UI" "the session cookie serves the UI (status 200" "$out"
  contains "it checks the cross-origin fence" "a cross-origin POST is refused" "$out"
  # The count depends on whether this host has a second address to probe, so the
  # assertion is that every check passed rather than how many there were.
  contains "and it reports how many checks ran" "checks passed" "$out"
  lacks "and not one of them failed" "FAIL " "$out"
  contains "the loopback-only bind is asserted" "Gate P2 (install half) PASSED" "$out"
  # The scratch DSH_HOME must not survive: a rehearsal that leaves credentials
  # behind is a rehearsal that changes the thing it is rehearsing.
  lacks "the scratch state directory is removed" "dsh-p2-smoke" "$(ls "$DSH_ROOTFS/var/tmp" 2>/dev/null)"
}

case_smoke_open() {
  if [ -z "$NODE_BIN" ]; then
    skip "the smoke test rejects an open harness" "node is not installed"
    return 0
  fi
  make_env
  HARNESS_MODE=open
  export HARNESS_MODE
  out=$(run_install --smoke-port 41732 2>&1)
  rc=$?
  check "an unauthenticated harness exits 6" "6" "$rc"
  contains "and the failure names the missing refusal" "GET / without a token is refused (status 200)" "$out"
  contains "and the message says the contract does not hold" "the auth contract does not hold" "$out"
}

case_smoke_wild() {
  if [ -z "$NODE_BIN" ]; then
    skip "the smoke test rejects a wild bind" "node is not installed"
    return 0
  fi
  # Only meaningful where the host has a second address to try.
  if ! ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -qv '^127\.'; then
    skip "the smoke test rejects a wild bind" "no non-loopback address on this host"
    return 0
  fi
  make_env
  HARNESS_MODE=wild
  export HARNESS_MODE
  out=$(run_install --smoke-port 41733 2>&1)
  rc=$?
  check "a harness bound to 0.0.0.0 exits 6" "6" "$rc"
  contains "and the failure is the loopback check" "not loopback-only" "$out"
}

case_smoke_no_token() {
  if [ -z "$NODE_BIN" ]; then
    skip "a silent harness" "node is not installed"
    return 0
  fi
  make_env
  HARNESS_MODE=silent
  export HARNESS_MODE
  # dshd extracts the guard token from exactly this line, so its absence has to
  # fail the install rather than surface as a guard that cannot start.
  out=$(sh "$SETUP" --skip-libs --no-apt --smoke-port 41734 2>&1)
  rc=$?
  check "a harness that prints no launch token exits 6" "6" "$rc"
  contains "and says the guard cannot start" "the guard cannot start" "$out"
}

case_skip_smoke_is_loud() {
  make_env
  out=$(run_install --skip-smoke 2>&1)
  rc=$?
  check "--skip-smoke still exits 0" "0" "$rc"
  contains "but warns that nothing was booted" "the harness was NOT booted" "$out"
  contains "and the summary calls the result partial" "PARTIAL" "$out"
}

case_dry_run() {
  make_env
  : >"$TMP/npm-install.args"
  out=$(sh "$SETUP" --skip-libs --dry-run 2>&1)
  rc=$?
  check "a dry run exits 0" "0" "$rc"
  contains "and prints the pin it would install" "would install @deepseek-ai/dsh@0.2.0-rc.2" "$out"
  if [ -s "$TMP/npm-install.args" ]; then
    fail "a dry run does not invoke npm" "$(cat "$TMP/npm-install.args")"
  else
    pass "a dry run does not invoke npm"
  fi
  if [ -f "$DSH_ROOTFS/opt/dsh-android/harness.manifest" ]; then
    fail "a dry run writes no manifest"
  else
    pass "a dry run writes no manifest"
  fi
}

# ===========================================================================
# 6. The pin is recorded where a reader can find it
# ===========================================================================

case_pin_is_documented() {
  # The default pin appears in one place in the script; the README and the plan
  # must not disagree with it, because a version mentioned in two places is a
  # version that will drift.
  pin=$(sed -n 's/^VERSION=\(.*\)$/\1/p' "$SETUP" | head -n 1)
  if [ -n "$pin" ]; then pass "the script declares a default pin"; else fail "the script declares a default pin"; fi
  contains "the pin is the one the dependency study used" "0.2.0-rc.2" "$pin"
}

# ===========================================================================

case_preflight
case_args
case_already_installed
case_version_pin
case_ignores_scripts
case_verify
case_smoke_happy
case_smoke_open
case_smoke_wild
case_smoke_no_token
case_skip_smoke_is_loud
case_dry_run
case_pin_is_documented

printf '\n%s run, %s failed, %s skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
