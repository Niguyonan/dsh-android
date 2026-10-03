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
│    .stage/       the APK's payload, extracted and verified before install  │
│    payload.sha256   the manifest: mode, digest and path per file          │
│    bin/dshd      setup|start|stop|restart|status|token|url|logs|mounts|   │
│                  boot|doctor                                              │
│    guard/guard.mjs   token-auth loopback guard (§7)                       │
│    log/          dshd.log, harness.log, guard.log, setup.log (+ rotated)  │
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
┌─ WebView APK (android/) ─────────────────────────────────────────────────┐
│  Does all of the above. There is no terminal step and no script to run by │
│  hand: one root command per action, and never a shell left open.          │
│    su -c '… tar -xf - … && exec sh …/bootstrap.sh setup --app-uid N'      │
│  with payload.tar on stdin: bootstrap.sh verifies every file by digest,   │
│  installs it, then hands over to `dshd setup`, which streams the ##dshd   │
│  progress protocol the app renders.                                       │
│  Activity: WebView → http://127.0.0.1:3081, navigable nowhere else        │
│  Foreground service: for the length of a run, because a 1 GB download     │
│  must survive the user switching apps. The server itself is a detached    │
│  root process: no app process, no wakelock, no notification needed.       │
└──────────────────────────────────────────────────────────────────────────┘
```

Four things the diagram is load-bearing for. The first two are §7 of the plan:

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
- **The app is a root client, and is built like one.** It reads its payload from
  its own APK and streams it into `su` rather than having root read app-private
  files, because SELinux's answer to that differs per root solution while a pipe
  does not. It sends nothing to a shell but constants and its own uid, never keeps
  a root shell open, and hands no JavaScript bridge to the page it renders — that
  page is agent output. [`docs/security.md`](./docs/security.md) has the list,
  including what the app deliberately does *not* protect against.

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
| `tools/confinement-check.sh` | 3 | Phase 3, decided rather than assumed: runs the harness's *own* `landlock-run --probe`, then proves a denied write with a two-sided control, then writes the pin and the sentence the app shows. |
| `android/build.sh` | 5 | Builds the APK with the SDK's own tools — aapt2, javac, d8, zipalign, apksigner — and refuses to report a build that does not verify. No Gradle, no AndroidX, no dependency resolution. |
| `android/src/dev/dshd/app/` | 5 | The app: `MainActivity` (setup screen, then the WebView), `SetupService` (foreground for the length of a run), `Shell` (the one `su` command and the payload pipe), `RunState` (worker thread → UI, coalesced), `Protocol` (the `##dshd` parser — the one part a host can decide). |
| `android/payload/bootstrap.sh` | 5 | The first thing of ours that runs on a device: refuses a non-root shell or an install directory another uid could write, verifies every file by digest, installs by rename, then execs `dshd`. |
| `tools/mkpayload.sh` | 5 | Builds `android/assets/payload.tar` and `payload.id` from the working tree, reproducibly, and refuses to write an archive whose members are not exactly the manifested files. |
| `boot/service.d/dshd.sh` | 4 | Opt-in boot autostart, installed at `/data/adb/service.d` — the path all three root solutions run. |
| `docs/security.md` | §7 | The exposure, the two controls, and the on-device procedure that proves a second app is blocked. |
| `docs/runbook.md` | 4, 5 | The device procedure: install, grant root, the seven steps and what each one costs, the P0–P5 gates with their pass conditions, proving both §7 controls by hand, troubleshooting by symptom, recovery — and the list of what has never been run. |
| `docs/root-solutions.md` | — | Magisk vs KernelSU vs KernelSU-Next: detection, `su`, SELinux domains, boot scripts, mount namespaces. |
| `docs/phase-0-probe-ledger.md` | 0 | The P0 template to fill in on the device, including the root-solution rows. |
| `tests/run.sh` | — | Host-side entry point: the ten suites below, and the only place a suite is registered. |
| `tests/docs.test.sh` | — | The documentation's checkable claims: every script and verb it names exists, every path in the layout table exists, and every suite in `tests/` is one that runs. |
| `tests/dshd.test.sh` | — | `dshd`'s lifecycle without a device or root: exit codes, posture, rotation, firewall handover, supervisor pair semantics. |
| `tests/firewall.test.sh` | §7 | The rule set against a fake iptables: apply, verify, tamper detection, removal, idempotence. |
| `tests/probe.test.sh` | 0 | `probe.sh`'s contract and verdicts with the device stubbed: it must fail loudly on a host, never quietly. |
| `tests/rootfs-setup.test.sh` | 1 | `rootfs-setup.sh` with local tarballs instead of downloads: extraction, checksums, refusal to clobber, re-run paths. |
| `tests/install-harness.test.sh` | 2 | `install-harness.sh` with the registry and chroot stubbed, including the negative controls: an open harness and a wild bind must both fail the smoke test. |
| `tests/setup.test.sh` | 5 | `dshd setup`: step order and failure propagation, skip-not-repeat, the protocol the app renders, the inputs it refuses, and the two failures the plan calls survivable. |
| `tests/payload.test.sh` | 5 | The payload pipeline: what cannot get into the archive root installs, and what a truncated transfer, a tampered file, a squattable install directory or a missing sha256 do. |
| `tests/apk.test.sh` | 5 | The APK: signed and verified, its permissions and cleartext policy, the payload inside it compared byte for byte with the tree, and `Protocol.java` driven with the real `dshd`'s output. Skips loudly without a JDK and an SDK. |

