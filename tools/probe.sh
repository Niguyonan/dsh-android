#!/system/bin/sh
# probe.sh — Phase 0 device feasibility probes (plan §5 Phase 0, gate P0).
#
# Everything downstream branches on the answers this prints, so it is written to
# produce *verdicts*, not just output: three probes decide whether the approach
# survives at all (executable storage, mountable SELinux context, chroot), three
# decide the documented fallbacks (Landlock → D3, PTY → D6, xt_owner → §7), and
# one records which root solution granted the shell, because Magisk, KernelSU and
# KernelSU-Next differ in exactly the places that matter here: the su binary, the
# SELinux domain su runs in, the mount namespace a new session gets, and where
# boot scripts live.
#
# It is non-destructive. The two probes that must try something real — the owner
# match and the mount-namespace question — use a scratch netfilter chain and a
# scratch tmpfs, both removed before the script exits, including on failure.
#
# usage: probe.sh [--save FILE]
# exit:  0 everything critical passed · 1 something critical failed · 2 not root

set -u

VERDICT_P0=unknown   # executable storage
VERDICT_MOUNT=unknown # can we mount proc/devpts/bind from this context
VERDICT_CHROOT=unknown
VERDICT_LANDLOCK=unknown
VERDICT_PTY=unknown
VERDICT_XTOWNER=unknown
VERDICT_ROOT=unknown
VERDICT_MNTNS=unknown

CRITICAL_FAILED=0
SAVE=""

SCRATCH_BASE="${DSH_BASE:-/data/local/dsh}"
SCRATCH="$SCRATCH_BASE/.probe.$$"
PROBE_CHAIN="DSH_PROBE"

# --- output -----------------------------------------------------------------

say() {
  printf '%s\n' "$*"
  [ -n "$SAVE" ] && printf '%s\n' "$*" >>"$SAVE"
  return 0
}

pass() { say "[PASS] $*"; }
fail() { say "[FAIL] $*"; }
warn() { say "[WARN] $*"; }
skip() { say "[SKIP] $*"; }
info() { say "[INFO] $*"; }

critical_fail() {
  CRITICAL_FAILED=$((CRITICAL_FAILED + 1))
  fail "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  say ""
  say "== $* =="
}

# Value of a getprop key, or "unknown". Android-only; guarded for the host smoke
# test in tests/probe.test.sh.
prop() {
  if have getprop; then
    v=$(getprop "$1" 2>/dev/null)
    [ -n "$v" ] && printf '%s\n' "$v" && return 0
  fi
  printf 'unknown\n'
}

# Is $1 a mountpoint, and with which options? Prints "fstype options", or nothing.
mount_info() {
  [ -r /proc/mounts ] || return 1
  awk -v t="$1" '$2 == t { print $3, $4; found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts
}

cleanup() {
  # netfilter scratch chain
  if [ -n "${IPT:-}" ] && [ "$VERDICT_XTOWNER" != "skipped" ]; then
    "$IPT" -F "$PROBE_CHAIN" >/dev/null 2>&1
    "$IPT" -X "$PROBE_CHAIN" >/dev/null 2>&1
  fi
  # scratch mounts, deepest first
  if [ -d "$SCRATCH" ]; then
    for m in "$SCRATCH/pts" "$SCRATCH/proc" "$SCRATCH/bind" "$SCRATCH/tmpfs"; do
      mount_info "$m" >/dev/null 2>&1 && umount "$m" >/dev/null 2>&1
    done
    rm -rf "$SCRATCH" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

# --- identity ---------------------------------------------------------------

probe_identity() {
  section "Identity"
  if have uname; then
    info "uname: $(uname -a 2>/dev/null)"
    arch=$(uname -m 2>/dev/null)
    case "$arch" in
      aarch64 | arm64) pass "architecture is $arch" ;;
      *) critical_fail "architecture is $arch, not aarch64/arm64 — the published prebuilts do not cover it" ;;
    esac
  else
    warn "uname is not available"
  fi
  [ -r /proc/version ] && info "kernel: $(cat /proc/version)"
  info "android release: $(prop ro.build.version.release) (sdk $(prop ro.build.version.sdk))"
  info "build: $(prop ro.build.id) / $(prop ro.product.model)"
  if have df; then
    info "space: $(df -h /data 2>/dev/null | tail -n 1)"
  fi
}

