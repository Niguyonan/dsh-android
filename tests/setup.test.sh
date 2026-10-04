#!/bin/sh
# Host-side tests for `dshd setup` — the one command the APK runs.
#
# The app has no terminal to fall back on, so this verb has to do four things
# that a person at a shell would otherwise do by hand, and each of them is
# checked here:
#
#   * run the phases in order, and stop at the first one that fails
#   * say what happened on stdout in a protocol the app can render, including
#     which step failed and why — because "exit 5" is not a diagnosis
#   * distinguish what it *did* from what was already done (`skip`, not `ok`)
#   * refuse the inputs that would install a control against the wrong UID, and
#     carry on past the failures the plan says are survivable, out loud
#
# The tools are stubs that record how they were called and exit with a code the
# case chooses, and dshd runs with DSHD_DRY_RUN=1 so that its own mutations —
# mounts, the supervisor, the token — are logged rather than performed. The stub
# tools still run for real: the orchestration is the thing under test.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
DSHD="$REPO/bin/dshd"

[ -f "$DSHD" ] || { echo "bin/dshd not found at $DSHD" >&2; exit 1; }

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
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 10)" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "did not expect [$2] in: $(printf '%s' "$3" | tail -n 10)" ;;
    *) pass "$1" ;;
  esac
}

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# --- environment ------------------------------------------------------------

# A base that looks like an installed payload: dshd itself, stub tools that
# record their argv, and a rootfs skeleton with a shell and node in it.
make_base() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-test.XXXXXX") || exit 1
  BASE="$TMP/dsh"
  mkdir -p "$BASE/bin" "$BASE/tools" "$BASE/state" "$BASE/log" "$BASE/etc" "$BASE/run" \
    "$BASE/rootfs/bin" "$BASE/rootfs/usr/local/bin" "$TMP/bin"
  # Root, stubbed, for the cases that must not run under DSHD_DRY_RUN. The
  # not-root case overwrites this one with its own.
  printf '#!/bin/sh\necho 0\n' >"$TMP/bin/id"
  chmod 755 "$TMP/bin/id"
  cp "$DSHD" "$BASE/bin/dshd"
  printf '#!/bin/sh\nexit 0\n' >"$BASE/rootfs/bin/sh"
  printf '#!/bin/sh\nexit 0\n' >"$BASE/rootfs/usr/local/bin/node"
  printf '#!/bin/sh\nexit 0\n' >"$BASE/rootfs/usr/local/bin/dsh"
  mkdir -p "$BASE/boot/service.d"
  printf '#!/system/bin/sh\nexit 0\n' >"$BASE/boot/service.d/dshd.sh"
  chmod 755 "$BASE/rootfs/bin/sh" "$BASE/rootfs/usr/local/bin/node" \
    "$BASE/rootfs/usr/local/bin/dsh" "$BASE/boot/service.d/dshd.sh"
  stub_tool probe.sh 0
  stub_tool rootfs-setup.sh 0
  stub_tool install-harness.sh 0
  stub_tool firewall.sh 0
  printf 'guard-token-for-tests\n' >"$BASE/state/guard.token"
  # The real tool writes the posture; a stub that did not would leave every
  # later step reading a verdict nobody produced.
  stub_confinement 0
}

# A tool that records `name argv...` and exits with $2.
stub_tool() {
  name=$1
  rc=${2:-0}
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >>"$DSH_BASE/log/calls"\n' "$name"
    printf 'echo "[stub %s] %s"\n' "$name" "$*"
    printf 'exit %s\n' "$rc"
  } >"$BASE/tools/$name"
  chmod 755 "$BASE/tools/$name"
}

