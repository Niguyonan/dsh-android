# dsh-android — DeepSeek Harness on rooted Android

Implementation of [`PORTING-PLAN.md`](./PORTING-PLAN.md): run the upstream DeepSeek
Harness (`dsh`) on a rooted `aarch64` Android device as an app-like experience.

**Runtime strategy (D1):** a glibc Linux rootfs inside a real `chroot`, orchestrated
from a root shell. Upstream's stock `linux-arm64` artifacts are valid verbatim inside
that rootfs, so there is **no native code to rebuild and no fork to maintain**.

## Architecture

```
┌─ Magisk / KernelSU / KernelSU-Next root shell ───────────────────────────┐
│  /data/local/dsh/                                                        │
│    rootfs/       glibc arm64 rootfs (Debian/Ubuntu)                      │
│    workspace/    agent working directory (ext4 — never noexec, never FUSE)│
│    state/        DSH_HOME: sessions, storages, creds, logs               │
│    state/guard.token    0600, per-install token for the loopback guard    │
│    state/posture.conf   Phase 3 confinement verdict (pinned mode)         │
│    bin/dshd      start|stop|restart|status|token|logs|mounts|doctor       │
│    guard/guard.mjs   token-auth loopback guard (§7)                       │
│    log/          dshd.log, harness.log, guard.log (+ rotated)             │
└──────────────────────────────────────────────────────────────────────────┘
      │ chroot rootfs; bind /proc, /dev (incl. /dev/pts), workspace, state
      ▼
   node (glibc) → dsh web --no-open --port 3080     ← loopback only, NOT exposed
      ▲
      │ TCP 127.0.0.1:3080
┌─ guard.mjs :3081 ────────────────────────────────────────────────────────┐
│  required token (cookie / bearer / x-dsh-token)                          │
│  strict Host + Origin allowlist, loopback bind enforced by the process   │
│  forwards HTTP, SSE, and WebSocket upgrades                              │
└──────────────────────────────────────────────────────────────────────────┘
      ▲
      │ TCP 127.0.0.1:3081 — the ONLY port the app talks to
┌─ WebView APK ────────────────────────────────────────────────────────────┐
│  Activity: WebView → http://127.0.0.1:3081                               │
│  Foreground service: owns server lifecycle + PARTIAL_WAKE_LOCK            │
│  Notification: status, Restart, Stop                                      │
└──────────────────────────────────────────────────────────────────────────┘
```

Two things the diagram is load-bearing for, both from §7 of the plan:

- **Loopback is not an app-to-app boundary on Android.** Any app holding `INTERNET`
  can reach `127.0.0.1`, and the harness executes shell commands — as root, here.
  The guard plus the UID-owner firewall rule are the controls; see
  [`docs/security.md`](./docs/security.md).
- **`/dev/pts` is a separate filesystem.** Binding `/proc` alone does not provide it,
  and every PTY allocation fails without it — silently costing the terminal.
- **The root solution is not a detail.** Magisk patches the ramdisk, KernelSU and
  KernelSU-Next patch the kernel, and the three differ in the `su` binary's path, the
  SELinux domain `su` runs in, and whether a *new* root session sees mounts made by
  this one. `dshd root` reports what it found; [`docs/root-solutions.md`](./docs/root-solutions.md)
  records the differences and what must be probed rather than assumed.

## Layout

Everything in this table exists and is exercised by `tests/run.sh`.