# --- root solution ----------------------------------------------------------

root_family() {
  adb=${DSH_ADB:-/data/adb}
  ksu=0
  magisk=0
  if [ -x "$adb/ksud" ] || [ -d "$adb/ksu" ] || have ksud; then ksu=1; fi
  if [ -d "$adb/magisk" ] || have magisk; then magisk=1; fi
  if [ "$ksu" = 1 ] && [ "$magisk" = 1 ]; then
    printf 'both\n'
  elif [ "$ksu" = 1 ]; then
    v=$(ksu_version)
    case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in
      *next* | *ksun*) printf 'kernelsu-next\n' ;;
      *) printf 'kernelsu\n' ;;
    esac
  elif [ "$magisk" = 1 ]; then
    printf 'magisk\n'
  else
    printf 'none\n'
  fi
}

ksu_version() {
  adb=${DSH_ADB:-/data/adb}
  k=""
  [ -x "$adb/ksud" ] && k="$adb/ksud"
  [ -z "$k" ] && k=$(command -v ksud 2>/dev/null)
  [ -n "${k:-}" ] || return 0
  out=$("$k" --version 2>/dev/null) || out=$("$k" -V 2>/dev/null)
  printf '%s\n' "$out" | head -n 1
}

magisk_version() {
  adb=${DSH_ADB:-/data/adb}
  m="$adb/magisk/magisk"
  [ -x "$m" ] || m=$(command -v magisk 2>/dev/null)
  [ -n "${m:-}" ] && [ -x "$m" ] || return 0
  "$m" -v 2>/dev/null | head -n 1
}

su_context() {
  if [ -r /proc/self/attr/current ]; then
    tr -d '\000' </proc/self/attr/current
  else
    printf 'unknown\n'
  fi
}

