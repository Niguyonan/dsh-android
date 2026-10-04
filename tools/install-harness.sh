#!/system/bin/sh
# install-harness.sh — Phase 2: install the pinned harness inside the rootfs,
# then prove the contract that everything downstream depends on.
#
# The install itself is one npm command. The value here is the proof, because
# this is the phase where the plan names its highest-risk unknown — "any native
# module resolved at startup" — and where an install can succeed while the
# harness cannot boot.
#
# Three things about this package are worth stating, all measured:
#
#   * **--ignore-scripts.** The tree has exactly five packages with install
#     scripts, and none of them needs to run to produce a runtime file: node-pty
#     ships prebuilds/linux-arm64/pty.node inside its own tarball and its
#     prebuild script only tests for that directory (so node-gyp never runs),
#     koffi's prebuilt binary arrives as a separate optional dependency that npm
#     resolves normally, and the remaining three scripts are inert no-ops. There
#     are no install-time downloads anywhere in the tree, and node-pty is the
#     only package with a binding.gyp, which npm skips because it has an install
#     script. So --ignore-scripts costs nothing and means 500-odd registry
#     packages never execute code as root on the phone.
#   * **libstdc++.** The boot path loads a native addon eagerly —
#     `node-addon-require-builtin` via `@deepseek-ai/dsh-app-boot`'s
#     `installRuntimeInterception` — and it, koffi's addon, and node-pty's all
#     declare DT_NEEDED on libstdc++.so.6 and libgcc_s.1. A minimal Ubuntu base
#     does not ship libstdc++, so without it the harness fails to boot in a way
#     that looks nothing like a missing library. Checked before installing, and
#     installed from the distro rather than vendored.
#   * **The libc guess.** That loader picks the glibc or musl variant of its
#     addon by reading Node's PT_INTERP, then /proc/self/maps, then
#     process.report — and **defaults to musl** if all three fail. Only the
#     glibc variant is installed on this target, so an unmounted /proc turns
#     into a boot failure. This is why the smoke test below runs with the
#     mounts up and why Gate P1 checks the mounts survive a re-chroot.
#
# The smoke test boots the real harness on a scratch port with a scratch
# DSH_HOME, and asserts the auth contract that dshd and the guard are built on:
# loopback-only bind, 401 without a session, the launch-token URL in the log,
# 303 + a signed cookie for that token, and /api reachable with the cookie. A
# version bump that changes any of those is caught here rather than presenting
# as an unreachable UI on a phone. Nothing is written to the real DSH_HOME: the
# smoke test uses its own, so it cannot mint or disturb credentials.
#
# usage: install-harness.sh [options]
#   --version V          harness version to install (default: 0.2.0-rc.2)
#   --force              reinstall over an existing installation
#   --skip-smoke         install and verify the CLI, but do not boot a server
#   --skip-libs          do not check or install shared-library prerequisites
#   --no-apt             fail instead of using apt for a missing library
#   --smoke-port N       port for the smoke server (default: a free high port)
#   --dry-run            print what would happen; change nothing
#
# exit: 0 ok · 1 usage/config · 2 not root · 3 prerequisite failed
#       4 install failed · 5 verification failed · 6 smoke test failed

set -u

: "${DSH_BASE:=/data/local/dsh}"
: "${DSH_ROOTFS:=$DSH_BASE/rootfs}"
: "${DSH_STATE:=$DSH_BASE/state}"
: "${DSH_LOG:=$DSH_BASE/log}"
: "${DSH_HARNESS_PORT:=3080}"
: "${DSH_HARNESS_BIN:=/usr/local/bin/dsh}"
: "${DSH_NODE:=/usr/local/bin/node}"

VERSION=0.2.0-rc.2
SMOKE_PORT=""
SKIP_SMOKE=0
SKIP_LIBS=0
USE_APT=1
FORCE=0
DRY_RUN=0
# Set by preflight when the pinned version is already in the rootfs: the install
# and the manifest are then nothing to do, and everything after them still runs.
INSTALL_SKIP=""

