# Porting DeepSeek Harness (`dsh`) to rooted Android

Planning artifact only. **No implementation is included or implied by this document.**

- Upstream: `https://github.com/deepseek-ai/deepseek-harness` (MIT)
- Inspected revision: `0.2.1-alpha.1` (root `package.json`), cloned to a scratch directory for analysis
- Target: rooted `aarch64` Android device, single-user, "app-like" launch experience

---

## 1. Decision record

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Runtime strategy | **glibc Linux rootfs inside a real `chroot`**, orchestrated from a root shell | Android ships `bionic`; the harness's native layer has glibc/musl prebuilts only. A `chroot` makes the stock `linux-arm64` artifacts valid verbatim, so there is **no native code to rebuild and no fork to maintain**. Root already grants real `chroot` — no `proot` needed. |
| D2 | End-user surface | **Dedicated WebView APK** with app icon, foreground service, partial wakelock | Selected by the user. The harness UI is already a browser client, so the APK is a shell around `http://127.0.0.1:3080` plus lifecycle ownership. |
| D3 | Confinement | **Prefer Landlock; fall back to `danger-full-access`** | The upstream Linux chain (`bwrap` → Landlock) fails closed with `SANDBOX_UNAVAILABLE`, so one of the two must work. On a rooted single-user device the sandbox is a guardrail against agent mistakes, not a security boundary against other users. |
| D4 | Upstream relationship | **Vendor a pinned release; do not fork** | MIT permits it, and upstream is a *developer preview* with announced compatibility-breaking changes. A fork would rot immediately. Thicken the boundary with our own wrapper/config instead. |
| D5 | Distribution | Ship the runtime as files under `/data/local/dsh`, APK as a thin frontend | Keeps the Node runtime, rootfs, and credentials outside the APK, so the frontend can be reinstalled or updated independently of the harness. |

### Explicitly rejected

- **Termux-native `bionic` build.** Requires rebuilding the Node-API addon and `node-pty` for Android, plus inventing a third libc branch, in exchange for roughly 100 MB of footprint. Permanently diverged native layer; highest maintenance cost per unit of benefit.
- **APK with embedded Node (`nodejs-mobile`).** Best theoretical UX, but the harness requires `engines: ^22.19.0 || >=24.0.0` and `nodejs-mobile` trails that badly. Would require self-building Node for Android first — a prerequisite project, not a port.
- **Bare Termux install with no `chroot`.** Looks cheapest, but lands directly on the native-layer wall in §2 and ends up as the rejected `bionic` option by another name.

---

## 2. Why there is no cheap "real" port

The harness is a Node.js/pnpm monorepo whose UI is a local web server. That is the good news: **no UI porting is required.** Everything hard is confined to the native layer and the process model.

Platform-specific surface, in descending order of pain:

1. **`native/system` (`@deepseek-ai/node-addon-system`)** — the hard blocker. `native/system/docs/support-matrix.md` publishes packages for **`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64` only**, and states: *"Other CPU/OS combinations have no published platform package: Landlock probes unusable, and flock acquisition rejects. New platform support requires a native builder and installed-artifact verification."* Each Linux package carries `bin/glibc/system.node` + `bin/musl/system.node` (Node-API 8) and a static-musl `landlock-run` executable. None of these load against `bionic`.
2. **`packages/sandbox/sandbox-local`** — platform runner chain is **`bwrap` → Landlock** on Linux, Seatbelt on macOS, ACL tokens on Windows, and it **fails closed** rather than running unconfined. Android kernels commonly disable unprivileged user namespaces (which kills `bwrap`) and Landlock depends on `CONFIG_SECURITY_LANDLOCK`, which is not guaranteed on GKI builds. Two supported escape hatches exist: `danger-full-access` bypasses confinement entirely (`ConfinedSandboxMode` excludes it at the type level, so no runner is spawned), and `runnerCommand` substitutes a custom runner argv.
3. **`packages/subprocess/subprocess-local`** — mounted in the base bundle and declares `node-pty@1.2.0-beta.15` (patched in-repo) plus `koffi@3.1.1`. It resolves `node-pty` through `createLazyRequire`, so a PTY is only needed when a terminal feature is actually used.
4. **`packages/session/session-persistence-jsonl`** — contains platform-gated generation/lease code (`src/lease.ts`, `src/generation.ts`) that must be exercised explicitly during Phase 0. Whether it hard-requires the `flock` binding is the one claim this document deliberately does not assert; treat it as an open item (§7).
5. **`python/sdk-runtime/platforms.json`** — the single-exe SDK runtime is built for `manylinux_2_28_aarch64` / `macosx_*` / `win_amd64` via `@yao-pkg/pkg`. It is **glibc-linked**, so it cannot run on bare Android either — but it becomes usable for free under D1, since the rootfs is glibc.

