#!/system/bin/sh
# dshd.sh — boot-time autostart for dshd, from a root solution's late_start
# service stage.
#
# Install it executable at /data/adb/service.d/dshd.sh:
#
#   Magisk          /data/adb/service.d is a general script directory, and the
#                   same path works inside a module's own service.d.
#   KernelSU        general scripts live in /data/adb/post-fs-data.d,
#                   /data/adb/service.d, /data/adb/post-mount.d and
#                   /data/adb/boot-completed.d, and *only run if executable*.
#   KernelSU-Next   same paths; it is a KernelSU fork and shares /data/adb/ksu
#                   and /data/adb/ksud.
#
# Both managers run these scripts in BusyBox ash, and KernelSU enables BusyBox's
# "Standalone Shell Mode" (ASH_STANDALONE=1) so applets come from BusyBox
# regardless of PATH. KernelSU also sets KSU=true. That means: POSIX sh only,
# no bashisms, and do not rely on PATH for core utilities.
#
# Autostart is opt-in, because D5 has the APK own the runtime's lifetime: boot
# start is for people who want the harness up before they unlock the phone, and
# it costs a root process for the whole boot. Enable it with
#
#   autostart=on
#
# in /data/local/dsh/etc/dshd.conf.
#
# File-based encryption is the reason this waits rather than racing: dshd's own
# paths (/data/local/dsh, /data/adb) are device-encrypted and available early,
# but if DSH_HOME or the workspace were pointed inside credential-encrypted
# storage, starting before the first unlock would half-work, which is worse than
# starting late.

set -u

have() { command -v "$1" >/dev/null 2>&1; }

DSH_BASE=${DSH_BASE:-/data/local/dsh}
CONF="$DSH_BASE/etc/dshd.conf"
LOG="$DSH_BASE/log/autostart.log"
DSHD="$DSH_BASE/bin/dshd"

# KernelSU sets KSU=true in the scripts it runs; Magisk does not set it. Only
# used for logging — nothing here branches on it.
manager="root solution"
[ "${KSU:-false}" = "true" ] && manager="KernelSU"

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s dshd-autostart[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$manager" "$*" >>"$LOG" 2>/dev/null
}

# Read one key from dshd.conf without sourcing it: this script must not change
# dshd's environment, and a sourced config with a syntax error would take the
# boot script down with it.
conf_get() {
  [ -f "$CONF" ] || return 1
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null | tail -n 1
}

if [ ! -x "$DSHD" ]; then
  # Not installed, or installed somewhere else. Nothing to do, and nothing to
  # report: a missing install is not an error at boot.
  exit 0
fi

if [ "$(conf_get autostart)" != "on" ]; then
  exit 0
fi

if [ "$(id -u 2>/dev/null)" != 0 ]; then
  log "not root (uid $(id -u 2>/dev/null)) — skipping"
  exit 0
fi

# Wait, bounded, for the boot to settle. The harness serves a browser UI and
# needs the network stack up; starting it into a half-initialised system is how
# you get a supervisor that restarts its children forever. The wait is
# configurable because "wait for boot_completed" is the wrong trade on a device
# where late_start already means the network is up, and because a host without
# getprop must not sit here for two minutes.
wait_budget=${DSH_AUTOSTART_WAIT:-60}
waited=0
if have getprop; then
  while [ "$waited" -lt "$wait_budget" ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
    log "sys.boot_completed never arrived in ${waited}s (budget ${wait_budget}s) — starting anyway"
  fi
else
  log "getprop is not available; not waiting for boot_completed"
fi

log "starting dshd (base=$DSH_BASE)"
out=$(sh "$DSHD" start 2>&1)
rc=$?
if [ -n "$out" ]; then
  printf '%s\n' "$out" | while IFS= read -r line; do
    [ -n "$line" ] && log "  $line"
  done
fi
log "dshd start exited $rc"
exit 0
