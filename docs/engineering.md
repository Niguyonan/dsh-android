# Engineering notes

How this port works, what has been verified, and what has not. This is the
implementation record — [`README.md`](../README.md) is the product: what the app
does and how to install it.

It is the implementation of a porting plan that is not part of this repository:
run the upstream DeepSeek Harness (`dsh`) on a rooted `aarch64` Android device as
an app-like experience. The plan's section numbers survive in this code as names
for decisions -- "the §7 control" is the guard and the firewall rule -- because
that is how everyone involved refers to them.

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
│    su -c '… tar -xf - … && exec sh …/bootstrap.sh --from "$S" setup …'    │
│  with payload.tar on stdin: the tar fills the stage, the bootstrap        │
│  verifies every file in it by digest, installs it, then hands over to     │
│  `dshd setup`, whose `##dshd` lines are the protocol the app renders.     │
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
  [`docs/security.md`](security.md).
- **`/dev/pts` is a separate filesystem.** Binding `/proc` alone does not provide it,
  and every PTY allocation fails without it — silently costing the terminal.
- **The root solution is not a detail.** Magisk patches the ramdisk, KernelSU and
  KernelSU-Next patch the kernel, and the three differ in the `su` binary's path, the
  SELinux domain `su` runs in, and whether a *new* root session sees mounts made by
  this one. `dshd root` reports what it found; [`docs/root-solutions.md`](root-solutions.md)
  records the differences and what must be probed rather than assumed.
- **The app is a root client, and is built like one.** It reads its payload from
  its own APK and streams it into `su` rather than having root read app-private
  files, because SELinux's answer to that differs per root solution while a pipe
  does not. It sends nothing to a shell but constants and its own uid, never keeps
  a root shell open, and hands no JavaScript bridge to the page it renders — that
  page is agent output. [`docs/security.md`](security.md) has the list,
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
| `android/payload/bootstrap.sh` | 5 | The first thing of ours that runs on a device: refuses a non-root shell (exit 2), makes the install directory safe (0700, or exit 7 with the reason), verifies every file by digest, installs by rename into directories nobody else can write, then execs `dshd`. |
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
[`docs/phase-0-probe-ledger.md`](phase-0-probe-ledger.md) in from it before
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
install directory cannot be made safe (exit 7: another uid's directory, a symlink,
or a mode that stays open — while a root-owned mode it *can* close is closed and
reported rather than refused); and that `Protocol.java`, which is
plain Java on purpose, renders the real `dshd`'s output correctly, including
refusing a run that says `done ok` and then exits non-zero.

**What still needs a device, for the app specifically:** what Magisk's and
KernelSU's root prompts look like and how they answer a refusal (KernelSU-Next's
was answered on a Xiaomi/HyperOS device running Android 16, and it *does* forward
stdin to `su -c` — the payload arrives that way, which the hand-over above now
depends on rather than assumes), whether the WebView's cookie store survives the
way the guard's login needs it to, and whether a detached `setsid` supervisor
outlives both the app being swiped away and a force-stop. Those are Gate P4/P5
rows, and [`docs/runbook.md`](runbook.md) is the procedure — including the list of
everything in this stack that has never been executed on real hardware.

**Root solutions:** the stack is written against uid 0 plus a working `su` rather
than against Magisk. `dshd root` and `probe.sh` detect Magisk, KernelSU and
KernelSU-Next (they share `/data/adb/ksu` and `/data/adb/ksud`, so they differ only
by version string and manager package), report the SELinux domain actually in use,
and resolve `su` across all five places it lives. What differs per solution — and
what therefore has to be probed on your device — is in
[`docs/root-solutions.md`](root-solutions.md).

**Untestable off-device, and therefore still open:** every kernel-level question —
Landlock availability, unprivileged user namespaces, `noexec` on `/data`, SELinux
policy for `mount` from a `su` context, `xt_owner` for the firewall rule, and whether
`node-pty` allocates a PTY under the Android kernel in a chroot. Those need
`tools/probe.sh` on the actual hardware and are tracked in
[`docs/phase-0-probe-ledger.md`](phase-0-probe-ledger.md).

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
- **The fixed mtime was only fixed in one timezone, and `touch -t` reads local
  time.** Found by comparing the payload inside the *released* 0.1.1 APK — built on
  a UTC runner — against a build of the same commit on this machine: the first
  difference was at byte 104, the mtime field of the first header. `payload.id` is
  a hash of the manifest body and not of the tar bytes, so it matched; the
  reproducibility check in the suite builds twice on one host, where the timezone
  cancels out, so it matched as well. The touch pass is `TZ=UTC0 touch -t
  200001010000` now, and the suite checks both directions: two builds under
  `TZ=UTC-14` and `TZ=UTC+12` must be byte-identical, and the mtime field of the
  first header must read `07033241600` (2000-01-01T00:00:00Z) — stated as bytes,
  because "the two builds agree" is also what a wrong-but-consistent mtime looks
  like.
