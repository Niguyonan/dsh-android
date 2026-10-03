# Phase 0 probe ledger

Template. Fill it in **on the device**, from a root shell, and keep the raw
output: the point of gate P0 is a written table with evidence, not a remembered
"looked fine".

```sh
sh /data/local/dsh/tools/probe.sh --save /data/local/dsh/log/phase-0-$(date +%F).txt
```

Paste the saved report into the *Raw output* section, then transcribe the
verdicts into the tables below. Do not start Phase 1 until the gate row is
filled in and the abort condition has been considered.

## Device

| Field | Value |
|---|---|
| Model / codename | |
| Android release / SDK | |
| Kernel (`uname -r`) | |
| ROM / build id | |
| Root solution | Magisk / KernelSU / KernelSU-Next / more than one |
| Root solution version | |
| Manager package(s) installed | |
| ABI | `aarch64`? |
| Free space on `/data` | |
| Date probed | |
| Probed by | |

## Gate P0 — abort conditions first

These three decide whether the approach survives at all. A failure here is not a
"note"; plan §5 Phase 0 makes it an abort or a redesign.

| Probe | What passes | Result | Evidence (command output) |
|---|---|---|---|
| **Executable storage** — `/data/local/dsh` and the rootfs path run what is written to them | a script written, `chmod +x`, and executed | | |
| **`mount -t proc`** from the `su` context | succeeds | | |
| **bind mount** from the `su` context | succeeds | | |
| **`chroot` binary + functional chroot** into the rootfs | `chroot <rootfs> /bin/sh -c 'printf ok'` → `ok` | | |
| **Commands `dshd` needs** (`awk cut cksum date dirname grep head od sed sleep tail tr wc mount umount chmod kill`) | all present | | |

`noexec` on the target path **kills the approach** (plan §6): Node cannot run at
all. Stop and pick a different path before going further.

## Decisions this gate resolves

| Decision | Probe | Result | Chosen posture |
|---|---|---|---|
| **D3 confinement** | Landlock: kallsyms hits, `/sys/kernel/security/landlock`, and the functional `landlock_create_ruleset` probe (ABI version) | | `landlock` (stock chain) **or** `DSH_PERMISSION_MODE=danger-full-access`, pinned in `dshd` and disclosed in the UI |
| **D6 terminal** | `/dev/pts` is devpts, `/dev/ptmx` present, PTY actually allocates | | terminal enabled **or** the declared fallback, with the absence visible in the UI |
| **§7 reachability control** | `iptables` present **and** the `owner` match accepted | | `tools/firewall.sh apply --uid <APP_UID>` **or** an explicit note that the guard alone does not satisfy §7 |
| **Mount namespace** | does a fresh `su -c` see a tmpfs mounted by this session? | | `shared` → start/stop from anywhere; `separate` → the APK service must own both |

Acceptance criterion 8 requires the §7 control to be **proven** to block a second
app, not merely installed: after applying, run the procedure in
[`security.md`](./security.md#2-a-second-app-is-actually-blocked-the-step-that-matters).

## Root-solution specifics

The port must run under all three solutions; see
[`root-solutions.md`](./root-solutions.md) for why these rows exist.

| Probe | Result | Notes |
|---|---|---|
| `su` resolved from (`PATH`, `/data/adb/ksu/bin/su`, `/debug_ramdisk/su`, `/sbin/su`, `/system/bin/su`) | | |
| `su -c 'id -u'` returns `0` | | the APK's token fetch depends on this |
| SELinux context of the root shell (`/proc/self/attr/current`) | | Magisk is usually `u:r:magisk:s0`; KernelSU `u:r:su:s0` |
| `getenforce` | | |
| `su --mount-master` supported? | | Magisk-only; expected absent on KernelSU |
| Both Magisk and KernelSU installed? | | coexistence is supported; record which `su` wins |
| `/data/adb/service.d` usable for autostart (executable, runs) | | needed by `boot/service.d/dshd.sh` |
| `KSU=true` seen in a boot script | | confirms KernelSU ran it |

## Kernel facts to re-check after every ROM/kernel update

Landlock, `xt_owner`, `noexec`, and the SELinux policy for `mount` from `su` are
properties of the **kernel and ROM**, not of the device. A posture that passed
last month is not evidence about this month's kernel.

| Probe | Result |
|---|---|
| Kernel generation / KMI | |
| `max_user_namespaces` | |
| Landlock ABI version | |
| `xt_owner` accepted | |
| SELinux denials during the mount probes (`avc: denied`) | |
| FUSE anywhere near the workspace path | |

## Raw output

```
(paste `probe.sh --save` output here)
```

## Gate P0 sign-off

- [ ] All abort-condition probes pass, or a different path/approach has been chosen
- [ ] D3 resolved to a concrete posture, with the evidence above
- [ ] D6 terminal verdict recorded (enabled or fallback)
- [ ] §7 control available, or the gap is written down and accepted
- [ ] Root solution and `su` path recorded
- [ ] Mount-namespace behaviour recorded

Signed off: ______________________  Date: __________