**Not written yet** — named so that what follows reads as a plan rather than a
description: `tools/backup.sh`, `tools/update.sh`, `tools/rollback.sh` and
`tools/doctor.sh` (all Phase 6).

## Quick start

Host-side checks (any machine with Node and `sh`; the APK suite also wants a JDK
and an Android SDK, and skips itself loudly without them):

```sh
tests/run.sh                 # ten suites: docs, guard, §7 rule set, probes,
                             # rootfs, harness install, payload, setup, APK, dshd
```

**On a phone or tablet, the APK is the whole story.** Build it, install it, open
it, and grant it root when your root manager asks:

```sh
sh android/build.sh                              # → android/.build/dshd-0.1.0.apk
adb install -r android/.build/dshd-0.1.0.apk
```

Then tap **Set up**. There is no terminal step and no script to run by hand: the
app checks the device, downloads the Linux base, installs the harness, checks the
sandbox, locks the ports to itself, writes the config, and starts the server,
showing each step as it happens. It is the sequence below, run for you, and every
step is the same script.

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

That is the reference path — what the app runs, one script per step, and what to
reach for when a device will not cooperate or when the APK cannot be installed.
The firewall rule goes on **before** the supervisor, not after: it is what keeps
other apps away from the ports the supervisor is about to open. Setting
`DSH_FIREWALL=on` in `etc/dshd.conf` makes `dshd` re-apply it on every start, so
it survives reboots; `docs/security.md` has the procedure that proves it works.

`dshd setup --app-uid <uid>` does the same seven steps in one command and prints
a `##dshd` progress protocol on stdout; that is exactly what the app runs, and
what `tests/setup.test.sh` holds to account. `dshd setup --check` reports what is
installed and what is running, in the same protocol.

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

**Verified for the APK, without a phone:** that `android/build.sh` produces a
signed APK which `apksigner` verifies, with the permissions, exported components
and loopback-only cleartext policy the manifest claims; that the payload inside
the APK is byte-for-byte the payload this tree builds, on a build that is
reproducible in the first place; that the path the app hands to `su` exists in
the payload the app ships, and that every verb it can send is one `dshd`
dispatches — both derived from the two sides rather than listed; that the
bootstrap installs nothing when a file does not match the manifest, when the
transfer is truncated, when it cannot compute a digest at all, or when the
install directory is writable by another uid; and that `Protocol.java`, which is
plain Java on purpose, renders the real `dshd`'s output correctly, including
refusing a run that says `done ok` and then exits non-zero.

**What still needs a device, for the app specifically:** whether Magisk,
KernelSU and KernelSU-Next forward stdin to `su -c` (the payload arrives that
way), what their root prompts look like and how they answer a refusal, whether
the WebView's cookie store survives the way the guard's login needs it to, and
whether a detached `setsid` supervisor outlives both the app being swiped away
and a force-stop. Those are Gate P4/P5 rows, and
[`docs/runbook.md`](./docs/runbook.md) is the procedure — including the list of
everything in this stack that has never been executed on real hardware.

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
- **The payload's own manifest was read as a list of files.** Reading a manifest
  line into `mode`, `digest` and `path` puts the `#` of a comment line in *mode*,
  so a check that tested `path` for a leading `#` let every header line through,
  and the bootstrap went looking for a file named after the rest of the
  sentence. It failed loudly, which is the only reason it took one run to find.