- **What the archive bytes still depend on, measured rather than assumed.** The
  same tree built by macOS `tar` and by GNU `tar` produces different *bytes*, in
  three ways: bsdtar terminates a numeric header field with a space where GNU tar
  zero-pads and terminates with NUL (`000755 \0` against `0000755\0`, and the
  mode, uid, gid, size and mtime fields are all encoded that way); directory
  members come out in the filesystem's readdir order, which no argument to this
  script controls, and the two archives listed the five `tools/` members in
  different orders; and GNU tar pads to its 20-record blocking factor, so the same
  content weighed 215040 bytes against 213504. `tools/mkpayload.sh`'s header used
  to promise that "two builds of the same tree produce the same bytes" while
  another paragraph of the same header warned about member order, and the
  measurement settled it. What *is* host-independent is `payload.id` and the
  manifest body it hashes — whose order is the list in `tools/mkpayload.sh`, a
  literal, and not the filesystem's — along with every per-file digest the
  bootstrap verifies before installing anything. So the released artifact is
  checked by id and by per-file digest against a build of the same commit, and "the APK carries exactly the
  payload in the working tree" is a claim the suite can only make about one host.
  Making the bytes identical everywhere means writing ustar headers here by hand,
  which is not worth doing in the one script whose output decides what root
  installs.
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
- **The mode check read its own arithmetic in the wrong base.** The entry above
  fixed the directory the app had created and shipped a bootstrap that closes a
  mode it can close — and the same screen came back from a phone with the
  opposite sentence: `/data/local/dsh is mode 700 and the group or other write
  bits could not be closed on it`, over a directory that had no write bits to
  close. The mode tests were `$((mode & 022))`, and what a number with a leading
  zero *means* is the shell's decision, not the script's: 448 to dash and bash,
  700 to the sh Android runs — mksh's, or toybox sh's, depending on the device —
  whose arithmetic reads it as decimal. `0700 & 022` is 0 under the first and 20
  under the second, and 20 is nonzero, so *every* existing install directory was
  refused, including the 0700 one the app had just created correctly. The
  documented recovery could not work either: `rm -rf /data/local/dsh` followed by
  **Set up** recreated it 0700, and it was refused again. The suite ran its mode
  cases under this host's `sh`, where the script's arithmetic happens to agree
  with the shell's, so nothing here could fail. The mode is now handled as digits
  rather than as a number, the cases also run under a shell that reads leading
  zeros as decimal — asked rather than assumed, since macOS's `/bin/ksh` answers
  448 — and a lint keeps a leading-zero literal out of anything the shell
  computes, on every host. Reading a manifest line into a variable named `path`
  was the same class of trap one step away: zsh and ksh93 tie `path` to `PATH`, so
  the digest step reported that the device had no `sha256sum` at all. Android's sh
  does not tie them (checked on the device), and the variable is `file` now.
- **Two readers, one stream.** The app's command extracts the payload into
  `/data/local/dsh/.stage` — it has to, because the thing it runs next is
  `bootstrap.sh` inside that archive — and the bootstrap, given no other source,
  extracted the payload *again* from its own stdin. There is one payload stream
  and `tar` reads it to the end, so the second extraction read an empty pipe:
  `tar: Not tar`, "the payload did not extract", exit 6, `fail payload`. Every
  host test drove the bootstrap with the archive on stdin — the flow that works —
  and nothing drove the command the app actually sends, so this waited for the
  first device run that got past the install directory. It needed to *get* past
  it, which is the entry above, which is why the two arrived together. The app now
  passes `--from "$S"`, the bootstrap verifies that stage like any other source
  (nothing is trusted for having been unpacked by the app), and the suite runs the
  app's command in the app's order — tar first, payload on the stdin of the whole
  pipeline, `--from` omitted afterwards as the failure it is. On the device this
  also answered a question this file had left open: KernelSU-Next does forward
  stdin to `su -c`, since the first `tar` received all 215 KB of the payload and
  ran `bootstrap.sh` out of it.
- **A query was judged by the rule for an install.** With the hand-over fixed, the
  phone's payload installed — `9 files verified, 9 updated` — and its screen then
  said "Setup stopped — the setup stopped without saying why (exit 3)". The app
  judges a run by two signals, `done ok` and exit 0, which is right for `setup`:
  it is the only verb that says `done ok`. `dshd setup --check` is a *query* — it
  reports what is installed and what is running on its `info` lines, and exits 3,
  "not running", when the answer is that nothing is set up yet. Judged as an
  install, every answer it can give reads as a failure: a fresh device showed the
  sentence above above a header that already said "Not set up", and a healthy
  device, whose check exits 0, showed it with a 0 in it. Success for `check` is
  now "the device answered" — an `info` line, no named failing step, and the
  query's own 0 or 3 — and it is deliberately narrow: a check that named a failed
  step, could not run for lack of root, or answered nothing is still a failure.
  The cases are driven with the bytes the phone actually wrote.
