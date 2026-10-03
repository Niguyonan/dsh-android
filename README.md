# dsh-android — DeepSeek Harness on rooted Android

Implementation of [`PORTING-PLAN.md`](./PORTING-PLAN.md): run the upstream DeepSeek
Harness (`dsh`) on a rooted `aarch64` Android device as an app-like experience.

**Runtime strategy (D1):** a glibc Linux rootfs inside a real `chroot`, orchestrated
from a root shell. Upstream's stock `linux-arm64` artifacts are valid verbatim inside
that rootfs, so there is **no native code to rebuild and no fork to maintain**.

## Architecture

```
┌─ Magisk / root shell ────────────────────────────────────────────────────┐
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

## Layout

| Path | Phase | What it is |
|---|---|---|
| `bin/dshd` | 1, 4 | The on-device entry point: chroot/mount wrapper *plus* supervisor. POSIX `sh`, runs under Magisk's `mksh`. |
| `tools/probe.sh` | 0 | Device feasibility probes → the P0 ledger (kernel, Landlock, `noexec`, SELinux, PTY, `xt_owner`). |
| `tools/rootfs-setup.sh` | 1 | Fetch + unpack the glibc arm64 rootfs, skeleton dirs, DNS, glibc Node. |
| `tools/install-harness.sh` | 2 | Install `@deepseek-ai/dsh` at a pinned version inside the rootfs. |
| `tools/confinement-check.sh` | 3 | Decide and **prove** the confinement posture (Landlock denied-write, or disclosed fallback). |
| `tools/firewall.sh` | §7 | Apply/remove/status the UID-owner rule that keeps other apps off both ports. |
| `tools/backup.sh` | 6 | Deliberate backup of `DSH_HOME` (sessions *and* credentials). |
| `tools/update.sh` | 6 | Version bump with smoke test and a known-good version kept for rollback. |
| `tools/rollback.sh` | 6 | Revert to the previous pinned version. |
| `tools/doctor.sh` | 6 | One-shot health snapshot: probes, posture, versions, mounts, ports. |
| `guard/guard.mjs` | §7 | The token guard. Zero dependencies, Node built-ins only. |
| `magisk/service.d/dshd.sh` | 4 | Optional boot-time autostart (opt-in; the APK owns lifecycle by default). |
| `android/` | 5 | The WebView APK: viewer plus lifecycle owner, no harness logic. |
| `docs/` | — | Probe ledger template, security design + proof procedure, runbook. |
| `tests/` | — | Host-side tests for `dshd` and the guard. |

## Quick start

Host-side checks (any machine with Node and `sh`):

```sh
tests/run.sh                 # exercises dshd's lifecycle logic + the guard
```

On the device, from a root shell, in order — **do not skip a gate**:

```sh
sh /data/local/dsh/tools/probe.sh              # P0: fill docs/phase-0-probe-ledger.md
sh /data/local/dsh/tools/rootfs-setup.sh       # P1: node -v inside the chroot reports glibc
sh /data/local/dsh/tools/install-harness.sh    # P2: full agent round-trip
sh /data/local/dsh/tools/confinement-check.sh  # P3: posture proven, not assumed
sh /data/local/dsh/bin/dshd start              # P4: supervisor
sh /data/local/dsh/tools/firewall.sh apply     # §7: other app UIDs rejected
```

Then install the APK, which starts, fronts, and stops all of the above.

## Status — what is verified here, and what only a device can answer

This repository is a macOS-development-host implementation of a device-targeted plan.
Being explicit about the split is part of the design (§10 of the plan).

**Verified on this host:** the guard's authentication, Host/Origin, loopback-bind and
proxying behaviour, including WebSocket upgrades; `dshd`'s lifecycle logic
(idempotent start, stale-PID cleanup, backoff, log rotation, status) driven through
its dry-run path; shell syntax of every script.

**Untestable off-device, and therefore still open:** every kernel-level question —
Landlock availability, unprivileged user namespaces, `noexec` on `/data`, SELinux
policy for `mount` from a `su` context, `xt_owner` for the firewall rule, and whether
`node-pty` allocates a PTY under the Android kernel in a chroot. Those need
`tools/probe.sh` on the actual hardware and are tracked in
[`docs/phase-0-probe-ledger.md`](./docs/phase-0-probe-ledger.md).

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