| Path | Phase | What it is |
|---|---|---|
| `bin/dshd` | 1, 4 | The on-device entry point: chroot/mount wrapper *plus* supervisor. POSIX `sh`, runs under Magisk's `mksh`, KernelSU's BusyBox `ash`, or a plain `sh -c`. |
| `guard/guard.mjs` | §7 | The token guard. Zero dependencies, Node built-ins only. |
| `guard/test/guard.test.mjs` | §7 | Proves the guard's controls rather than asserting them: auth, Host/Origin, bind refusal, upgrade teardown. |
| `tools/probe.sh` | 0 | Phase 0 device probes → the P0 ledger, with verdicts for D3, D6 and §7, and the root-solution block. |
| `tools/rootfs-setup.sh` | 1 | Fetch + checksum-verify the glibc arm64 base and glibc Node, build the skeleton, write DNS, then run Gate P1 in a chroot. |
| `tools/install-harness.sh` | 2 | Install the pinned harness with `--ignore-scripts`, then *prove* the contract everything downstream depends on: loopback-only bind, 401 without a session, the launch-token line `dshd` parses, and the cross-origin fence. |
| `tools/firewall.sh` | §7 | The reachability half of the mitigation: a UID-owner rule set that keeps every other app off both ports, self-verified after apply. |
| `boot/service.d/dshd.sh` | 4 | Opt-in boot autostart, installed at `/data/adb/service.d` — the path all three root solutions run. |
| `docs/security.md` | §7 | The exposure, the two controls, and the on-device procedure that proves a second app is blocked. |
| `docs/root-solutions.md` | — | Magisk vs KernelSU vs KernelSU-Next: detection, `su`, SELinux domains, boot scripts, mount namespaces. |
| `docs/phase-0-probe-ledger.md` | 0 | The P0 template to fill in on the device, including the root-solution rows. |
| `tests/run.sh` | — | Host-side entry point: the guard, firewall, probe, rootfs and harness-install suites, then `dshd`'s lifecycle suite. |
| `tests/dshd.test.sh` | — | `dshd`'s lifecycle without a device or root: exit codes, posture, rotation, firewall handover, supervisor pair semantics. |
| `tests/firewall.test.sh` | §7 | The rule set against a fake iptables: apply, verify, tamper detection, removal, idempotence. |
| `tests/probe.test.sh` | 0 | `probe.sh`'s contract and verdicts with the device stubbed: it must fail loudly on a host, never quietly. |
| `tests/rootfs-setup.test.sh` | 1 | `rootfs-setup.sh` with local tarballs instead of downloads: extraction, checksums, refusal to clobber, re-run paths. |
| `tests/install-harness.test.sh` | 2 | `install-harness.sh` with the registry and chroot stubbed, including the negative controls: an open harness and a wild bind must both fail the smoke test. |

**Not written yet** — named so that the quick start below reads as a plan rather
than a description: `tools/confinement-check.sh` (3), `android/` (5),
`tools/backup.sh`, `tools/update.sh`, `tools/rollback.sh`, `tools/doctor.sh` (6)
and `docs/runbook.md`.

## Quick start

Host-side checks (any machine with Node and `sh`):

```sh
tests/run.sh                 # guard, §7 rule set, Phase 0 probes, dshd lifecycle
```

On the device, from a root shell, in order — **do not skip a gate**:

```sh
sh /data/local/dsh/tools/probe.sh --save /data/local/dsh/log/p0.txt   # P0 gate
sh /data/local/dsh/tools/rootfs-setup.sh       # P1: fetches, verifies, and proves glibc
sh /data/local/dsh/tools/install-harness.sh    # P2: full agent round-trip
sh /data/local/dsh/tools/confinement-check.sh  # P3: posture proven, not assumed
sh /data/local/dsh/tools/firewall.sh apply --uid <APP_UID>   # §7: other app UIDs rejected
sh /data/local/dsh/bin/dshd start              # P4: supervisor
```

`probe.sh` prints verdicts, not just output: whether the target paths are
executable, whether the `su` context may mount, whether Landlock and `xt_owner`
exist, and which root solution and `su` you are on. Fill
[`docs/phase-0-probe-ledger.md`](./docs/phase-0-probe-ledger.md) in from it before
Phase 1 — the plan hangs every later decision on that table.

The firewall rule goes on **before** the supervisor, not after: it is what keeps
other apps away from the ports the supervisor is about to open. Setting
`DSH_FIREWALL=on` in `etc/dshd.conf` makes `dshd` re-apply it on every start, so
it survives reboots; `docs/security.md` has the procedure that proves it works.

Then install the APK, which starts, fronts, and stops all of the above.

## Status — what is verified here, and what only a device can answer

This repository is a macOS-development-host implementation of a device-targeted plan.
Being explicit about the split is part of the design (§10 of the plan).

**Verified on this host:** the guard's authentication, Host/Origin, loopback-bind and
proxying behaviour, including WebSocket upgrades and the teardown of upgraded sockets;
`dshd`'s lifecycle logic (idempotent start, stale-PID cleanup, posture resolution,
token handling, log rotation, exit codes) driven through its dry-run path; and the
supervisor's pair semantics driven end-to-end against the *real* guard with a stand-in
harness — kill either child and the other is torn down and the pair restarts, with the
pid file proven (via `lsof`) to name the process that holds the port. Also the §7
rule set: `tools/firewall.sh` is driven against a fake iptables through
apply → verify → tamper → remove, including that a kernel without the owner match
fails loudly instead of reporting success. `tools/probe.sh` is exercised end to end
with the device stubbed out: it must produce its verdicts, fail loudly on a host,
and touch netfilter only through its own scratch chain. `tools/rootfs-setup.sh` is
driven through local tarballs: checksum mismatches stop it before anything is
installed, a second run refuses to clobber a rootfs without `--force`, a symlinked
`resolv.conf` is replaced rather than written through, and `--skip-verify` says
out loud that Gate P1 did not run. `tests/run.sh` runs all of it.