D1 sidesteps 1, 4, 5 and most of 2 entirely, and reduces 3 to "does a PTY work under a chroot", which is a plain Linux question.

---

## 3. Target architecture

```
┌─ Magisk / root shell ────────────────────────────────────────────┐
│  /data/local/dsh/                                                │
│    rootfs/          Debian-or-Ubuntu arm64 rootfs (glibc)         │
│    workspace/       agent working directory (ext4, not FUSE)      │
│    state/           DSH_HOME: sessions, storages, creds, logs      │
│    bin/dshd         start|stop|status supervisor + log rotation    │
│    log/dshd.log                                                   │
└──────────────────────────────────────────────────────────────────┘
             │ chroot rootfs  (proc, dev, workspace, state bind-mounted)
             ▼
   node (glibc arm64)  →  dsh web --no-open  →  127.0.0.1:3080
             ▲
             │ HTTP on loopback only
┌─ WebView APK (the "app") ────────────────────────────────────────┐
│  Activity: WebView → http://127.0.0.1:3080                       │
│  Foreground service: owns server lifecycle + PARTIAL_WAKE_LOCK    │
│  Persistent notification: status, Restart, Stop, Quit             │
└──────────────────────────────────────────────────────────────────┘
```

**Lifecycle ownership is the crux of D2.** Android will reap the server the moment it stops being the user's point of attention; the foreground service — not the Activity — is what keeps it alive, and it must be able to *start* the server, not merely observe it.

---

## 4. Phased plan

Each phase ends in a gate. Do not start the next phase until the gate passes on the actual device.

### Phase 0 — Device feasibility probes (blocking)

Everything downstream branches on these answers. Run from a root shell and record raw output.

| Probe | Command | Why it matters |
|---|---|---|
| Kernel + arch | `uname -a`; `cat /proc/version` | Confirms `aarch64` and kernel generation |
| User namespaces | `cat /proc/sys/user/max_user_namespaces` | `0` ⇒ `bwrap` is dead; rules out runner rung 1 |
| Landlock | `grep -i landlock /proc/kallsyms \| head` and the `LANDLOCK_CREATE_RULESET_VERSION` probe (§7) | Decides D3: Landlock vs `danger-full-access` |
| Seccomp / `setpriv` | `command -v setpriv unshare` | Fallback confinement building blocks if you want more than D3's fallback |
| Filesystem for the workspace | `mount \| grep -E 'sdcard\|fuse\|ext4'` | `chroot` + Landlock over FUSE-backed `/sdcard` is where subtle breakage lives; prefer ext4 |
| Free space | `df -h /data` | Rootfs + Node + `pnpm` store is a few hundred MB before sessions |

**Gate P0:** a written table of probe results, and D3 resolved to a concrete choice.
**Abort condition:** if Landlock is unavailable *and* you are unwilling to run `danger-full-access`, stop and reconsider D1 — the `bionic` path would not fix this, since it has the same kernel.

### Phase 1 — glibc rootfs

1. Fetch an arm64 base rootfs (`ubuntu-base-*-base-arm64.tar.gz` or a Debian equivalent) that uses glibc. This is the whole point of D1 — do not reach for Alpine/musl here.
2. Extract under `/data/local/dsh/rootfs`; create the standard skeleton (`proc`, `sys`, `dev`, `tmp`, `workspace`, `state`).
3. Bind-mount `/proc`, `/dev`, the workspace, and the state directory. Set a working `/etc/resolv.conf` so `npm`/`pnpm` can reach the network.
4. Install a **glibc** Node inside the rootfs from the official `linux-arm64` tarball, satisfying `^22.19.0 || >=24.0.0`.
5. Write `bin/dshd` — `chroot` wrapper with the correct mounts, `PATH`, and `DSH_HOME` pointed at `state/`.