# The confinement stub has to write the posture file, because everything after it
# reads what it wrote.
stub_confinement() {
  rc=$1
  mode=${2:-workspace-write}
  verdict=${3:-landlock-full, a denied write was observed}
  cat >"$BASE/tools/confinement-check.sh" <<EOF
#!/bin/sh
printf "%s %s\\n" "confinement-check.sh" "\$*" >>"\$DSH_BASE/log/calls"
save=""
while [ \$# -gt 0 ]; do
  case "\$1" in --save) shift; save=\${1:-} ;; esac
  shift
done
[ -n "\$save" ] || save="\$DSH_STATE/posture.conf"
( umask 077; printf 'confinement=%s\npermission_mode=%s\nprobe=full\ndeny=proven\n' "$verdict" "$mode" >"\$save" )
exit $rc
EOF
  chmod 755 "$BASE/tools/confinement-check.sh"
}

calls() { cat "$BASE/log/calls" 2>/dev/null; }
clear_calls() { : >"$BASE/log/calls"; }

# The whole run, through the real dshd, with the device's mutations logged.
run_setup() {
  DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup "$@" 2>&1
}

run_setup_rc() {
  DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup "$@" >/dev/null 2>&1
  echo $?
}

# The step names, in order, without their messages.
step_names() {
  printf '%s\n' "$1" | sed -n 's/^##dshd [^ ]* step \([a-z_-]*\) .*/\1/p' | tr '\n' ' '
}

# awk rather than sed: macOS sed has no alternation in basic regexes, and a
# helper that quietly matches nothing would have made every state assertion in
# this file vacuous on the machine it was written on.
step_states() {
  printf '%s\n' "$1" | awk '$1 == "##dshd" && ($3 == "ok" || $3 == "skip" || $3 == "fail") { print $3, $4 }' | tr '\n' ' '
}

# --- argument handling ------------------------------------------------------

printf '\n== setup arguments ==\n'

make_base
out=$(run_setup)
rc=$?
check "no --app-uid is a usage error" "1" "$rc"
contains "and says why" "--app-uid" "$out"
check "--app-uid must be numeric" "1" "$(run_setup_rc --app-uid 10x23)"
check "--app-uid cannot be empty" "1" "$(run_setup_rc --app-uid '')"
check "--app-uid cannot be negative" "1" "$(run_setup_rc --app-uid -1)"
check "an unknown argument is a usage error" "1" "$(run_setup_rc --app-uid 10123 --bogus)"
check "--boot takes install, remove or skip" "1" "$(run_setup_rc --app-uid 10123 --boot later)"
check "a non-numeric port is refused" "1" \
  "$(DSH_BASE="$BASE" DSHD_DRY_RUN=1 DSH_GUARD_PORT=tcp sh "$BASE/bin/dshd" setup --app-uid 10123 >/dev/null 2>&1; echo $?)"

# --- the happy path ---------------------------------------------------------

printf '\n== the whole sequence ==\n'

make_base
clear_calls
out=$(run_setup --app-uid 10123)
rc=$?
check "setup exits 0" "0" "$rc"
check "the steps run in order" \
  "probe rootfs harness confinement firewall config start " "$(step_names "$out")"
# The fake rootfs in make_base is already a base, so that step skips — which is
# what a second run on a real device does, and what the next section is about.
check "every step reports a state" \
  "ok probe skip rootfs ok harness ok confinement ok firewall ok config ok start " \
  "$(step_states "$out")"