ROOTFS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NPM_CACHE=/var/cache/dsh-npm
MANIFEST=/opt/dsh-android/harness.manifest
SMOKE_DIR=/var/tmp/dsh-p2-smoke

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '%s install-harness: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$*"; }
warn() { log "WARNING: $*"; }

die() {
  code=$1
  shift
  printf 'install-harness: ERROR: %s\n' "$*" >&2
  exit "$code"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command inside the rootfs. Everything the harness and npm do happens
# here, so the environment is explicit rather than inherited: no TERM, no
# Android-specific variables, and HOME inside the rootfs.
in_rootfs() {
  chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root TMPDIR=/tmp LANG=C.UTF-8 \
    "$@"
}

# npm, with its cache pinned inside the rootfs so a re-run is fast and nothing
# is written outside the tree we own.
npm_in_rootfs() {
  chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root TMPDIR=/tmp LANG=C.UTF-8 \
    "npm_config_cache=$NPM_CACHE" npm_config_update_notifier=false \
    npm_config_fund=false npm_config_audit=false \
    /usr/local/bin/npm "$@"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  [ "$DRY_RUN" = 1 ] || [ "$(id -u 2>/dev/null)" = 0 ] || die 2 "must run as root: the chroot and the in-rootfs install need it"

  [ -d "$DSH_ROOTFS" ] || die 3 "no rootfs at $DSH_ROOTFS — run tools/rootfs-setup.sh first (Phase 1)"
  [ -x "$DSH_ROOTFS$DSH_NODE" ] || die 3 "no Node at $DSH_ROOTFS$DSH_NODE — run tools/rootfs-setup.sh first"

  missing=""
  for c in chroot mount mkdir printf date; do
    have "$c" || missing="$missing $c"
  done
  [ -n "$missing" ] && die 3 "missing required commands:$missing"

  if [ ! -s "$DSH_ROOTFS/etc/resolv.conf" ]; then
    warn "$DSH_ROOTFS/etc/resolv.conf is empty or missing — npm cannot resolve registry.npmjs.org. Re-run tools/rootfs-setup.sh."
  fi

  installed=$(installed_version)
  if [ -n "$installed" ] && [ "$FORCE" != 1 ]; then
    if [ "$installed" = "$VERSION" ]; then
      # The pinned version is already in the rootfs: nothing to install, and
      # nothing to replace either. This used to be fatal for *any* installed
      # version, which made a second `dshd setup` stop at the harness step on a
      # device whose harness was installed and running — while the rootfs step
      # one screen earlier *skips* in exactly this case, so one setup run
      # reported "skip" and "fail" for the two halves of the same state. The
      # verification and the smoke test below still run: a re-run is where those
      # earn their keep, and they are what makes skipping the install honest.
      INSTALL_SKIP="the pinned $VERSION is already installed"
    else
      die 5 "the harness is already installed in this rootfs (version $installed). Re-run with --force to replace it, or use tools/update.sh for a version bump."
    fi
  fi
}

# The version recorded in the manifest, if this rootfs has one. Read from inside
# the rootfs so a rootfs replaced by --force cannot leave a stale manifest
# behind claiming an install that no longer exists.
installed_version() {
  [ -f "$DSH_ROOTFS$MANIFEST" ] || return 0
  sed -n 's/^version=//p' "$DSH_ROOTFS$MANIFEST" 2>/dev/null | head -n 1
}

# Mounts first: the smoke test needs /proc for the loader's libc detection and
# for the listening-socket check, and npm wants /dev/urandom.
ensure_mounts() {
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would ensure the chroot mounts"; return 0; }
  if [ -x "$DSH_BASE/bin/dshd" ]; then
    # Asking dshd means the runtime and this check cannot drift apart.
    sh "$DSH_BASE/bin/dshd" mounts >/dev/null 2>&1 || warn "dshd mounts reported a problem; continuing"
  else
    mkdir -p "$DSH_ROOTFS/proc" "$DSH_ROOTFS/dev/pts"
    mount -t proc proc "$DSH_ROOTFS/proc" 2>/dev/null || warn "mount -t proc failed"
    mount -o bind /dev "$DSH_ROOTFS/dev" 2>/dev/null || warn "bind /dev failed"
  fi
}

# ---------------------------------------------------------------------------
# Shared libraries
# ---------------------------------------------------------------------------
#
# A functional check, not a package-list check: what matters is that the files
# the addons name actually resolve. ldd is the tool that answers that, and it is
# run against the installed artifacts after the install — but the install is the
# expensive step, so the cheap pre-check happens first and the authoritative one
# inside verify().

missing_libs() {
  # The addons on the boot path declare DT_NEEDED on libstdc++.so.6, which a
  # minimal Ubuntu base does not ship. libgcc_s and libutil come with libgcc-s1
  # and libc6 respectively, so they are not checked separately.
  #
  # Each pattern is asked about on its own, and that is a fix rather than a
  # style. `ls /usr/lib/*/libstdc++.so.6* /usr/lib/libstdc++.so.6*` exits
  # non-zero when *either* pattern matches nothing, and on the Ubuntu base a
  # device installs, the library lives only under the multiarch triplet that the
  # first pattern covers: ls listed the file and failed on the second pattern
  # anyway, this function called the library missing, apt answered "libstdc++6
  # is already the newest version", and the run died with "libstdc++6 still does
  # not resolve after installing it" — on a rootfs where it resolved fine. The
  # flat path is still tried: a base image that puts it there is equally good.
  #
  # Looked at from here rather than from inside, because the paths are the
  # rootfs's: `"$DSH_ROOTFS"/usr/lib/*/…` is a question this shell can ask, and
  # the alternative — a shell inside the chroot expanding a pattern — is a
  # question no host-side test can arrange, which is how the two-pattern version
  # stayed untested.
  for p in "$DSH_ROOTFS"/usr/lib/*/libstdc++.so.6* "$DSH_ROOTFS"/usr/lib/libstdc++.so.6*; do
    [ -e "$p" ] && return 0
  done
  printf 'libstdc++.so.6\n'
}

check_libs() {
  [ "$SKIP_LIBS" = 1 ] && { log "phase 2a: shared libraries skipped (--skip-libs)"; return 0; }
  log "phase 2a: shared-library prerequisites"
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would check libstdc++ and install it if absent"; return 0; }

  if [ "$(id -u 2>/dev/null)" != 0 ]; then
    return 0
  fi
  missing=$(missing_libs)
  if [ -z "$missing" ]; then
    log "libstdc++ is present"
    return 0
  fi

  warn "missing: $(printf '%s' "$missing" | tr '\n' ' ')— the eager native load on the boot path needs it"
  if [ "$USE_APT" != 1 ]; then
    die 3 "missing shared libraries and --no-apt was given. Install them with:
    chroot $DSH_ROOTFS /usr/bin/env PATH=$ROOTFS_PATH apt-get update
    chroot $DSH_ROOTFS /usr/bin/env PATH=$ROOTFS_PATH apt-get install -y --no-install-recommends libstdc++6"
  fi

  # The base image ships apt sources; libstdc++6 is ~1 MB and is a hard
  # requirement, so installing it is part of the phase rather than a surprise.
  log "installing libstdc++6 from the distro"
  in_rootfs /usr/bin/apt-get update >/dev/null 2>&1 || warn "apt-get update failed; trying the install anyway"
  if ! in_rootfs /usr/bin/apt-get install -y --no-install-recommends libstdc++6; then
    die 3 "could not install libstdc++6 inside the rootfs — check $DSH_ROOTFS/etc/resolv.conf and the apt sources"
  fi
  [ -n "$(missing_libs)" ] && die 3 "libstdc++6 still does not resolve after installing it"
  log "installed libstdc++6"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

step_install() {
  if [ -n "$INSTALL_SKIP" ]; then
    log "phase 2b: npm install skipped ($INSTALL_SKIP)"
    return 0
  fi
  log "phase 2b: npm install --global @deepseek-ai/dsh@$VERSION (--ignore-scripts)"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would install @deepseek-ai/dsh@$VERSION into $DSH_ROOTFS/usr/local"
    return 0
  fi

  mkdir -p "$DSH_ROOTFS$NPM_CACHE"

  # Resolve before installing, so a typo or an unpublished version is a clear
  # message instead of an npm resolution error three screens long.
  resolved=$(npm_in_rootfs view "@deepseek-ai/dsh@$VERSION" version 2>/dev/null | tr -d '\r' | tail -n 1)
  if [ -z "$resolved" ]; then
    die 4 "cannot resolve @deepseek-ai/dsh@$VERSION from the registry inside the rootfs (network, DNS, or the version does not exist)"
  fi
  if [ "$resolved" != "$VERSION" ]; then
    die 4 "the registry resolved @deepseek-ai/dsh@$VERSION to '$resolved' — refusing to install something other than the pin"
  fi

  if ! npm_in_rootfs install --global --ignore-scripts --no-fund --no-audit --loglevel=error \
    "@deepseek-ai/dsh@$VERSION"; then
    die 4 "npm install failed — see the output above. A package that needs an install script would be the cause; the pinned tree has none that matter."
  fi

  [ -x "$DSH_ROOTFS$DSH_HARNESS_BIN" ] || die 4 "install reported success but $DSH_ROOTFS$DSH_HARNESS_BIN is not executable"
  log "installed into /usr/local inside the rootfs"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
#
# Written inside the rootfs on purpose: a rootfs replaced by `rootfs-setup.sh
# --force` takes the manifest with it, so there is no stale record of an install
# that no longer exists. Plain key=value so POSIX sh can read it without jq, and
# 0600 because it names the harness home and version but no secrets.

step_manifest() {
  if [ -n "$INSTALL_SKIP" ]; then
    # The manifest is the record of an install that did not happen this time: it
    # is already there, and rewriting it would move installed_at for no reason.
    log "phase 2c: manifest kept ($INSTALL_SKIP)"
    return 0
  fi
  log "phase 2c: manifest at $MANIFEST"
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would write $MANIFEST"; return 0; }
  mkdir -p "$DSH_ROOTFS/opt/dsh-android"
  node_version=$(in_rootfs "$DSH_NODE" -v 2>/dev/null)
  (
    umask 077
    {
      printf 'package=@deepseek-ai/dsh\n'
      printf 'version=%s\n' "$VERSION"
      printf 'node=%s\n' "$node_version"
      printf 'installed_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
      printf 'globals=/usr/local/lib/node_modules\n'
      printf 'cache=%s\n' "$NPM_CACHE"
      printf 'installed_by=tools/install-harness.sh\n'
    } >"$DSH_ROOTFS$MANIFEST"
  ) || die 3 "cannot write $DSH_ROOTFS$MANIFEST"
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

# The boot-path native load, which `dsh web --help` exercises: the loader is
# installed during boot, before any profile-specific work, and the app's own
# help text is produced without binding a server (the bundle patch says so, and
# the smoke test below confirms it independently).
step_verify() {
  log "phase 2d: CLI and boot-path native load"
  [ "$DRY_RUN" = 1 ] && { log "dry-run: would run dsh --version and dsh web --help"; return 0; }

  out=$(in_rootfs "$DSH_HARNESS_BIN" --version 2>&1) || die 5 "dsh --version failed: $out"
  reported=$(printf '%s\n' "$out" | tr -d '\r' | tail -n 1)
  [ "$reported" = "$VERSION" ] || die 5 "dsh --version reported '$reported', expected '$VERSION' — the install is not the pin"
  log "dsh --version: $reported"

  if ! out=$(in_rootfs "$DSH_HARNESS_BIN" web --help 2>&1); then
    die 5 "dsh web --help failed, so the profile tree does not load: $out
  This is the boot-path native load. The usual causes are a missing libstdc++6, an unmounted /proc (the loader then guesses musl), or a /tmp that cannot be written and executed."
  fi
  case "$out" in
    *--no-open*) : ;;
    *) die 5 "dsh web --help did not print the web flags; the web profile did not load:
$out" ;;
  esac
  log "the web profile loads and prints its own flags"

  # The refusal is a control: if a future version starts accepting 0.0.0.0, that
  # is a remote-code-execution surface appearing silently, and it should be a
  # failing install rather than a discovery on a network.
  #
  # Bounded, because the failure mode of this check is the check itself: a
  # version that *accepts* the flag would start a server and the command would
  # never return, hanging the install instead of reporting the problem.
  #
  # And it demands a refusal that names the address it refuses, because
  # "exited non-zero" is not evidence of a refusal: during development of this
  # script a port collision (EADDRINUSE) made a flag-accepting stand-in crash,
  # and the crash was read as a pass. A control that can be satisfied by an
  # unrelated failure is not a control.
  wild_log="$DSH_LOG/.host-check.log"
  # A direct `chroot` invocation rather than the in_rootfs() helper, and not for
  # style: backgrounding a *function* makes $! the wrapper subshell, so killing it
  # leaves the server it started running. That is the same trap spawn_in_rootfs()
  # in bin/dshd exists to avoid, and here it would strand an unauthenticated
  # listener on the device after a failed check.
  chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root TMPDIR=/tmp LANG=C.UTF-8 \
    "$DSH_HARNESS_BIN" web --no-open --host 0.0.0.0 --port "$DSH_HARNESS_PORT" >"$wild_log" 2>&1 &
  wild_pid=$!
  waited=0
  while [ "$waited" -lt 10 ]; do
    kill -0 "$wild_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$wild_pid" 2>/dev/null; then
    kill -9 "$wild_pid" 2>/dev/null
    die 5 "dsh web did not refuse --host 0.0.0.0 — it was still running after 10s. This version will bind the agent surface to the network. Do not run it on a device without re-doing §7."
  fi
  wait "$wild_pid" 2>/dev/null
  wild_rc=$?
  wild_out=$(cat "$wild_log" 2>/dev/null)
  rm -f "$wild_log"
  [ "$wild_rc" -ne 0 ] || die 5 "dsh web exited 0 for --host 0.0.0.0 — this version accepts it. Do not run it on a device without re-doing §7."
  case "$wild_out" in
    *0.0.0.0*)
      log "--host 0.0.0.0 is refused, and the refusal names the address"
      ;;
    *)
      die 5 "dsh web exited $wild_rc for --host 0.0.0.0 without saying anything about the address, so this is not a confirmed refusal — it may be a crash for another reason (a busy port, a missing library). Output:
$wild_out"
      ;;
  esac

  # The authoritative library check, against what is actually installed.
  if have ldd; then
    missing=""
    for so in $(in_rootfs /bin/sh -c "ls /usr/local/lib/node_modules/@deepseek-ai/*/bin/*/*.node /usr/local/lib/node_modules/node-pty/prebuilds/linux-*/pty.node 2>/dev/null"); do
      # ldd runs on the host against a rootfs path, which is why the path is
      # translated rather than passed as the child sees it.
      notfound=$(ldd "$DSH_ROOTFS$so" 2>/dev/null | awk '/not found/ { print $1 }')
      [ -n "$notfound" ] && missing="$missing $so:$notfound"
    done
    if [ -n "$missing" ]; then
      warn "native addons with unresolved libraries:$missing"
    else
      log "every installed native addon resolves its libraries"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
#
# Risk accepted and stated: the harness has no unauthenticated mode, but during
# the window between bind and stop this server is reachable by any app on the
# device, and it is unauthenticated until it mints its cookie. It binds loopback
# on a scratch high port, holds a scratch DSH_HOME, and is stopped immediately —
# and `--skip-smoke` exists for a device where that window is not acceptable.
# The alternative is shipping an install whose boot path was never executed.

# The probe runs *inside* the chroot and uses Node's own fetch, because the base
# image has no curl and Node is the one HTTP client guaranteed to be present.
write_probe() {
  cat >"$DSH_ROOTFS$SMOKE_DIR/probe.mjs" <<'EOS'
// Gate P2 (install half): the auth contract dshd and the guard are built on.
// Every assertion here is a thing that was measured against 0.2.0-rc.2, and a
// version that changes any of them breaks the deployment in a way that would
// otherwise show up as an unreachable UI on a phone.
const net = await import('node:net').then((m) => m.default)
const [port, token, otherIp] = process.argv.slice(2)
const base = `http://127.0.0.1:${port}`
const results = []
const rec = (name, ok, detail) => results.push({ name, ok, detail })

// The only check here that tests the *bind* rather than the auth: a server on
// 0.0.0.0 answers on every interface, so a refusal on a non-loopback address is
// evidence of a loopback-only bind. Skipped when no other address is known.
function offLoopbackRefused() {
  return new Promise((resolve) => {
    if (!otherIp) return resolve(null)
    const socket = net.connect({ host: otherIp, port: Number(port) })
    const settle = (v) => {
      socket.destroy()
      resolve(v)
    }
    socket.on('connect', () => settle(false))
    socket.on('error', () => settle(true))
    socket.setTimeout(4000, () => settle(true))
  })
}

async function main() {
  const offLoopback = await offLoopbackRefused()
  if (offLoopback !== null) {
    rec(
      'not reachable on a non-loopback address',
      offLoopback,
      offLoopback ? `${otherIp}:${port} refused` : `ANSWERED on ${otherIp}:${port} — not loopback-only`,
    )
  }

  const bare = await fetch(`${base}/`, { redirect: 'manual' })
  rec('GET / without a token is refused', bare.status === 401, `status ${bare.status}`)

  const bareApi = await fetch(`${base}/api`, { redirect: 'manual' })
  rec('GET /api without a token is refused', bareApi.status === 401, `status ${bareApi.status}`)

  const wrong = await fetch(`${base}/?token=not-the-token`, { redirect: 'manual' })
  rec('a wrong launch token is refused', wrong.status === 401, `status ${wrong.status}`)

  const boot = await fetch(`${base}/?token=${encodeURIComponent(token)}`, { redirect: 'manual' })
  const cookies = boot.headers.getSetCookie()
  const session = cookies.find((c) => c.startsWith('dsh-auth-'))
  rec(
    'the launch token mints a session cookie',
    boot.status === 303 && Boolean(session),
    `status ${boot.status}, cookies: ${JSON.stringify(cookies.map((c) => c.split('=')[0]))}`,
  )
  if (session) {
    const jar = session.split(';')[0]
    const index = await fetch(`${base}/`, { headers: { cookie: jar }, redirect: 'manual' })
    const body = index.status === 200 ? await index.text() : ''
    rec(
      'the session cookie serves the UI',
      index.status === 200 && /<html/i.test(body),
      `status ${index.status}, ${body.length} bytes`,
    )
    const api = await fetch(`${base}/api`, { headers: { cookie: jar }, redirect: 'manual' })
    rec('the session cookie authenticates /api', api.status !== 401 && api.status !== 403, `status ${api.status}`)

    // The fence, not decoration: a cross-origin POST must be refused even with
    // a valid session, or a page in another app could drive this server.
    const cross = await fetch(`${base}/api`, {
      method: 'POST',
      headers: { cookie: jar, origin: 'http://evil.example' },
      redirect: 'manual',
    })
    rec('a cross-origin POST is refused despite a valid session', cross.status === 403, `status ${cross.status}`)
  }

  for (const r of results) {
    console.log(`${r.ok ? 'ok  ' : 'FAIL'} ${r.name} (${r.detail})`)
  }
  const failed = results.filter((r) => !r.ok).length
  console.log(`probe: ${results.length - failed}/${results.length} checks passed`)
  process.exit(failed === 0 ? 0 : 1)
}

main().catch((err) => {
  console.log(`FAIL probe threw: ${err && err.stack ? err.stack : err}`)
  process.exit(2)
})
EOS
}

# A non-loopback IPv4 address of this device, for the one test that can prove a
# loopback-only bind without reading kernel tables: connecting to an address the
# server should not be on. Any answer is fine; "no address" just skips the check.
nonloopback_ipv4() {
  if have getprop; then
    for p in dhcp.wlan0.ipaddress dhcp.eth0.ipaddress; do
      v=$(getprop "$p" 2>/dev/null)
      case "$v" in '' | '0.0.0.0' | *:*) : ;; *) printf '%s\n' "$v"; return 0 ;; esac
    done
  fi
  if have ip; then
    v=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi
  if have ifconfig; then
    v=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -n 1)
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi
  return 1
}