**Root solutions:** the stack is written against uid 0 plus a working `su` rather
than against Magisk. `dshd root` and `probe.sh` detect Magisk, KernelSU and
KernelSU-Next (they share `/data/adb/ksu` and `/data/adb/ksud`, so they differ only
by version string and manager package), report the SELinux domain actually in use,
and resolve `su` across all five places it lives. What differs per solution — and
what therefore has to be probed on your device — is in
[`docs/root-solutions.md`](./docs/root-solutions.md).

**Untestable off-device, and therefore still open:** every kernel-level question —
Landlock availability, unprivileged user namespaces, `noexec` on `/data`, SELinux
policy for `mount` from a `su` context, `xt_owner` for the firewall rule, and whether
`node-pty` allocates a PTY under the Android kernel in a chroot. Those need
`tools/probe.sh` on the actual hardware and are tracked in
[`docs/phase-0-probe-ledger.md`](./docs/phase-0-probe-ledger.md).

## Defects the host tests caught (and what they cost on a device)

Recorded because each one failed *silently* in production shape — the class of bug
that a device would have blamed on Android:

- **Upgraded sockets leaked.** Node detaches a socket handed to an `upgrade` listener
  from the server's connection tracking, so `closeAllConnections()` skips it and
  `server.close()` waits on it forever. Every WebView reload left its harness
  connection open for the life of the process, and `SIGTERM` was answered only by
  `dshd`'s `SIGKILL`. The guard now tracks its pairs and tears down both ends.
- **The guard could exit 0 without listening.** The `argv[1] === import.meta.url`
  check did not resolve symlinks, so under any symlinked path (`/tmp` on macOS, a
  symlinked install dir) `main()` never ran: no log line, no port, and a supervisor
  restarting it forever. Both sides are realpath'd now, with a test that executes the
  guard through a symlink.
- **`$!` was a wrapper subshell, not the child.** Backgrounding a shell *function*
  makes `$!` the subshell; the harness is a grandchild that survives SIGTERM to it.
  `dshd stop` would report success while the harness kept holding its port. Children
  are now spawned as single external commands, and `lsof` in the suite holds the pid
  file to that claim.
- **The root refusal exited 1, not the documented 2.** The APK's health check
  distinguishes "not root" from every other failure, so the contract is now what the
  header says.
- **The firewall script got none of its inputs.** `dshd` read `DSH_APP_UID` and the
  ports from its own environment or a sourced `dshd.conf` and then ran
  `firewall.sh` as a separate process without exporting any of them: the log said
  "applying firewall rule (app uid: 10123)" while the script received nothing, which
  is how a §7 control ends up installed against the wrong UID or not at all. The
  values are exported now, and a test asserts what the script is handed.

## Corrections to the plan found while implementing

- **§7 item 1 is imprecise, and the conclusion is unchanged.** The API and upgrade
  surface is not entirely unguarded: `packages/bundle/web-app/cordis.patch.yml:225-236`
  wires a `trustedHosts` policy (loopback-derived host literals) into
  `@deepseek-ai/dsh-client-connection`, which every `/api` request and upgrade passes.
  That is a **host allowlist, not authentication** — a co-resident app sends
  `Host: 127.0.0.1:3080` and satisfies it — so "any app on the device can drive a root
  shell" stands. The guard must therefore rewrite `Host` and `Origin` to the harness
  authority when forwarding, or it would trip this policy on the new port.
- The webserver's `host` config accepts exactly `127.0.0.1` or `0.0.0.0`
  (`packages/host/webserver/src/index.ts:61`), so "loopback only" is enforceable by
  config. Port `0` means OS-assigned; the guard must be told the real port, which is
  why `dshd` pins an explicit port rather than letting the OS choose.

## Upstream relationship

Upstream is a developer preview with announced compatibility-breaking changes. The
fork at `Niguyonan/deepseek-harness` stays a **read-only mirror** (D4) — every
assumption about plugin names, preset wiring, bundle rows, and config keys in this
repo is version-pinned, not durable.