contains "the begin event comes before the first step" "begin" "$(printf '%s' "$out" | grep -m1 '##dshd ')"
contains "the begin event carries the uid" "begin app_uid=10123" "$out"
contains "the run ends with done ok" "done ok" "$out"
lacks "and never with done fail" "done fail" "$out"
check "there is exactly one done event" "1" "$(printf '%s\n' "$out" | grep -c ' done ')"
contains "the url is handed back to the app" "url http://127.0.0.1:3081/?token=guard-token-for-tests" "$out"
# And the state block a check reports, as the setup's last act. Without it the
# app had nothing to read when a setup *finished*: it drew "Not set up", with SET
# UP where START belongs and no STOP button, over a harness that was installed,
# running, and on screen in the WebView. Only a resume fixed it, because a resume
# runs a check — so the wrong screen is what you see if you look at the app
# instead of leaving it and coming back.
contains "a finished setup reports the install" "info installed yes" "$out"
contains "and the harness" "info harness yes" "$out"
contains "and the payload id" "info payload" "$out"
contains "and the posture" "info posture landlock-full" "$out"
# The property that matters is not a list of lines but that the two verbs agree:
# whatever a check would tell the app, a finished setup has already told it.
check "a finished setup reports the same state a check reports" \
  "$(DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup --check 2>&1 |
    awk '$1 == "##dshd" && $3 == "info" { print $4, $5 }' | sort | tr '\n' ' ')" \
  "$(printf '%s\n' "$out" | awk '$1 == "##dshd" && $3 == "info" { print $4, $5 }' | sort | tr '\n' ' ')"
contains "the state block comes before done" "yes" \
  "$(printf '%s\n' "$out" | awk '/^##dshd .* info installed yes/{i=NR} /^##dshd .* done /{d=NR} END{print (i && d && i < d) ? "yes" : "no"}')"

# rootfs-setup.sh is absent because its step skipped: not running a tool that
# has nothing to do is the point of the skip.
check "each tool that had work ran once, in order" \
  "probe.sh install-harness.sh confinement-check.sh firewall.sh" \
  "$(calls | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"

contains "the firewall step gets the uid" "firewall.sh apply --uid 10123" "$(calls)"
contains "the confinement check is asked to save a posture" \
  "confinement-check.sh --save" "$(calls)"

# --- what the app reads back ------------------------------------------------

printf '\n== the config setup leaves behind ==\n'

# Written for real, so this run is not a dry run: root is stubbed, the chroot is
# skipped, and the supervisor is pointed at a path that does not exist, which is
# the one way to reach the config step on a host without spawning anything. The
# start step then fails on readiness — which is itself worth asserting, because
# "the server never came up" is the failure a phone will actually hit.
make_base
clear_calls
out=$(PATH="$TMP/bin:$PATH" DSH_BASE="$BASE" DSHD_NO_CHROOT=1 DSHD_SELF="$TMP/no-supervisor" \
  DSH_START_TIMEOUT=2 sh "$BASE/bin/dshd" setup --app-uid 10123 2>&1)
rc=$?
check "a start that never becomes ready exits 5" "5" "$rc"
contains "and the failing step is named" "fail start exit 4" "$out"
contains "and the run is closed out" "done fail" "$out"

check "etc/dshd.conf exists" "yes" "$([ -f "$BASE/etc/dshd.conf" ] && echo yes || echo no)"
conf=$(cat "$BASE/etc/dshd.conf")
contains "it is marked as setup's" "# managed by dshd setup" "$conf"
contains "it pins the uid" "DSH_APP_UID=10123" "$conf"
contains "it leaves the firewall on" "DSH_FIREWALL=on" "$conf"
contains "it records the ports" "DSH_GUARD_PORT=3081" "$conf"
contains "autostart is off unless asked for" "autostart=off" "$conf"
# GNU stat first: on Linux `stat -f` means "filesystem", succeeds, and prints
# its format string, so the BSD spelling has to come second or this reads
# nonsense and never falls back.
conf_mode=$(stat -c '%a' "$BASE/etc/dshd.conf" 2>/dev/null || stat -f '%Lp' "$BASE/etc/dshd.conf")
check "it is not world readable" "600" "$conf_mode"

out=$(DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup --check)
contains "check reports the install" "info installed yes" "$out"
contains "check reports the payload id" "info payload" "$out"
contains "check reports the posture" "info posture landlock-full" "$out"
contains "check reports the app uid from the config" "info app_uid 10123" "$out"
lacks "check does not invent a url when nothing is running" "url http" "$out"