# Liveness by connecting, not by reading a table: /proc/net/tcp is present on a
# device and irrelevant off one, and this has to work in both places for the
# suite to be able to exercise the smoke test at all.
wait_for_port() {
  port=$1
  waited=0
  while [ "$waited" -lt 45 ]; do
    if in_rootfs "$DSH_NODE" -e "const s=require('net').connect({host:'127.0.0.1',port:$port},()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1));setTimeout(()=>process.exit(1),2000)" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# The listener's local address from the kernel's own table, when there is one:
# 0100007F is 127.0.0.1 and 00000000 is every interface. Empty when /proc is not
# mounted, in which case the connect-based check in the probe carries the test.
listening_local_address() {
  hexport=$(printf '%04X' "$1")
  in_rootfs /bin/sh -c "awk -v p=':$hexport' '\$4 == \"0A\" && index(\$2, p) { split(\$2, a, \":\"); print a[1] }' /proc/net/tcp 2>/dev/null" | head -n 1
}

step_smoke() {
  if [ "$SKIP_SMOKE" = 1 ]; then
    warn "--skip-smoke: the harness was NOT booted. Nothing here proves it starts on this device; 'dshd start' is the next thing that will try."
    return 0
  fi
  log "phase 2e: smoke test (boot on a scratch port and a scratch DSH_HOME)"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would boot $DSH_HARNESS_BIN web --no-open --port <free> and assert the auth contract"
    return 0
  fi

  ensure_mounts
  port=${SMOKE_PORT:-$(( ( $(date '+%s') % 20000 ) + 41000 ))}

  rm -rf "$DSH_ROOTFS$SMOKE_DIR"
  mkdir -p "$DSH_ROOTFS$SMOKE_DIR/state" "$DSH_ROOTFS$SMOKE_DIR/home"
  chmod 700 "$DSH_ROOTFS$SMOKE_DIR/state"
  write_probe
  smoke_log="$SMOKE_DIR/harness.log"

  # A scratch DSH_HOME, so this cannot read, write or mint anything belonging to
  # a real installation — a rehearsal does not touch credentials.
  chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root TMPDIR=/tmp LANG=C.UTF-8 \
    DSH_HOME="$SMOKE_DIR/state" \
    "$DSH_HARNESS_BIN" web --no-open --port "$port" >"$DSH_ROOTFS$smoke_log" 2>&1 &
  smoke_pid=$!

  addr=$(wait_for_port "$port") || {
    kill "$smoke_pid" 2>/dev/null
    rm -rf "$DSH_ROOTFS$SMOKE_DIR"
    die 6 "the harness did not listen on 127.0.0.1:$port within 45s. Log:
$(cat "$DSH_ROOTFS$smoke_log" 2>/dev/null | tail -n 20)"
  }

  # Two independent readings of the bind, because each can be unavailable:
  # /proc/net/tcp is authoritative but only exists on a device, and the
  # off-loopback probe is functional but only runs when we know another address.
  local_addr=$(listening_local_address "$port")
  other_ip=$(nonloopback_ipv4) || other_ip=""
  if [ -n "$local_addr" ]; then
    if [ "$local_addr" = "0100007F" ]; then
      log "the listening socket's local address is 0100007F (127.0.0.1)"
    else
      warn "the listener's local address is $local_addr, not 0100007F — this may not be loopback-only"
    fi
  else
    log "/proc/net/tcp is not readable here; relying on the off-loopback probe"
  fi
  [ -n "$other_ip" ] && log "will also check that $other_ip:$port is refused"

  # The launch token, extracted exactly the way dshd extracts it. If this regex
  # stops matching, dshd cannot start the guard, so it is part of the contract.
  token=$(sed -n 's|.*http://127\.0\.0\.1:[0-9][0-9]*/?token=\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*|\1|p' \
    "$DSH_ROOTFS$smoke_log" | tail -n 1)
  if [ -z "$token" ]; then
    kill "$smoke_pid" 2>/dev/null
    rm -rf "$DSH_ROOTFS$SMOKE_DIR"
    die 6 "the harness printed no 'http://127.0.0.1:<port>/?token=...' line. dshd extracts its guard token from exactly that line, so the guard cannot start. Log:
$(cat "$DSH_ROOTFS$smoke_log" 2>/dev/null | tail -n 20)"
  fi
  log "launch token found in the log (${#token} chars)"

  if ! out=$(in_rootfs "$DSH_NODE" "$SMOKE_DIR/probe.mjs" "$port" "$token" "$other_ip" 2>&1); then
    kill "$smoke_pid" 2>/dev/null
    rm -rf "$DSH_ROOTFS$SMOKE_DIR"
    die 6 "the auth contract does not hold on this install:
$out"
  fi
  printf '%s\n' "$out" | while IFS= read -r line; do log "  $line"; done

  # Stop it and prove the port came back, because a harness that will not exit is
  # a supervisor that cannot restart it.
  kill "$smoke_pid" 2>/dev/null
  waited=0
  while [ "$waited" -lt 15 ]; do
    kill -0 "$smoke_pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$smoke_pid" 2>/dev/null && { kill -9 "$smoke_pid" 2>/dev/null; warn "the smoke server ignored SIGTERM"; }
  rm -rf "$DSH_ROOTFS$SMOKE_DIR"

  # The one assertion that cannot be softened: if the server is reachable on an
  # interface that is not loopback, this is an RCE endpoint on the network and
  # nothing else in this phase matters.
  case "$out" in
    *"not reachable on a non-loopback address (ok"*) : ;;
    *"not reachable on a non-loopback address (FAIL"*)
      die 6 "the harness answered on $other_ip:$port — it is not bound to loopback only. Do not expose this (plan §7)." ;;
  esac
  if [ -n "$local_addr" ] && [ "$local_addr" != "0100007F" ]; then
    die 6 "the listening socket's local address is $local_addr, not 127.0.0.1 (0100007F)"
  fi
  log "Gate P2 (install half) PASSED: the harness boots, binds loopback, and enforces its auth contract"
}

