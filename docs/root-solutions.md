# Root solutions: Magisk, KernelSU, KernelSU-Next

This port must run under all three. They differ in exactly the places this
project is fragile — the `su` binary, the SELinux domain `su` runs in, the mount
namespace a new root session gets, and where boot scripts live — so "it works on
my Magisk setup" is not a claim about KernelSU. This document records what is
known, what this repository does about it, and what only the device can answer.

## Who hooks what

- **Magisk** patches the **ramdisk**.
- **KernelSU** / **KernelSU-Next** patch the **kernel**.
- They therefore **coexist**: KernelSU's own FAQ states that if you only use
  KernelSU's `su` it works well alongside Magisk ([KernelSU
  FAQ](https://kernelsu.org/guide/faq.html)). "Both installed" is a real
  configuration, not a broken one, so `dshd` reports it rather than picking one
  and hoping.

## Detection

`bin/dshd` (`dshd root`, and the `root:` line in `dshd status`) and
`tools/probe.sh` detect by filesystem and version string, never by assumption:

| Signal | Magisk | KernelSU | KernelSU-Next |
|---|---|---|---|
| Work dir | `/data/adb/magisk` | `/data/adb/ksu` | `/data/adb/ksu` |
| Daemon | — (`magisk` binary) | `/data/adb/ksud` | `/data/adb/ksud` |
| BusyBox | `/data/adb/magisk/busybox` | `/data/adb/ksu/bin/busybox` | `/data/adb/ksu/bin/busybox` |
| Manager package | `com.topjohnwu.magisk` | `me.weishu.kernelsu` | `com.rifsxd.ksunext` |
| Boot-script env | — | `KSU=true` | `KSU=true` |

KernelSU and KernelSU-Next deliberately share `WORKING_DIR` and `DAEMON_PATH`
(compare `userspace/ksud/src/defs.rs` in
[tiann/KernelSU](https://github.com/tiann/KernelSU/blob/main/userspace/ksud/src/defs.rs)
and
[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next/blob/master/userspace/ksud/src/defs.rs)
— the only difference is the backup file prefix). So they are **one code path
with two version strings**, and telling them apart is a reporting concern:

1. the `ksud --version` string (if it mentions `next`/`ksun`), else
2. the installed manager package (`com.rifsxd.ksunext`), else
3. `kernelsu` — and the raw version string is printed either way, so the ledger
   records what is actually there instead of what the code guessed.

## `su`

The `su` binary is not in a predictable place, and on some setups it is not in
`PATH` at all ([tiann/KernelSU#2647](https://github.com/tiann/KernelSU/issues/2647)).
`bin/dshd` therefore resolves it in this order and reports which one it found:

1. `su` from `PATH` — when `dshd` runs from a root shell, this is the shell the
   operator was granted, and the one whose mount namespace this process inherits
2. `/data/adb/ksu/bin/su` — KernelSU / KernelSU-Next
3. `/debug_ramdisk/su` — Magisk 24+
4. `/sbin/su` — older Magisk
5. `/system/bin/su` — traditional, and some KernelSU setups

There is no "auth disabled" or "assume root" path: `dshd` still checks `id -u`
and exits 2 if it is not 0, whatever granted the shell.

## SELinux domain

The domain `su` runs in decides whether `mount` and `iptables` are permitted, and
it is **not** the same across solutions:

- Magisk's `su` runs as `u:r:magisk:s0`.
- KernelSU's runs as `u:r:su:s0` by default, and the manager lets the user change
  it per app — KernelSU-Next exposes the domain as a per-app choice.
- KernelSU's own initrc example uses `u:r:ksu:s0` for services it injects
  ([module guide](https://kernelsu.org/guide/module.html)), which is a different
  context from an interactive `su` shell.

Nothing in this repository hardcodes a domain. `dshd root` and `probe.sh` **read**
`/proc/self/attr/current` and report it, and Phase 0 checks the thing that
actually matters: whether mounts succeed *from this context*.

## Boot scripts

`/data/adb/service.d` works on all three, which is why `boot/service.d/dshd.sh`
is installed there and not into a Magisk-specific module:

- Magisk: `/data/adb/service.d` (and a module's own `service.d`).
- KernelSU / KernelSU-Next: general scripts in `/data/adb/post-fs-data.d`,
  `/data/adb/service.d`, `/data/adb/post-mount.d`, `/data/adb/boot-completed.d`
  run in the corresponding boot stage, and **only if they are executable**
  ([module guide](https://kernelsu.org/guide/module.html)).

Two KernelSU-specific facts the script is written around:

- Scripts run in **BusyBox `ash` with Standalone Mode** (`ASH_STANDALONE=1`), so
  applets come from BusyBox regardless of `PATH`. That is good for us — the
  utilities `dshd` needs are all there — but it means the script must be POSIX
  and must not assume a host `PATH`.
- KernelSU adds a `boot-completed` stage and a `late-load` mode; `service.d` runs
  in all of them, so autostart does not care which boot path the device took.

Autostart stays **opt-in** (`autostart=on` in `etc/dshd.conf`), because D5 gives
the APK ownership of the runtime's lifetime.

## Modules: not required for this port

KernelSU's module mounting is delegated to a metamodule, and its docs warn that
`system`-directory modules need one. This port **does not modify `/system`** — it
installs everything under `/data/local/dsh` and mounts into its own rootfs — so
it needs no module and no metamodule on any of the three solutions. The only
integration points are `su` and the boot-script directory.

## The mount-namespace question (probe it, do not assume it)

A bind mount made in one `su` session lives in that session's mount namespace.
Whether a **new** `su` session sees it differs by solution and by release:
KernelSU added mount-namespace support in a
[2025 commit](https://github.com/tiann/KernelSU/commit/c95c2d7956a23f4bf23713eb1a4ca86b8ad04569),
and "no global namespace" behaviour has been reported against its libsu
([tiann/KernelSU#180](https://github.com/tiann/KernelSU/issues/180)). Magisk has
`su --mount-master` for the global namespace; KernelSU does not implement that
flag.

This matters operationally:

- `dshd start` creates the mounts, and its children inherit them — that part is
  safe on every solution.
- `dshd stop` run from a **different** session may be in a different namespace,
  where those mounts do not exist, so it cannot unmount them.
- The same applies to `dshd status`'s mount summary.

The design answer is already in D5: **the APK's foreground service owns the
lifecycle**, so start and stop come from the same owner. `tools/probe.sh` asks
the question directly — it mounts a scratch tmpfs, then checks whether a fresh
`su -c` can see it — and prints one of:

```
Mount ns      : SHARED with a fresh su session — start/stop from anywhere
Mount ns      : SEPARATE per su session — the same owner must start and stop dshd
```

If your device reports `SEPARATE`, do not drive `dshd stop` from a terminal and
expect it to clean up the mounts the app created.

## What only the device can answer

Recorded here so it does not get mistaken for knowledge:

- Whether `su`'s domain on **your** ROM may `mount -t proc`, `mount -t devpts`,
  and bind-mount. Magisk is commonly permissive here; KernelSU's `u:r:su:s0` is
  usually allowed but is policy, not a guarantee, and a Magisk `su` context being
  denied `mount` is a known ROM-dependent failure.
- Whether your kernel has `xt_owner` (needed by `tools/firewall.sh`) and
  Landlock (needed by D3). Both are **kernel** properties, independent of which
  root solution you use, and both must be re-probed after a kernel or ROM update.
- Which `su` a given app actually gets when both managers are installed.

All three are exactly what `tools/probe.sh` answers on the device; the results
belong in `docs/phase-0-probe-ledger.md`.
