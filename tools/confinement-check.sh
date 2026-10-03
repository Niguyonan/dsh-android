#!/system/bin/sh
# confinement-check.sh — Phase 3 (plan §5): decide D3 from evidence, then write
# the verdict down where dshd and the app will both read it.
#
# The question is not "is there a Landlock in this kernel" — the plan is explicit
# that a kernel version is not a signal, and neither is a syscall number. The
# question is whether the process that will run the agent is *actually confined*,
# and the only honest answer comes from enforcing a ruleset and watching a
# forbidden write fail.
#
# That check is run here, through the harness's own launcher, using the
# launcher's own CLI — not a re-implementation of it:
#
#   @deepseek-ai/node-addon-system/lib/index.js   probe()   → --probe, exit 0,
#                                                 stdout full/partial
#   src/main.c                                    EXIT_LAUNCHER_FAILURE = 125
#                                                 every launcher error prints
#                                                 `landlock-run: ...` on stderr
#   src/main.c                                    `[--ro p]... [--rw p]... -- argv`
#
# So this script never guesses the binary's path or its flags: the path comes
# from the package's own launcherPath(), and a wrong path or a wrong flag shows
# up as a launcher failure rather than as a pass.
#
# Two controls, and both must land, or the verdict is `unproven`:
#
#   positive   --rw /tmp            writing inside the granted root SUCCEEDS
#   negative   --ro /               writing outside it FAILS
#
# A one-sided test cannot tell "the kernel denied it" from "the launcher never
# ran", and that difference is the whole verdict: a launcher that rejects its own
# argv denies every write too. `unproven` is therefore a real outcome here, and
# it is reported as one instead of being rounded up to a pass.
#
# The verdict goes to $DSH_STATE/posture.conf, which dshd reads for both the
# permission mode and the one-line status the app shows:
#
#   probe=full|partial|unusable     the launcher's own functional probe
#   deny=proven|unproven            the two controls above
#   permission_mode=...             what dshd will pin (plan §5 Phase 3 / D3)
#   confinement=...                 the sentence the app puts in front of a human
#
# usage: confinement-check.sh [--save FILE] [--probe-only] [--mode MODE]
#
#   --save FILE    where to write the posture (default $DSH_STATE/posture.conf)
#   --probe-only   report; write nothing, so a dry look cannot pin a mode
#   --mode MODE    pin this permission mode instead of the derived one
#
# env: DSH_BASE, DSH_ROOTFS, DSH_STATE, CONFINEMENT_LAUNCHER (override the
#      launcher path — for tests, and for an install that moved it)
#
# exit: 0 the control was proven in force · 1 usage or config error · 2 not root
#       3 prerequisite failed (no rootfs, no launcher) · 5 not enforced
#
# POSIX sh: this runs under Magisk's mksh on the device and under /bin/sh in
# tests/confinement.test.sh. `sh -n tools/confinement-check.sh` checks it.

set -u

: "${DSH_BASE:=/data/local/dsh}"
: "${DSH_ROOTFS:=$DSH_BASE/rootfs}"
: "${DSH_STATE:=$DSH_BASE/state}"
: "${CONFINEMENT_LAUNCHER:=}"

ROOTFS_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NODE_MODULES="/usr/local/lib/node_modules"
DSH_PACKAGE="$NODE_MODULES/@deepseek-ai/dsh"

SAVE=""
PROBE_ONLY=0
MODE_OVERRIDE=""

# --- output -----------------------------------------------------------------

say() { printf '%s\n' "$*"; }
pass() { say "[PASS] $*"; }
fail() { say "[FAIL] $*"; }
warn() { say "[WARN] $*"; }
skip() { say "[SKIP] $*"; }
info() { say "[INFO] $*"; }