- **The file name discovery returned its own log line.** With the check screen
  honest, `SET UP` ran and stopped at *Installing the Linux system* with exit 4:
  `curl: (3) URL rejected: Malformed input to a URL function`, then BusyBox
  `wget: server returned error: HTTP/1.1 400 Bad Request`, then "cannot download
  https://…/release/". The step blamed the network, and the network was fine. The
  URL being fetched was

      https://…/release/2026-10-04T12:31:11+0800 rootfs-setup: fetching https://…/release/
      ubuntu-base-24.04.5-base-arm64.tar.gz

  — a URL with a timestamp and a newline in it, because `discover_base_file`
  returns a file name on stdout, the caller captures stdout with `$( )`, and
  `fetch` logs the URL it is about to read on stdout too. One `>&2` fixes it, and
  the reason is written where the next person will look. No test had ever run
  discovery: every case in `tests/rootfs-setup.test.sh` handed the script a local
  tarball with `--base-file`, so the one path that reads a listing — the path a
  device takes — was unexercised. It has a case now, with the network stubbed by a
  `curl` that answers by destination and a listing that puts the *lexically*
  smaller point release first, so "newest" cannot be an accident of order.
- **A presence check that failed when *either* path was absent.** With the base
  image installed, the harness step stopped at exit 3 with

      install-harness: WARNING: missing: libstdc++.so.6 — the eager native load on the boot path needs it
      install-harness: installing libstdc++6 from the distro
      libstdc++6 is already the newest version (14.2.0-4ubuntu2~24.04.1).
      install-harness: ERROR: libstdc++6 still does not resolve after installing it

  The check was `ls /usr/lib/*/libstdc++.so.6* /usr/lib/libstdc++.so.6* >/dev/null
  2>&1`, and `ls` exits non-zero when *any* operand is missing: on the Ubuntu
  base a device installs, the library lives only under the multiarch triplet the
  first pattern covers, so ls listed the file and failed on the second pattern
  anyway. A rootfs that had the library was told it did not resolve, and apt — run
  because of that — answered that it was already installed. Each pattern is asked
  about on its own now, and from *outside* the chroot (`"$DSH_ROOTFS"/usr/lib/…`),
  which is also what makes it testable: a pattern a shell inside the chroot
  expands is a pattern no host-side test can arrange. That untestability is the
  second half of this entry — every case in `tests/install-harness.test.sh` passed
  `--skip-libs`, so `check_libs` had never run anywhere, and the new case runs it
  in both directions: the library under the triplet (found), and no library at all
  (still refused).
- **A second `SET UP` failed on its own successful install.** With the harness
  installed and running — `install-harness.sh` had put 0.2.0-rc.2 in the rootfs —
  re-running setup stopped at *Installing the harness* with exit 5:
  "the harness is already installed in this rootfs (version 0.2.0-rc.2). Re-run
  with `--force`". The refusal itself is deliberate (a working install is not
  clobbered without being asked), but it was fatal for *any* installed version,
  including the pin, and the rootfs step one screen earlier skips in exactly that
  case: one run reported "skip" for the base and "fail" for the harness, over the
  same state. Preflight now tells the two cases apart — the pinned version already
  present means nothing to install, a *different* version present is still a
  refusal — and the install and the manifest are skipped while verification and
  the smoke test still run, which is what makes skipping them honest. The suite
  covers both versions of the case.
- **The screen offered START for a device that was half installed.** `dshd setup
  --check` reports `installed` (rootfs and Node) and `harness` (the harness's own
  `dsh`) separately, because a run can leave the first and not the second: the
  device above answered `installed yes`, `harness no`. Keyed on `installed` alone,
  the app said "the harness is installed but not running" and offered START —
  which refused, correctly, with "harness not installed at
  …/usr/local/bin/dsh". Ready is now both halves, in the status line, the panel,
  both buttons and the autostart toggle. The refusal was right; the button was not.
- **The debug build could not be installed over the previous one.** `android/build.sh`
  wipes `$BUILD` at the start of every build, and the debug keystore it generates
  lived inside it — so every build signed with a new key, and installing the
  result over the last one failed with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: an
  uninstall, the app's preferences, and the root grant asked for again. Found by
  rebuilding to verify a fix on a phone, which is the only place the cost lands on
  a person. The keystore now lives beside the build directory (`android/.debug.keystore`,
  already gitignored), a keystore left inside an old build directory is adopted
  rather than orphaned, and a case in `tests/apk.test.sh` builds twice and compares
  the certificates.

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