**Gate P1:** inside the chroot, `node -v` reports a supported version, `node -e "require('node:report').getReport().header"`-equivalent libc introspection identifies glibc, and the mounts survive a re-`chroot`.

### Phase 2 — Install and boot the harness

1. Install `@deepseek-ai/dsh` at a **pinned version** (D4) inside the rootfs.
2. Boot `dsh web --no-open` with `DSH_HOME=/data/local/dsh/state`.
3. Confirm the server binds `127.0.0.1:3080` and that a browser on the device renders the UI.
4. Configure credentials through the UI's Models page rather than inlining a key, and verify the managed credentials document lands in `DSH_HOME` (§6).
5. Note for Phase 3 that the base bundle reads `DSH_PERMISSION_MODE` (defaulting to `workspace-write`) and that `danger-full-access` also flips the approval policy to `never`.

**Gate P2:** a full agent round-trip — prompt in, a real file read/write in the workspace, result back — with the process surviving a detach/reattach cycle.
**Highest-risk unknown in this phase:** any native module resolved at startup. If boot fails on a missing addon, that is the §2 item 3/4 boundary being hit, and it belongs in Phase 0's ledger.

### Phase 3 — Confinement

1. If Landlock is available: keep the stock chain and verify that `workspace-write` actually **denies** a write outside the workspace — a sandbox that silently degrades to permissive is worse than no sandbox, because the model is told it is confined.
2. If Landlock is unavailable: pin `DSH_PERMISSION_MODE=danger-full-access` at the `dshd` level so the mode cannot drift per session, and document in the app UI that writes are unconfined.
3. If you want confinement *without* Landlock, this is where `runnerCommand` earns its keep — a wrapper enforcing the workspace boundary by other means. Treat as optional stretch, not part of the baseline.

**Gate P3:** demonstrate the chosen posture empirically — a denied write under Landlock, or an explicit "unconfined" notice in the UI under the fallback.

### Phase 4 — Launcher and lifecycle

1. Harden `dshd` into a supervisor: idempotent `start`, `stop`, `status`, restart-on-crash with backoff, log rotation, and stale-PID cleanup.
2. Decide the autostart mechanism: a Magisk `service.d` script for boot-time start, or service-initiated start from the APK. Prefer the APK owning it (D5) so the runtime's lifetime matches what the user sees in the notification.
3. Verify the server comes back cleanly after a force-stop, a reboot, and an OOM kill.

**Gate P4:** reboot the device, do nothing, and reach the UI. Then force-stop everything and reach it again.

### Phase 5 — WebView APK

Keep the APK resolutely dumb — a viewer plus a lifecycle owner. No harness logic in Java/Kotlin, so upstream changes never touch it.

- **Activity:** a `WebView` pointed at `http://127.0.0.1:3080`. Enable JavaScript and DOM storage; keep in-app navigation inside the WebView; handle the back button as history; render a first-run/error screen when the server is not up.
- **Cleartext:** loopback HTTP requires the manifest/network-security-config to permit cleartext for `127.0.0.1` specifically — not globally.
- **Foreground service:** a single service owning server start/stop, with a persistent notification exposing Restart/Stop, and a `PARTIAL_WAKE_LOCK` held only while the server is meant to be up.
- **Permissions:** notifications (needed for a visible foreground service on modern Android). Prompt for battery-optimization exemption, but treat a refusal as degraded rather than fatal.
- **Readiness:** poll the loopback port before navigating, so a cold start does not flash a connection error.
- **Binding:** bind loopback **only**. Never `0.0.0.0` — the harness executes shell commands, and a LAN-exposed agent surface is a remote-code-execution endpoint by design.

**Gate P5:** from a cold device, one tap on the app icon reaches a usable, already-authenticated UI, and the server is still alive after ten minutes in the background.

### Phase 6 — Hardening and updates