- **`verify_payload` was called in a command substitution.** A function that
  calls `exit` inside `$( )` exits the subshell: the digest mismatch would have
  printed, and the install would have carried on with the file it had just
  rejected. Both `verify_payload` and `install_payload` report through variables
  now, and the bootstrap's header says why.
- **An empty digest compared equal to a blank manifest field.** A `sha256sum`
  that exists and fails (a broken symlink, a function from the environment)
  produced `""`, and `""` is a perfectly good thing to compare against nothing.
  Every hashing helper in the payload and the builder now fails when it cannot
  produce a digest, and the bootstrap refuses to install unverified files.
- **The payload was not reproducible, twice over.** A build timestamp in the
  manifest meant two builds of the same tree produced different bytes, which
  quietly made "the APK ships the payload in this tree" unprovable. Removing it
  was not enough: the fixed-mtime pass ran `find -type f` before the manifest was
  written, so directory entries and the manifest's own header still carried the
  clock. A tar header stores whole seconds, so both bugs passed a
  same-second rebuild test — and then failed a byte-for-byte comparison a second
  later, in a different suite, roughly two runs in three. The archive is a
  function of the sources now, and `tests/payload.test.sh` rebuilds across a
  one-second gap on purpose, because that is the only version of this check that
  can fail.
- **`String.join` and `Process.waitFor(long, TimeUnit)` are API 26.** The app
  declares minSdk 24, so both are `NoSuchMethodError` crashes on an Android 7
  device and nothing on a laptop would notice. The bounded wait is hand-rolled,
  and the suite greps the sources for both.
- **macOS `tar` adds members nobody asked for.** The archive self-check caught
  this by refusing to write an archive with an extra member — and the first
  member it refused was `payload.sha256`, the one file that cannot appear in its
  own manifest. That is the check working: the exception is now one visible line
  rather than a hole in the comparison.
- **A test helper that matched nothing.** The new setup suite extracted step
  states with `sed 's/...\(ok\|skip\|fail\)...'`, and macOS `sed` has no
  alternation in basic regexes, so every one of those assertions was vacuous on
  the machine it was written on. It is `awk` now. A green check that cannot fail
  is the same failure this repository keeps recording, one level up.
- **The firewall script got none of its inputs.** `dshd` read `DSH_APP_UID` and the
  ports from its own environment or a sourced `dshd.conf` and then ran
  `firewall.sh` as a separate process without exporting any of them: the log said
  "applying firewall rule (app uid: 10123)" while the script received nothing, which
  is how a §7 control ends up installed against the wrong UID or not at all. The
  values are exported now, and a test asserts what the script is handed.
- **The app refused the install directory it had just created.** Found on a real
  device, which is the point of this entry: setup stopped, the screen said *the
  payload did not verify*, and the log said `/data/local/dsh is mode 0775: group
  or other writable`. Both halves were wrong, in different ways. The directory was
  0775 because the app's command created it with `mkdir -p` under whatever umask
  the `su` shell was started with — the mode check was correct and the *creation*
  was the bug. And "the payload did not verify" was the app's summary for exit 6,
  a code the bootstrap used for every refusal it could make, consulted *before* it
  looked at whether the script had named the check that refused (it had not: the
  bootstrap printed its refusals to the log and not on the protocol). So: the app
  now creates the directory with `(umask 077; mkdir -p "$S")`, the bootstrap closes
  a root-owned mode it can close and reports the before and after instead of
  refusing, `chmod`'s exit status is not trusted (the mode is read back, and a
  directory still writable by somebody else is fatal), a symlinked install
  directory is refused rather than followed, a refusal carries its own exit code
  (7, "the install directory is not safe", with 6 left meaning the payload did not
  verify and nothing else), every refusal is emitted as `fail <step> <reason>` on
  the protocol, and the app renders a named check before it renders a code. The
  mode cases in `tests/payload.test.sh` use the real filesystem with only `id` and
  the owner stubbed — a stubbed `stat` would have agreed with whatever the script
  believed, which is exactly how this reached a phone.

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