probe_root() {
  section "Root solution"
  adb=${DSH_ADB:-/data/adb}
  family=$(root_family)
  VERDICT_ROOT="$family"
  info "solution: $family"
  case "$family" in
    magisk) info "magisk: $(magisk_version)" ;;
    kernelsu | kernelsu-next) info "kernelsu: $(ksu_version)" ;;
    both)
      info "magisk: $(magisk_version)"
      info "kernelsu: $(ksu_version)"
      info "both installed: KernelSU hooks the kernel and Magisk the ramdisk, so the"
      info "su that granted this shell may be either — 'dshd root' reports what it finds"
      ;;
    none)
      warn "no Magisk, KernelSU or KernelSU-Next found under $adb"
      ;;
  esac

  ctx=$(su_context)
  info "selinux context: $ctx"
  have getenforce && info "getenforce: $(getenforce 2>/dev/null)"
  case "$ctx" in
    u:r:su:s0*) info "KernelSU-family su domain" ;;
    u:r:magisk:s0*) info "Magisk su domain" ;;
    u:r:ksu:s0*) info "KernelSU kernel/ksu domain (as used by initrc.services)" ;;
  esac

  for c in su "$adb/ksu/bin/su" /debug_ramdisk/su /sbin/su /system/bin/su; do
    case "$c" in
      /*) [ -x "$c" ] && info "su binary: $c" ;;
      *) p=$(command -v "$c" 2>/dev/null) && [ -n "$p" ] && info "su binary: $p" ;;
    esac
  done

  if have su; then
    if out=$(su -c 'id -u' 2>&1) && [ "$out" = "0" ]; then
      pass "su -c works and returns uid 0"
    else
      warn "su -c 'id -u' returned: ${out:-no output} — the APK's token fetch would fail"
    fi
    # Magisk-only flag; KernelSU does not implement it, which is fine as long as
    # nothing in dshd depends on it. Recorded so the difference is known.
    if su --mount-master -c 'id -u' >/dev/null 2>&1 || su -M -c 'id -u' >/dev/null 2>&1; then
      info "su --mount-master: supported (Magisk-style global mount namespace)"
    else
      info "su --mount-master: not supported (expected on KernelSU and KernelSU-Next)"
    fi
  else
    warn "no su in PATH — this shell may already be root without one"
  fi
}

# --- mounts, and the namespace question -------------------------------------

probe_mounts() {
  section "Mounts and SELinux policy (this is the one that usually decides it)"
  VERDICT_MOUNT=pass
  mkdir -p "$SCRATCH" 2>/dev/null || {
    VERDICT_MOUNT=fail
    critical_fail "cannot create a scratch directory at $SCRATCH"
    return 0
  }

  # proc
  mkdir -p "$SCRATCH/proc"
  if mount -t proc proc "$SCRATCH/proc" 2>/dev/null; then
    pass "mount -t proc from this context"
    umount "$SCRATCH/proc" 2>/dev/null
  else
    VERDICT_MOUNT=fail
    critical_fail "mount -t proc denied — the chroot needs it; check 'avc: denied' below"
  fi

  # devpts: a separate filesystem type, so binding /dev alone does not provide it
  mkdir -p "$SCRATCH/pts"
  if mount -t devpts devpts "$SCRATCH/pts" 2>/dev/null; then
    pass "mount -t devpts from this context"
    umount "$SCRATCH/pts" 2>/dev/null
  else
    warn "mount -t devpts denied — PTYs inside the chroot will not work (D6 fallback)"
  fi

  # bind mount, which is how state/ and workspace/ get in
  mkdir -p "$SCRATCH/bind"
  if mount -o bind /data "$SCRATCH/bind" 2>/dev/null; then
    pass "bind mount from this context"
    umount "$SCRATCH/bind" 2>/dev/null
  else
    VERDICT_MOUNT=fail
    critical_fail "bind mount denied — state/ and workspace/ cannot be mounted in"
  fi

  # Did SELinux say anything? Kernel logs are the only place a denial explains
  # itself, and a denial with no explanation is what turns into a lost weekend.
  denials=""
  if have dmesg; then
    denials=$(dmesg 2>/dev/null | grep -i 'avc:.*denied' | tail -n 5)
  fi
  if [ -z "$denials" ] && have logcat; then
    denials=$(logcat -d -b all 2>/dev/null | grep -i 'avc:.*denied' | tail -n 5)
  fi
  if [ -n "$denials" ]; then
    warn "recent SELinux denials:"
    printf '%s\n' "$denials" | while IFS= read -r l; do say "       $l"; done
  else
    info "no recent 'avc: denied' found in dmesg/logcat"
  fi
}

# The design has the APK own the runtime's lifetime, so it matters whether a
# bind mount made in one su session is visible to a *new* one — Magisk and
# KernelSU differ here, and it has changed over KernelSU releases.
probe_mount_namespace() {
  section "Mount namespace across su sessions"
  mkdir -p "$SCRATCH/tmpfs" 2>/dev/null || return 0
  if ! mount -t tmpfs -o size=1m tmpfs "$SCRATCH/tmpfs" 2>/dev/null; then
    VERDICT_MNTNS="unknown"
    warn "could not mount a scratch tmpfs; namespace question unanswered"
    return 0
  fi

  here=$(grep -c " $SCRATCH/tmpfs " /proc/mounts 2>/dev/null)
  fresh="no-su"
  if have su; then
    fresh=$(su -c "grep -c ' $SCRATCH/tmpfs ' /proc/mounts 2>/dev/null" 2>/dev/null)
  fi
  umount "$SCRATCH/tmpfs" 2>/dev/null

  case "$fresh" in
    '' | *[!0-9]*) VERDICT_MNTNS="unknown"; warn "could not query a fresh su session ($fresh)" ;;
    0)
      VERDICT_MNTNS="separate"
      warn "a fresh su session does NOT see this session's mounts (this session: $here)"
      warn "⇒ dshd start and dshd stop must come from the same owner (the APK's"
      warn "  service), or stop will not find the mounts it is meant to remove"
      ;;
    *)
      VERDICT_MNTNS="shared"
      pass "a fresh su session sees this session's mounts (shared mount namespace)"
      ;;
  esac
}

# --- storage: the probe that can end the project ----------------------------

probe_storage() {
  section "Storage: executable, and not FUSE"
  for dir in "$SCRATCH_BASE" "${DSH_ROOTFS:-$SCRATCH_BASE/rootfs}" /data/local/tmp; do
    if [ ! -d "$dir" ]; then
      skip "$dir does not exist yet"
      continue
    fi
    if have df; then
      info "$dir: $(df -h "$dir" 2>/dev/null | tail -n 1)"
    fi
    opts=$(mount_info "$dir" 2>/dev/null)
    [ -n "$opts" ] && info "$dir: fstype/options $opts"

    # Functional, not textual: the mount table can be right while execution is
    # still denied, and this is the probe that decides whether the whole
    # approach survives.
    marker="$dir/.dsh-probe-exec.$$"
    if ! printf '#!%s\nprintf ok\\n' "$(command -v sh)" >"$marker" 2>/dev/null; then
      warn "$dir is not writable by this shell"
      continue
    fi
    chmod +x "$marker" 2>/dev/null
    if out=$("$marker" 2>&1) && [ "$out" = "ok" ]; then
      pass "$dir executes what is written to it"
      [ "$VERDICT_P0" = fail ] || VERDICT_P0=pass
    else
      critical_fail "$dir does not execute (noexec?) — Node cannot run from here; this ends the chroot approach for this path"
      VERDICT_P0=fail
    fi
    rm -f "$marker" 2>/dev/null
  done
}

# --- kernel capabilities ----------------------------------------------------

probe_kernel_caps() {
  section "Kernel capabilities"
  if [ -r /proc/sys/user/max_user_namespaces ]; then
    n=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)
    info "max_user_namespaces: $n"
    [ "$n" = "0" ] && warn "0 ⇒ bwrap is dead; runner rung 1 is out (expected)"
  else
    info "max_user_namespaces: not exposed"
  fi
  have unshare && info "unshare: present" || info "unshare: absent"
  have setpriv && info "setpriv: present" || info "setpriv: absent"

  # Landlock, three ways: symbols, securityfs, and the actual syscall. The plan
  # is explicit that kernel version alone is not a signal.
  if have grep && [ -r /proc/kallsyms ]; then
    n=$(grep -ci landlock /proc/kallsyms 2>/dev/null)
    info "landlock symbols in kallsyms: ${n:-0}"
  fi
  [ -d /sys/kernel/security/landlock ] && info "securityfs: /sys/kernel/security/landlock present"

  if have python3; then
    out=$(python3 - <<'PY' 2>/dev/null
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
# landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) — 444 on
# both x86_64 and arm64.
res = libc.syscall(444, None, 0, 1)
print(res if res >= 0 else "errno=%d" % ctypes.get_errno())
PY
)
    case "$out" in
      errno=38 | errno=*)
        VERDICT_LANDLOCK="unavailable"
        warn "landlock_create_ruleset: $out ⇒ no Landlock; D3 falls back to danger-full-access (and must be disclosed)"
        ;;
      '' )
        VERDICT_LANDLOCK="unknown"
        warn "landlock functional probe produced no output"
        ;;
      *)
        VERDICT_LANDLOCK="abi v$out"
        pass "landlock_create_ruleset works: ABI version $out"
        ;;
    esac
  else
    VERDICT_LANDLOCK="unknown"
    skip "python3 is not installed — Landlock cannot be probed functionally (kallsyms is a hint, not proof)"
  fi
}

# --- PTY (D6) ---------------------------------------------------------------

probe_pty() {
  section "PTY / devpts (decides D6: terminal, or the declared fallback)"
  [ -d /dev/pts ] && pass "/dev/pts exists" || warn "/dev/pts is missing"
  [ -c /dev/ptmx ] && pass "/dev/ptmx exists" || warn "/dev/ptmx is missing"
  m=$(mount_info /dev/pts 2>/dev/null)
  if [ -n "$m" ]; then
    pass "/dev/pts is a mount: $m"
  else
    warn "/dev/pts is not a separate mount (it should be devpts)"
  fi

  if have python3; then
    if out=$(python3 -c 'import pty; pty.openpty(); print("ok")' 2>&1) && [ "$out" = "ok" ]; then
      VERDICT_PTY="ok"
      pass "a PTY allocates (python3 pty.openpty)"
    else
      VERDICT_PTY="fail"
      warn "PTY allocation failed: $out ⇒ the terminal is unavailable; ship the D6 fallback and say so in the UI"
    fi
  else
    VERDICT_PTY="unknown"
    skip "python3 is not installed; the real PTY test is node-pty inside the rootfs (Phase 2)"
  fi
}

# --- netfilter (§7) ---------------------------------------------------------

probe_netfilter() {
  section "Netfilter: the §7 reachability control"
  IPT=""
  for c in iptables; do
    if have "$c"; then
      IPT=$(command -v "$c")
      info "$c: $IPT"
      "$c" --version 2>/dev/null | head -n 1
    fi
  done
  have ip6tables && info "ip6tables: $(command -v ip6tables)" || info "ip6tables: absent"
  have nft && info "nft: $(command -v nft)" || info "nft: absent"

  if [ -z "$IPT" ]; then
    VERDICT_XTOWNER="absent"
    critical_fail "iptables is not available — tools/firewall.sh cannot run, and the guard alone does not stop another app reaching 127.0.0.1:3080"
    return 0
  fi

  # Functional owner-match probe in a scratch chain: created, used, removed.
  "$IPT" -N "$PROBE_CHAIN" 2>/dev/null || "$IPT" -F "$PROBE_CHAIN" 2>/dev/null
  if "$IPT" -A "$PROBE_CHAIN" -o lo -p tcp --dport 1 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null; then
    VERDICT_XTOWNER="ok"
    pass "the owner match works (xt_owner) — tools/firewall.sh can enforce §7"
  else
    VERDICT_XTOWNER="missing"
    critical_fail "the owner match is rejected (missing CONFIG_NETFILTER_XT_MATCH_OWNER?) — §7 has no reachability control on this kernel"
  fi
  "$IPT" -F "$PROBE_CHAIN" 2>/dev/null
  "$IPT" -X "$PROBE_CHAIN" 2>/dev/null
}

# --- chroot -----------------------------------------------------------------

probe_chroot() {
  section "chroot"
  if have chroot; then
    pass "chroot binary: $(command -v chroot)"
  else
    critical_fail "no chroot binary — D1 depends on it (proot is explicitly rejected)"
    return 0
  fi
  rootfs=${DSH_ROOTFS:-$SCRATCH_BASE/rootfs}
  if [ -x "$rootfs/bin/sh" ]; then
    if out=$(chroot "$rootfs" /bin/sh -c 'printf ok' 2>&1) && [ "$out" = "ok" ]; then
      VERDICT_CHROOT="ok"
      pass "chroot into $rootfs works"
    else
      critical_fail "chroot into $rootfs failed: $out"
    fi
  else
    VERDICT_CHROOT="skipped"
    skip "$rootfs has no /bin/sh yet — run tools/rootfs-setup.sh (Phase 1), then re-run this"
  fi
}

# --- the toolbox dshd itself needs ------------------------------------------

probe_toolbox() {
  section "Commands dshd and the guard depend on"
  missing=""
  # Setsid is optional (nohup is the fallback) and nc is only the host-side port
  # check, so they are listed separately rather than as failures.
  for c in awk cut cksum date dirname grep head od sed sleep tail tr wc mount umount chmod kill; do
    have "$c" || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    critical_fail "missing commands:$missing"
  else
    pass "all required commands are present"
  fi
  optional=""
  for c in setsid nohup mktemp nc; do
    have "$c" || optional="$optional $c"
  done
  [ -n "$optional" ] && info "optional commands absent:$optional" || info "optional commands all present"
}

# --- the gate ---------------------------------------------------------------

verdicts() {
  section "VERDICTS (gate P0)"

  case "$VERDICT_P0" in
    pass) say "P0 storage    : PASS — the target paths execute what is written to them" ;;
    fail) say "P0 storage    : FAIL — noexec on the target path. D1 cannot work there; see plan §6" ;;
    *) say "P0 storage    : UNKNOWN — no target directory existed to test" ;;
  esac

  case "$VERDICT_MOUNT" in
    pass) say "Mount/SELinux : PASS — proc, devpts and bind mounts all succeeded from this context" ;;
    fail) say "Mount/SELinux : FAIL — a required mount was denied (see the denials above)" ;;
    *) say "Mount/SELinux : UNKNOWN — the mount probes did not run" ;;
  esac

  case "$VERDICT_CHROOT" in
    ok) say "chroot        : PASS" ;;
    skipped) say "chroot        : SKIPPED — re-run after Phase 1" ;;
    *) say "chroot        : FAIL — see above" ;;
  esac

  case "$VERDICT_LANDLOCK" in
    unknown) say "D3 confine    : UNKNOWN — probe Landlock before choosing (kallsyms alone is not proof)" ;;
    unavailable) say "D3 confine    : NO LANDLOCK — pin DSH_PERMISSION_MODE=danger-full-access in dshd and disclose it in the UI" ;;
    *) say "D3 confine    : LANDLOCK $VERDICT_LANDLOCK — keep the stock chain and prove a denied write (Phase 3)" ;;
  esac

  case "$VERDICT_PTY" in
    ok) say "Terminal (D6) : ENABLED — devpts and PTY allocation work" ;;
    fail) say "Terminal (D6) : FALLBACK — PTY allocation fails; ship without the sidebar terminal and say so" ;;
    *) say "Terminal (D6) : UNKNOWN — re-check with node-pty inside the rootfs (Phase 2)" ;;
  esac

  case "$VERDICT_XTOWNER" in
    ok) say "§7 firewall   : AVAILABLE — apply tools/firewall.sh --uid <APP_UID>" ;;
    missing) say "§7 firewall   : UNAVAILABLE — the owner match is missing; the guard alone does not satisfy §7" ;;
    *) say "§7 firewall   : UNAVAILABLE — no iptables; the guard alone does not satisfy §7" ;;
  esac

  case "$VERDICT_MNTNS" in
    shared) say "Mount ns      : SHARED with a fresh su session — start/stop from anywhere" ;;
    separate) say "Mount ns      : SEPARATE per su session — the same owner must start and stop dshd (the APK service)" ;;
    *) say "Mount ns      : UNKNOWN — unanswered by this run" ;;
  esac

  say "Root          : $VERDICT_ROOT ($(su_context))"
  say "ADB dir       : ${DSH_ADB:-/data/adb}"
  say ""
  if [ "$CRITICAL_FAILED" -gt 0 ]; then
    say "RESULT: $CRITICAL_FAILED critical probe(s) failed — do not start Phase 1 until they are resolved or explicitly accepted."
  else
    say "RESULT: no critical failures. Record this table in docs/phase-0-probe-ledger.md and close gate P0."
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --save)
        shift
        SAVE=${1:-}
        [ -n "$SAVE" ] || { printf 'probe: --save needs a path\n' >&2; exit 1; }
        : >"$SAVE" || { printf 'probe: cannot write %s\n' "$SAVE" >&2; exit 1; }
        ;;
      -h | --help)
        printf 'usage: probe.sh [--save FILE]\n\nSee the header of this script and plan §5 Phase 0.\n'
        exit 0
        ;;
      *)
        printf 'probe: unknown argument %s\n' "$1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ "$(id -u 2>/dev/null)" != 0 ]; then
    printf 'probe: must run as root — most of these probes are about what the su context may do\n' >&2
    exit 2
  fi

  say "dsh-android Phase 0 probe — $(date 2>/dev/null)"
  say "Run from a root shell; record the output in docs/phase-0-probe-ledger.md."

  probe_identity
  probe_root
  probe_storage
  probe_mounts
  probe_mount_namespace
  probe_kernel_caps
  probe_pty
  probe_netfilter
  probe_chroot
  probe_toolbox
  verdicts

  cleanup
  trap - EXIT INT TERM
  [ "$CRITICAL_FAILED" -gt 0 ] && exit 1
  exit 0
}

main "$@"