summary() {
  log ""
  log "harness:    $VERSION at $DSH_ROOTFS$DSH_HARNESS_BIN"
  log "manifest:   $DSH_ROOTFS$MANIFEST"
  log "npm cache:  $DSH_ROOTFS$NPM_CACHE (safe to delete; re-installs reuse it)"
  log ""
  if [ "$SKIP_SMOKE" = 1 ]; then
    log "PARTIAL: the harness was installed but never booted here."
  fi
  log "next: sh $DSH_BASE/bin/dshd start   (then 'dshd url' for the tokenised URL)"
  log "then: Gate P2 proper — a prompt in, a real file write in the workspace,"
  log "      the result back, surviving a detach/reattach. That needs credentials"
  log "      configured through the UI's Models page (plan §5 Phase 2 step 4);"
  log "      docs/runbook.md records the procedure."
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) shift; VERSION=${1:-} ;;
      --force) FORCE=1 ;;
      --skip-smoke) SKIP_SMOKE=1 ;;
      --skip-libs) SKIP_LIBS=1 ;;
      --no-apt) USE_APT=0 ;;
      --smoke-port) shift; SMOKE_PORT=${1:-} ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) die 1 "unknown argument '$1' (try --help)" ;;
    esac
    shift
  done

  [ -n "$VERSION" ] || die 1 "--version needs a value"
  case "$SMOKE_PORT" in
    '') : ;;
    *[!0-9]*) die 1 "--smoke-port must be a number, got '$SMOKE_PORT'" ;;
  esac

  preflight
  check_libs
  step_install
  step_manifest
  step_verify
  step_smoke
  summary
}

main "$@"