# A config a person edited is not clobbered.
make_base
printf 'DSH_BASE=%s\nDSH_HARNESS_PORT=9999\n' "$BASE" >"$BASE/etc/dshd.conf"
out=$(run_setup --app-uid 10123)
contains "a hand-written config is left alone" "was not written by setup" "$out"
check "and is not overwritten" "DSH_HARNESS_PORT=9999" "$(sed -n '2p' "$BASE/etc/dshd.conf")"

# --- skips, not repeats -----------------------------------------------------

printf '\n== already done ==\n'

make_base
clear_calls
run_setup --app-uid 10123 >/dev/null 2>&1
clear_calls
out=$(run_setup --app-uid 10123)
contains "a second run skips the rootfs" "skip rootfs" "$out"
contains "and skips the posture" "skip confinement" "$out"
contains "the skip says what it found" "already installed" "$out"
lacks "the rootfs tool is not run again" "rootfs-setup.sh" "$(calls)"
out=$(run_setup --app-uid 10123 --recheck)
contains "--recheck runs the posture check again" "ok confinement" "$out"

# --- failure propagation ----------------------------------------------------

printf '\n== a step that fails ==\n'

for spec in "probe.sh 1 probe" "install-harness.sh 4 harness" "firewall.sh 3 firewall"; do
  set -- $spec
  tool=$1
  code=$2
  step=$3
  make_base
  stub_tool "$tool" "$code"
  out=$(run_setup --app-uid 10123)
  rc=$?
  check "$step failing exits 5" "5" "$rc"
  contains "$step is named as the failure" "fail $step exit $code" "$out"
  contains "$step failing ends the run" "done fail" "$out"
  lacks "and nothing after it runs" "start " "$(step_names "$out")"
  check "the steps before it did run" "yes" \
    "$(printf '%s' "$(step_names "$out")" | grep -q "$step" && echo yes || echo no)"
done

# --- the two survivable failures --------------------------------------------

printf '\n== a firewall that cannot be enforced ==\n'

make_base
stub_tool firewall.sh 5
out=$(run_setup --app-uid 10123)
rc=$?
check "an unenforced firewall stops setup" "5" "$rc"
contains "and says what stays exposed" "other apps can reach the guard port" "$out"
contains "and offers the way past it" "--allow-unenforced-firewall" "$out"

make_base
stub_tool firewall.sh 5
out=$(run_setup --app-uid 10123 --allow-unenforced-firewall)
rc=$?
check "with the flag, setup finishes" "0" "$rc"
contains "and still says what is exposed" "NOT enforced" "$out"
contains "and completes" "done ok" "$out"

printf '\n== a sandbox that cannot be proven ==\n'

make_base
stub_confinement 5 danger-full-access "no landlock: the agent is NOT confined to the workspace"
out=$(run_setup --app-uid 10123)
rc=$?
check "an unproven sandbox does not stop setup" "0" "$rc"
contains "but it is said out loud" "NOT proven" "$out"
contains "and the run completes" "done ok" "$out"
out=$(DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup --check)
contains "and the posture carries the fallback" "info posture no landlock" "$out"
check "the pinned mode is the fallback" "danger-full-access" \
  "$(sed -n 's/^permission_mode=//p' "$BASE/state/posture.conf")"

# --- a missing tool is not a silent skip ------------------------------------

printf '\n== a payload that is missing a tool ==\n'

make_base
rm -f "$BASE/tools/firewall.sh"
out=$(run_setup --app-uid 10123)
rc=$?
check "a missing tool fails the step" "5" "$rc"
contains "and says which one" "tools/firewall.sh is missing" "$out"
contains "and names the step" "fail firewall exit 3" "$out"

# --- not root ---------------------------------------------------------------

printf '\n== not root ==\n'