1. Pin the harness version and write an update procedure: bump inside the rootfs, smoke-test, keep the previous version for rollback.
2. Back up `DSH_HOME` deliberately — session logs and credentials both live there.
3. Add a "revert to known-good" path and a health check that the APK can surface.
4. Re-run the Phase 0 probe table after any kernel/ROM update, since Landlock availability is a kernel property, not a device property.

---

## 5. Traps worth pre-empting

- **`os`/`cpu` gating passes on Android — and that is a trap, not a win.** Android Node reports `process.platform === 'linux'` and `process.arch === 'arm64'`, so npm's `os`/`cpu` checks in `native/system/packages/linux-arm64/package.json` will happily install the package. Selection is not the problem; loading a glibc `system.node` into a bionic Node is. Under D1 both are glibc, so the coincidence becomes harmless.
- **libc detection has exactly two branches.** `native/system/scripts/build.ts` classifies a Linux host as `glibc` if `process.report` exposes `glibcVersionRuntime`, else `musl`. `bionic` is *neither*, so it silently falls through to `musl`. This is a concrete reason D1 beats the `bionic` path rather than a stylistic preference.
- **Lazy `node-pty` means a missing PTY may not fail at boot.** A green boot does not prove the terminal feature works. Exercise it explicitly, and decide up front whether a broken terminal is acceptable (probably yes for v1).
- **FUSE-backed `/sdcard` is not a good agent workspace.** Prefer an ext4 path and bind it in. Writes, permissions, `mmap`, and Landlock semantics over FUSE are all places to lose a weekend.
- **A silent sandbox downgrade is a correctness bug.** Upstream deliberately fails closed when no runner is usable; any wrapper that turns that into "run unconfined" must make the difference visible to the user.
- **Developer-preview churn.** Upstream has announced breaking changes. Every assumption here about plugin names, bundle rows, and config keys is version-pinned, not durable.
- **Loopback trust.** Confirm during Phase 2 whether the Web UI requires a token when bound to loopback, and whether any capability assumes the client is a trusted local browser.

---

## 6. Acceptance criteria

The port is done when **all** of the following hold:

1. Cold boot, no terminal interaction, one tap on the app icon → usable harness UI.
2. An agent completes a real multi-turn task with file edits landing in `/data/local/dsh/workspace`.
3. The server survives backgrounding for at least 30 minutes and recovers from a force-stop with no manual repair.
4. The confinement posture from D3 is observable and honest — enforced-and-demonstrated, or explicitly disclosed as absent.
5. Credentials live in `DSH_HOME`, never in an APK resource, a shell history, or a config file committed anywhere.
6. The server is reachable **only** on loopback.
7. The harness version is pinned, and a documented rollback to the previous version exists.

---

## 7. Open items to close in Phase 0

- Does `packages/session/session-persistence-jsonl` hard-require the `flock` binding, or degrade gracefully? Read `src/lease.ts` and `src/generation.ts` and run a session that forces a lease.
- Does a Landlock probe on the target kernel report `full`, `partial`, or `unusable`? Kernel version alone is explicitly *not* a reliable signal per the upstream support matrix — use a functional probe.
- Does the device's `/data` mount support the durability assumptions the session log makes (append + `fsync` semantics), and does anything in the persistence path assume a desktop-style filesystem?
- Does the Web UI require a token or origin check when bound to loopback?
- Which `bwrap`-independent confinement options the kernel actually offers (`setpriv`, `unshare`, UID separation), in case Landlock is unusable and `danger-full-access` is judged too loose.

---

## 8. Effort sketch

| Phase | Character of the work | Dominant cost |
|---|---|---|
| 0 | Probes and reading | Device access; ambiguity in kernel answers |
| 1 | Rootfs assembly, mounts, `chroot` wrapper | Bind-mount and DNS fiddliness |
| 2 | Install, boot, first real task | Whatever native module surprises survive Phase 0 |
| 3 | Confinement decision + proof | Kernel capability, or writing a custom runner |
| 4 | Supervisor and lifecycle | Android process-death behaviours |
| 5 | WebView APK | Small: a viewer plus a service |
| 6 | Updates, backups, rollback | Discipline, not difficulty |

Phases 1–3 are the real work and are all **host-side shell engineering**, which is precisely why D1 dominates the alternatives: no toolchain, no ABI work, no upstream divergence.