die() {
  rc=$1
  shift
  printf 'confinement-check: %s\n' "$*" >&2
  exit "$rc"
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,55p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

# --- the launcher -----------------------------------------------------------

# Ask the package itself where its binary is: the resolution rule (which
# platform package, which bin/ name) belongs to upstream and is version-pinned,
# and a second copy of it here would be a second thing to get wrong. node is
# already in the rootfs, and this is the same resolution the harness will do
# when it confines the agent.
#
# Resolution is pinned to the harness's own directory rather than to the cwd: a
# relative search here would make "which binary confines the agent" depend on
# where this script happened to be run from.
resolve_launcher_with_node() {
  [ -d "$DSH_ROOTFS$DSH_PACKAGE" ] || return 1
  script="const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');
const req = createRequire('$DSH_PACKAGE/package.json');
const entry = req.resolve('@deepseek-ai/node-addon-system/landlock-run');
import(pathToFileURL(entry).href).then(m => { process.stdout.write(m.launcherPath()) }).catch(() => process.exit(1));"
  out=$(chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root LANG=C.UTF-8 \
    /usr/local/bin/node -e "$script" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# The fallback if node cannot answer: the published layout. Only reaches a
# verdict if the file is really there — this is a hint, never a substitute.
find_launcher() {
  [ -d "$DSH_ROOTFS$NODE_MODULES" ] || return 1
  find "$DSH_ROOTFS$NODE_MODULES" -maxdepth 4 -type f -name landlock-run 2>/dev/null | head -n 1
}

launcher_path() {
  if [ -n "$CONFINEMENT_LAUNCHER" ]; then
    printf '%s\n' "$CONFINEMENT_LAUNCHER"
    return 0
  fi
  p=$(resolve_launcher_with_node) || p=$(find_launcher) || return 1
  [ -n "$p" ] || return 1
  printf '%s\n' "$p"
}

# Is the path an in-rootfs path (what the launcher needs as argv) or a host path?
in_rootfs_path() {
  case "$1" in
    "$DSH_ROOTFS"/*) printf '%s\n' "${1#"$DSH_ROOTFS"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Run argv inside the rootfs, capturing stdout and stderr separately, and leave
# the status in $RUN_STATUS plus the streams in $RUN_OUT / $RUN_ERR.
RUN_STATUS=1
RUN_OUT=""
RUN_ERR=""
run_in_rootfs() {
  out_file="$DSH_STATE/.confinement.out.$$"
  err_file="$DSH_STATE/.confinement.err.$$"
  mkdir -p "$DSH_STATE" 2>/dev/null
  chroot "$DSH_ROOTFS" /usr/bin/env -i \
    PATH="$ROOTFS_PATH" HOME=/root TMPDIR=/tmp LANG=C.UTF-8 "$@" \
    >"$out_file" 2>"$err_file"
  RUN_STATUS=$?
  RUN_OUT=$(cat "$out_file" 2>/dev/null)
  RUN_ERR=$(cat "$err_file" 2>/dev/null)
  rm -f "$out_file" "$err_file"
  return 0
}

# 125 alone is not enough to blame the launcher: the wrapped command may use it
# too. The contract requires a matching diagnostic as well (lib/index.js says so
# in as many words).
launcher_failed() {
  [ "$RUN_STATUS" = 125 ] || return 1
  case "$RUN_ERR" in
    *landlock-run:*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the checks -------------------------------------------------------------

PROBE_VERDICT=unusable
PROBE_DETAIL=""
DENY_VERDICT=unproven
DENY_DETAIL=""
LAUNCHER=""
LAUNCHER_IN=""

probe_launcher() {
  info "launcher: $LAUNCHER_IN"
  if [ ! -f "$LAUNCHER" ]; then
    PROBE_DETAIL="the launcher binary is not there ($LAUNCHER)"
    fail "$PROBE_DETAIL — the harness resolves this same path, so its workspace-write mode has nothing to confine with"
    return 0
  fi
  run_in_rootfs "$LAUNCHER_IN" --probe
  if [ "$RUN_STATUS" = 0 ]; then
    case "$RUN_OUT" in
      *"partially enforced"*)
        PROBE_VERDICT=partial
        pass "landlock-run --probe: partially enforced (older ABI)"
        ;;
      *"fully enforced"*)
        PROBE_VERDICT=full
        pass "landlock-run --probe: fully enforced"
        ;;
      *)
        PROBE_VERDICT=unusable
        PROBE_DETAIL="the probe exited 0 without its report line: '$RUN_OUT'"
        fail "$PROBE_DETAIL — the launcher CLI contract moved (§5 Phase 3). Fix this before trusting any verdict about confinement."
        ;;
    esac
    return 0
  fi
  PROBE_VERDICT=unusable
  if launcher_failed; then
    PROBE_DETAIL="the kernel refused enforcement: $RUN_ERR"
    fail "landlock-run --probe exited 125: $RUN_ERR"
    info "this is the documented fallback path: D3 pins danger-full-access and the disclosure that goes with it"
  else
    PROBE_DETAIL="probe exit $RUN_STATUS with no launcher diagnostic ($RUN_ERR)"
    fail "landlock-run --probe exited $RUN_STATUS and did not identify itself — refusing to read that as an answer either way"
  fi
  return 0
}

# The two controls. Both matter: see the header.
deny_check() {
  [ "$PROBE_VERDICT" = unusable ] && {
    skip "the deny test needs a launcher that runs at all"
    return 0
  }
  probe_allowed="/tmp/.confinement-allow.$$"
  probe_denied="/etc/.confinement-deny.$$"

  run_in_rootfs "$LAUNCHER_IN" --ro / --rw /tmp -- /bin/sh -c \
    "printf x > $probe_allowed && rm -f $probe_allowed && exit 0; exit 1"
  if [ "$RUN_STATUS" != 0 ]; then
    DENY_DETAIL="the positive control failed (exit $RUN_STATUS): writing to a granted root was refused, so this run proves nothing about enforcement"
    if launcher_failed; then
      DENY_DETAIL="the launcher rejected its own argv, not the write: $RUN_ERR"
    fi
    fail "$DENY_DETAIL"
    return 0
  fi
  pass "positive control: a write inside the granted root succeeded"

  run_in_rootfs "$LAUNCHER_IN" --ro / --rw /tmp -- /bin/sh -c \
    "printf x > $probe_denied 2>/dev/null && rm -f $probe_denied && exit 0; exit 1"
  if [ "$RUN_STATUS" = 0 ]; then
    DENY_DETAIL="the negative control succeeded: a write to /etc was allowed while only /tmp was granted, so the ruleset is not covering what it claims to"
    fail "$DENY_DETAIL"
  elif launcher_failed; then
    DENY_DETAIL="the launcher rejected its own argv on the negative control too: $RUN_ERR"
    fail "$DENY_DETAIL"
  else
    DENY_VERDICT=proven
    pass "negative control: the same write outside the granted root was denied (exit $RUN_STATUS)"
  fi
  # A denied write leaves nothing behind; a permitted one just did.
  [ -f "$DSH_ROOTFS$probe_denied" ] && {
    warn "$probe_denied exists — removing it"
    rm -f "$DSH_ROOTFS$probe_denied"
  }
  return 0
}

# --- the verdict ------------------------------------------------------------

decide_mode() {
  if [ -n "$MODE_OVERRIDE" ]; then
    printf '%s\n' "$MODE_OVERRIDE"
    return 0
  fi
  case "$PROBE_VERDICT" in
    full | partial) printf '%s\n' workspace-write ;;
    *) printf '%s\n' danger-full-access ;;
  esac
}

confinement_sentence() {
  case "$PROBE_VERDICT" in
    full | partial)
      if [ "$DENY_VERDICT" = proven ]; then
        printf 'landlock-%s, a denied write was observed' "$PROBE_VERDICT"
      else
        printf 'landlock-%s, but no denied write was observed — available, not proven' "$PROBE_VERDICT"
      fi
      ;;
    *)
      printf 'no landlock: the agent is NOT confined to the workspace'
      ;;
  esac
}

write_posture() {
  file=$1
  dir=$(dirname "$file")
  (umask 077; mkdir -p "$dir") || die 3 "cannot create $dir"
  {
    printf '# written by tools/confinement-check.sh on %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '# read by dshd (permission_mode=) and shown by the app (confinement=).\n'
    printf '# A control that is assumed rather than tested is not a control: the\n'
    printf '# "deny" line below is the only claim here that was observed.\n'
    printf 'confinement=%s\n' "$(confinement_sentence)"
    printf 'permission_mode=%s\n' "$(decide_mode)"
    printf 'probe=%s\n' "$PROBE_VERDICT"
    printf 'deny=%s\n' "$DENY_VERDICT"
    printf 'launcher=%s\n' "$LAUNCHER_IN"
    [ -n "$PROBE_DETAIL" ] && printf 'probe_detail=%s\n' "$PROBE_DETAIL"
    [ -n "$DENY_DETAIL" ] && printf 'deny_detail=%s\n' "$DENY_DETAIL"
  } >"$file" || die 3 "cannot write $file"
}

# --- main -------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --save)
      shift
      SAVE=${1:-}
      ;;
    --probe-only) PROBE_ONLY=1 ;;
    --mode)
      shift
      MODE_OVERRIDE=${1:-}
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die 1 "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

[ -n "$SAVE" ] || SAVE="$DSH_STATE/posture.conf"

if [ "$(id -u 2>/dev/null)" != 0 ]; then
  die 2 "must run as root: the probe chroots into $DSH_ROOTFS and the posture is 0600 root"
fi

[ -x "$DSH_ROOTFS/bin/sh" ] || die 3 "no usable rootfs at $DSH_ROOTFS — run tools/rootfs-setup.sh first"

say "== Phase 3: is the agent confined? =="
info "rootfs: $DSH_ROOTFS"

LAUNCHER=$(launcher_path) || LAUNCHER=""
if [ -z "$LAUNCHER" ]; then
  PROBE_VERDICT=unusable
  PROBE_DETAIL="no launcher could be resolved inside the rootfs (neither the package's launcherPath() nor a landlock-run under $NODE_MODULES)"
  fail "$PROBE_DETAIL"
  info "the harness is installed without its platform package, or installed somewhere this script does not know about"
  LAUNCHER_IN="(unresolved)"
else
  LAUNCHER_IN=$(in_rootfs_path "$LAUNCHER")
  probe_launcher
  deny_check
fi

say ""
if [ "$DENY_VERDICT" = proven ]; then
  pass "confinement: $(confinement_sentence)"
else
  warn "confinement: $(confinement_sentence)"
fi
info "permission mode that follows: $(decide_mode)"

rc=5
[ "$DENY_VERDICT" = proven ] && rc=0

if [ "$PROBE_ONLY" = 1 ]; then
  info "--probe-only: nothing written, no mode pinned"
  exit "$rc"
fi

write_posture "$SAVE"
info "posture written to $SAVE"
if [ "$rc" != 0 ]; then
  say ""
  warn "this is not fatal, and it is not quiet either: dshd will pin $(decide_mode), and the app puts this sentence in front of you:"
  warn "  $(confinement_sentence)"
fi
exit "$rc"