make_base
printf '#!/bin/sh\necho 2000\n' >"$TMP/bin/id"
chmod 755 "$TMP/bin/id"
out=$(PATH="$TMP/bin:$PATH" DSH_BASE="$BASE" sh "$BASE/bin/dshd" setup --app-uid 10123 2>&1)
rc=$?
check "a non-root setup exits 2" "2" "$rc"
contains "and says so" "must run as root" "$out"
check "and no tool ran" "" "$(calls)"

# --- boot autostart ---------------------------------------------------------

printf '\n== boot autostart ==\n'

make_base
mkdir -p "$TMP/service.d"
out=$(DSH_BASE="$BASE" DSH_BOOT_SERVICE_DIR="$TMP/service.d" DSHD_DRY_RUN=1 \
  sh "$BASE/bin/dshd" setup --app-uid 10123 2>&1)
lacks "no boot step unless asked for" "step boot" "$out"

make_base
mkdir -p "$TMP/service.d2"
out=$(DSH_BASE="$BASE" DSH_BOOT_SERVICE_DIR="$TMP/service.d2" DSHD_DRY_RUN=1 \
  sh "$BASE/bin/dshd" setup --app-uid 10123 --boot install 2>&1)
contains "the boot step runs when asked" "step boot" "$out"
contains "and the run completes" "done ok" "$out"

# For real this time: `boot` writes files and flips the config key, so it is not
# a dry run. The copy has to be the one dshd installs or `boot remove` refuses to
# touch it, which is the next thing asserted.
boot_rc() {
  PATH="$TMP/bin:$PATH" DSH_BASE="$BASE" DSH_BOOT_SERVICE_DIR="$1" sh "$BASE/bin/dshd" boot "$2" \
    >/dev/null 2>&1
  echo $?
}
make_base
check "a service directory that does not exist is refused" "3" "$(boot_rc "$TMP/no-such-dir" install)"
mkdir -p "$TMP/service.d3"
check "boot install exits 0" "0" "$(boot_rc "$TMP/service.d3" install)"
check "and copies the script" "yes" \
  "$([ -f "$TMP/service.d3/dshd.sh" ] && echo yes || echo no)"
check "and makes it executable" "yes" \
  "$([ -x "$TMP/service.d3/dshd.sh" ] && echo yes || echo no)"
out=$(PATH="$TMP/bin:$PATH" DSH_BASE="$BASE" DSH_BOOT_SERVICE_DIR="$TMP/service.d3" sh "$BASE/bin/dshd" boot status)
contains "boot status reports it" "installed" "$out"
contains "and reports autostart on" "autostart     on" "$out"
contains "and the config agrees" "autostart=on" "$(cat "$BASE/etc/dshd.conf")"

# A script that is not ours is left alone: deleting someone else's boot script
# would be a surprising thing for a toggle to do.
printf '#!/system/bin/sh\n# not ours\n' >"$TMP/service.d3/dshd.sh"
check "boot remove still exits 0" "0" "$(boot_rc "$TMP/service.d3" remove)"
check "but leaves a foreign script in place" "yes" \
  "$([ -f "$TMP/service.d3/dshd.sh" ] && echo yes || echo no)"
contains "and turns autostart off anyway" "autostart=off" "$(cat "$BASE/etc/dshd.conf")"

check "boot remove takes our copy away" "0" "$(boot_rc "$TMP/service.d3" install)"
check "boot remove exits 0" "0" "$(boot_rc "$TMP/service.d3" remove)"
check "and the file is gone" "no" \
  "$([ -f "$TMP/service.d3/dshd.sh" ] && echo yes || echo no)"

# --- the url contract -------------------------------------------------------

printf '\n== the url the app opens ==\n'

make_base
rm -f "$BASE/state/guard.token"
out=$(run_setup --app-uid 10123)
contains "no token yet is a note, not a failure" "could not be read back" "$out"
contains "and the run still succeeds" "done ok" "$out"
check "and exits 0" "0" "$(run_setup_rc --app-uid 10123)"

printf '\n%d checks, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
