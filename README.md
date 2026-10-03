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

Everything in this table exists and is exercised by `tests/run.sh`.

| Path | Phase | What it is |
|---|---|---|
| `bin/dshd` | 1, 4 | The on-device entry point: chroot/mount wrapper *plus* supervisor. POSIX `sh`, runs under Magisk's `mksh`. |
| `guard/guard.mjs` | §7 | The token guard. Zero dependencies, Node built-ins only. |
| `guard/test/guard.test.mjs` | §7 | Proves the guard's controls rather than asserting them: auth, Host/Origin, bind refusal, upgrade teardown. |
| `tools/firewall.sh` | §7 | The reachability half of the mitigation: a UID-owner rule set that keeps every other app off both ports, self-verified after apply. |
| `docs/security.md` | §7 | The exposure, the two controls, and the on-device procedure that proves a second app is blocked. |
| `tests/run.sh` | — | Host-side entry point: the guard suite, the firewall suite, then `dshd`'s lifecycle suite. |
| `tests/dshd.test.sh` | — | `dshd`'s lifecycle without a device or root: exit codes, posture, rotation, firewall handover, supervisor pair semantics. |
| `tests/firewall.test.sh` | §7 | The rule set against a fake iptables: apply, verify, tamper detection, removal, idempotence. |

**Not written yet** — named so that the quick start below reads as a plan rather
than a description: `tools/probe.sh` (Phase 0), `tools/rootfs-setup.sh` (1),
`tools/install-harness.sh` (2), `tools/confinement-check.sh` (3),
`magisk/service.d/dshd.sh` (4), `android/` (5), `tools/backup.sh`,
`tools/update.sh`, `tools/rollback.sh`, `tools/doctor.sh` (6),
`docs/phase-0-probe-ledger.md` and `docs/runbook.md`.

## Quick start

Host-side checks (any machine with Node and `sh`):

```sh
tests/run.sh                 # the guard, the §7 rule set, and dshd's lifecycle
```

On the device, from a root shell, in order — **do not skip a gate**:

```sh
sh /data/local/dsh/tools/probe.sh              # P0: fill docs/phase-0-probe-ledger.md
sh /data/local/dsh/tools/rootfs-setup.sh       # P1: node -v inside the chroot reports glibc
sh /data/local/dsh/tools/install-harness.sh    # P2: full agent round-trip
sh /data/local/dsh/tools/confinement-check.sh  # P3: posture proven, not assumed
sh /data/local/dsh/tools/firewall.sh apply --uid <APP_UID>   # §7: other app UIDs rejected
sh /data/local/dsh/bin/dshd start              # P4: supervisor
```

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
fails loudly instead of reporting success. `tests/run.sh` runs all of it.

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
