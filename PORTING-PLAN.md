# Porting DeepSeek Harness (`dsh`) to rooted Android

Planning artifact only. **No implementation is included or implied by this document.**

- Upstream: `https://github.com/deepseek-ai/deepseek-harness` (MIT)
- Inspected revision: `0.2.1-alpha.1` (root `package.json`), cloned to a scratch directory for analysis
- Fork (read-only mirror): `https://github.com/Niguyonan/deepseek-harness`
- This project: `https://github.com/Niguyonan/dsh-android`
- Target: rooted `aarch64` Android device, single-user, "app-like" launch experience
- Claim audit: every factual assertion below is traced in §10, with what remains unverified named explicitly

---

## 1. Decision record

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Runtime strategy | **glibc Linux rootfs inside a real `chroot`**, orchestrated from a root shell | Android ships `bionic`; the harness's native layer has glibc/musl prebuilts only. A `chroot` makes the stock `linux-arm64` artifacts valid verbatim, so there is **no native code to rebuild and no fork to maintain**. Root already grants real `chroot` — no `proot` needed. |
| D2 | End-user surface | **Dedicated WebView APK** with app icon, foreground service, partial wakelock | Selected by the user. The harness UI is already a browser client, so the APK is a shell around `http://127.0.0.1:3080` plus lifecycle ownership. |
| D3 | Confinement | **Prefer Landlock; fall back to `danger-full-access`** | The upstream Linux chain (`bwrap` → Landlock) fails closed with `SANDBOX_UNAVAILABLE`, so one of the two must work. On a rooted single-user device the sandbox is a guardrail against agent mistakes, not a security boundary against other users. |
| D4 | Upstream relationship | **GitHub fork kept as a read-only mirror; do not maintain patched upstream source** | A fork now exists at `Niguyonan/deepseek-harness` so there is a stable reference point. It must stay unmodified: upstream is a *developer preview* with announced compatibility-breaking changes, so a patched fork would rot immediately. All our work lives in the port repo, not in the fork. |
| D5 | Distribution | Ship the runtime as files under `/data/local/dsh`, APK as a thin frontend | Keeps the Node runtime, rootfs, and credentials outside the APK, so the frontend can be reinstalled or updated independently of the harness. |
| D6 | Terminal posture | **Treat the PTY terminal as an opt-in feature with a declared fallback**, not as baseline | The terminal is the flagship "use it like a shell" capability *and* the single most likely thing to break on Android (§4). Only the `minimal` agent preset wires it. Baseline ships without it; enabling it is an explicit step with a PTY probe as its gate. |

### Explicitly rejected

- **Termux-native `bionic` build.** Requires rebuilding the Node-API addon and `node-pty` for Android, plus inventing a third libc branch, in exchange for roughly 100 MB of footprint. Permanently diverged native layer; highest maintenance cost per unit of benefit.
- **APK with embedded Node (`nodejs-mobile`).** Best theoretical UX, but the harness requires `engines: ^22.19.0 || >=24.0.0` and `nodejs-mobile` trails that badly. Would require self-building Node for Android first — a prerequisite project, not a port.
- **Bare Termux install with no `chroot`.** Looks cheapest, but lands directly on the native-layer wall in §2 and ends up as the rejected `bionic` option by another name.

---

## 2. Why there is no cheap "real" port

The harness is a Node.js/pnpm monorepo whose UI is a local web server. That is the good news: **no UI porting is required.** Everything hard is confined to the native layer and the process model.

Platform-specific surface, in descending order of pain:

1. **`native/system` (`@deepseek-ai/node-addon-system`)** — the hard blocker. `native/system/docs/support-matrix.md` publishes packages for **`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64` only**, and states: *"Other CPU/OS combinations have no published platform package: Landlock probes unusable, and flock acquisition rejects. New platform support requires a native builder and installed-artifact verification."* Each Linux package carries `bin/glibc/system.node` + `bin/musl/system.node` (Node-API 8) and a static-musl `landlock-run` executable. None of these load against `bionic`.
2. **`packages/session/session-persistence-jsonl`** — **hard-requires the flock addon.** `src/lease.ts` opens with a static top-level `import { tryLockExclusive } from '@deepseek-ai/node-addon-system/flock'`; the write lease on each session's `session.lock` is taken through it. This is not lazy and not optional — without a working binding, session write-open fails. Under D1 the glibc `system.node` satisfies it, which is a point *in favour* of D1 rather than against it.
3. **`packages/shell/bash-sandbox`** — consumed by the base bundle's `bash-sandbox` row and the other direct consumer of `node-addon-system` (its Landlock launcher). Same ABI story as item 1.
4. **`packages/sandbox/sandbox-local`** — the platform runner chain is **`bwrap` → Landlock** on Linux, Seatbelt on macOS, ACL tokens on Windows, and it **fails closed** rather than running unconfined. Android kernels commonly disable unprivileged user namespaces (which kills `bwrap`) and Landlock depends on `CONFIG_SECURITY_LANDLOCK`, which is not guaranteed on GKI builds. Two supported escape hatches exist: `danger-full-access` bypasses confinement entirely (`ConfinedSandboxMode` excludes it at the type level, so no runner is spawned), and `runnerCommand` substitutes a custom runner argv.
5. **`packages/subprocess/subprocess-local`** — mounted in the base bundle and declares `node-pty@1.2.0-beta.15` (patched in-repo) plus `koffi@3.1.1`. It resolves `node-pty` through `createLazyRequire`, so a plain boot does not load it. **That is not a licence to ignore it:** an interactive terminal *is* a shipped feature, and it is what loads this dependency. See §4.
6. **`python/sdk-runtime/platforms.json`** — the single-exe SDK runtime is built for `manylinux_2_28_aarch64` / `macosx_*` / `win_amd64` via `@yao-pkg/pkg`. It is **glibc-linked**, so it cannot run on bare Android either — but it becomes usable for free under D1, since the rootfs is glibc.

D1 sidesteps items 1–3 and 6 entirely, and most of item 4. Item 5 is the one it does not sidestep, and §4 is about that.

---

## 3. Target architecture

```
┌─ Magisk / root shell ────────────────────────────────────────────┐
│  /data/local/dsh/                                                │
│    rootfs/          Debian-or-Ubuntu arm64 rootfs (glibc)         │
│    workspace/       agent working directory (ext4, never noexec)  │
│    state/           DSH_HOME: sessions, storages, creds, logs      │
│    bin/dshd         start|stop|status supervisor + log rotation    │
│    log/dshd.log                                                   │
└──────────────────────────────────────────────────────────────────┘
             │ chroot rootfs
             │ bind: /proc  /dev (incl. /dev/pts)  workspace  state
             ▼
   node (glibc arm64)  →  dsh web --no-open  →  127.0.0.1:3080
             ▲
             │ HTTP on loopback only — NOT an app-to-app boundary (§7)
┌─ WebView APK (the "app") ────────────────────────────────────────┐
│  Activity: WebView → http://127.0.0.1:3080                       │
│  Foreground service: owns server lifecycle + PARTIAL_WAKE_LOCK    │
│  Persistent notification: status, Restart, Stop, Quit             │
└──────────────────────────────────────────────────────────────────┘
```

Two notes the diagram is load-bearing for:

- **`/dev/pts` must be present inside the chroot.** `devpts` is a *separate* filesystem type — mounting `/proc` alone does not provide it. Omit it and every PTY allocation fails, which silently costs you the terminal (§4). Bind `/dev` including `/dev/pts`, or mount `devpts` explicitly.
- **Loopback is not a security boundary between Android apps.** Any other app holding `INTERNET` can reach `127.0.0.1:3080`. See §7 — this is the most serious finding in this document.

**Lifecycle ownership is the crux of D2.** Android will reap the server the moment it stops being the user's point of attention; the foreground service — not the Activity — is what keeps the server alive, and it must be able to *start* it, not merely observe it.

---

## 4. The terminal question ("can it behave like Termux?")

This is a first-class feature, not an edge case, and it deserves its own posture (D6).

### What actually ships

| Layer | Package | What it gives you |
|---|---|---|
| Model-facing | `packages/terminal/tool-terminal` | *"Six model-facing persistent PTY tools with owner isolation and generic background-job integration"* — the **agent** gets an interactive TTY, so it can drive `vim`, `htop`, and anything that expects a terminal |
| Model-facing | `dsh-tool-bash-persistent` | A bash session whose state survives across tool calls, so `cd` and `export` persist between turns |
| User-facing | `packages/client/ui-sidebar-terminal` | A real **xterm.js** emulator (`@xterm/xterm ^6.0.0` + `@xterm/addon-fit ^0.11.0`) — so in the WebView you get a terminal on the phone screen |
| Backend | `packages/terminal/terminal-bash` | The bash PTY provider; this is where `node-pty` enters |

### How you enable it — it is a preset, not a default

The terminal **UI** is mounted unconditionally by the web app (`packages/bundle/web-app/cordis.patch.yml:295`, `ui-sidebar-terminal`). The **backend** comes from an *agent preset*, and only one preset has it:

| Preset | `order` | PTY rows |
|---|---|---|
| `standard` | 1 | **0** |
| `ptc` | 2 | **0** |
| `minimal` | 3 | **3** |
| `cordis` | 4 | **0** |

Only `packages/bundle/web-app/presets/minimal.patch.yml` inserts the stack: a `cordis:group` with `isolate: { terminals: true }` containing `dsh-terminal` (the pty seam), `dsh-terminal-bash`, and `dsh-tool-bash-persistent` (lines 21–44). So a session must use the **`minimal`** preset — or you add those same rows to your own profile patch — before the sidebar terminal has anything behind it. The deployment default is read from `config.default` (overridable by `selectedDefault` at runtime), so confirm which preset is default rather than assuming.

### The Android catch

Enabling the terminal is precisely what makes `node-pty` load-bearing — the one native dependency the chroot does *not* rescue, because its problems are kernel- and SELinux-level:

- **`/dev/pts` must be mounted** inside the chroot (§3).
- **`posix_openpt` / `grantpt` / `forkpty` must work** under the Android kernel and SELinux policy.
- node-pty's Linux glibc prebuild is satisfied by the rootfs — this part D1 does fix.
- **xterm.js in Android System WebView** is fine (Chromium), but `addon-fit` needs correct container sizing, and a soft keyboard over a terminal is the classic WebView pain point.

### It degrades, it does not cliff-edge

If PTY fails, the base bundle's non-PTY path still works: `tool-bash` + `bash-sandbox` run commands and return output without a live TTY. You lose the sidebar terminal, interactive programs, and cross-call shell state. You do **not** lose "the agent can run shell commands." Per D6, that is the declared baseline.

### It will not *be* Termux

| | Termux | This |
|---|---|---|
| Userspace | Android `bionic` | Debian/Ubuntu arm64, **glibc** |
| Packages | Termux's own repos | upstream Debian/Ubuntu `apt` |
| Privilege | app UID | **root** |
| Reachable from | the phone | the WebView app — *and anything on the device that can reach loopback* |

That last row is why enabling the terminal materially raises the stakes on §7: a PTY in a web UI is a remote shell. Both can coexist — Termux for the bionic side, the harness for the glibc/root side — since they have separate userspaces, files, and package managers.

---

## 5. Phased plan

Each phase ends in a gate. Do not start the next phase until the gate passes on the actual device.

### Phase 0 — Device feasibility probes (blocking)

Everything downstream branches on these answers. Run from a root shell and record raw output.

| Probe | Command | Why it matters |
|---|---|---|
| Kernel + arch | `uname -a`; `cat /proc/version` | Confirms `aarch64` and kernel generation |
| User namespaces | `cat /proc/sys/user/max_user_namespaces` | `0` ⇒ `bwrap` is dead; rules out runner rung 1 |
| Landlock | `grep -i landlock /proc/kallsyms \| head`, plus a functional `LANDLOCK_CREATE_RULESET_VERSION` probe | Decides D3. Kernel version alone is explicitly *not* a reliable signal per the upstream support matrix |
| **`noexec` mount** | `mount \| grep -E ' /data \| /data/local '` | **If the rootfs lands on a `noexec` mount, Node cannot execute at all.** This kills the approach before it starts and must be checked first |
| **SELinux denials on mount** | `mount -t proc proc /data/local/dsh/rootfs/proc` and check `dmesg \| tail` / `logcat` for `avc: denied` | `mount` from a Magisk `su` context is commonly denied; expect to need policy patches |
| **PTY / `devpts`** | Confirm `/dev/pts` exists and a PTY allocates (e.g. `python3 -c "import pty; pty.openpty()"` inside the rootfs) | The terminal is the flagship risk (D6); this decides whether §4's fallback is the baseline |
| Seccomp / `setpriv` | `command -v setpriv unshare` | Fallback confinement building blocks if anything beyond D3's fallback is wanted |
| Workspace filesystem | `mount \| grep -E 'sdcard\|fuse\|ext4'` | `chroot` + Landlock over FUSE-backed `/sdcard` is where subtle breakage lives; prefer ext4 |
| Free space | `df -h /data` | Rootfs + Node + `pnpm` store is a few hundred MB before sessions |

**Gate P0:** a written table of probe results, D3 resolved to a concrete choice, and the §4 terminal verdict (enabled or fallback).
**Abort condition:** if Landlock is unavailable *and* `danger-full-access` is unacceptable, stop and reconsider D1 — the `bionic` path would not fix this, since it has the same kernel.

### Phase 1 — glibc rootfs

1. Fetch an arm64 base rootfs (`ubuntu-base-*-base-arm64.tar.gz` or a Debian equivalent) that uses glibc. This is the whole point of D1 — do not reach for Alpine/musl here.
2. Extract under `/data/local/dsh/rootfs` (verified executable, §5 Phase 0); create the skeleton (`proc`, `sys`, `dev`, `dev/pts`, `tmp`, `workspace`, `state`).
3. Bind-mount `/proc`, `/dev` **including `/dev/pts`**, the workspace, and the state directory. Set a working `/etc/resolv.conf` so `npm`/`pnpm` can reach the network.
4. Install a **glibc** Node inside the rootfs from the official `linux-arm64` tarball, satisfying `^22.19.0 || >=24.0.0`.
5. Write `bin/dshd` — a `chroot` wrapper owning the mounts, `PATH`, and `DSH_HOME` pointed at `state/`.

**Gate P1:** inside the chroot, `node -v` reports a supported version, and libc introspection identifies glibc:

```sh
node -p "process.report.getReport().header.glibcVersionRuntime || 'MUSL/OTHER — D1 is broken'"
```

Also confirm the mounts survive a re-`chroot`.

### Phase 2 — Install and boot the harness

1. Install `@deepseek-ai/dsh` at a **pinned version** (D4) inside the rootfs.
2. Boot `dsh web --no-open` with `DSH_HOME=/data/local/dsh/state`.
3. Confirm the server binds `127.0.0.1:3080` and that a browser on the device renders the UI.
4. Configure credentials through the UI's Models page rather than inlining a key, and verify the managed credentials document lands in `DSH_HOME` (§7).
5. Note for Phase 3 that the base bundle reads `DSH_PERMISSION_MODE` (defaulting to `workspace-write`) and that `danger-full-access` also flips the approval policy to `never`.
6. Exercise a session write, so item 2 of §2 (the flock-backed write lease) is proven rather than assumed.

**Gate P2:** a full agent round-trip — prompt in, a real file read/write in the workspace, result back — with the process surviving a detach/reattach cycle.
**Highest-risk unknown in this phase:** any native module resolved at startup. If boot fails on a missing addon, that is the §2 boundary being hit, and it belongs in Phase 0's ledger.

### Phase 3 — Confinement

1. If Landlock is available: keep the stock chain and verify that `workspace-write` actually **denies** a write outside the workspace — a sandbox that silently degrades to permissive is worse than no sandbox, because the model is told it is confined.
2. If Landlock is unavailable: pin `DSH_PERMISSION_MODE=danger-full-access` at the `dshd` level so the mode cannot drift per session, and disclose in the app UI that writes are unconfined.
3. If confinement without Landlock is wanted, this is where `runnerCommand` earns its keep — a wrapper enforcing the workspace boundary by other means. Optional stretch, not baseline.

**Gate P3:** demonstrate the chosen posture empirically — a denied write under Landlock, or an explicit "unconfined" notice under the fallback.

### Phase 4 — Launcher and lifecycle

1. Harden `dshd` into a supervisor: idempotent `start`, `stop`, `status`, restart-on-crash with backoff, log rotation, and stale-PID cleanup.
2. Decide the autostart mechanism: a Magisk `service.d` script for boot-time start, or service-initiated start from the APK. Prefer the APK owning it (D5) so the runtime's lifetime matches what the user sees in the notification. Note that boot-time start can fire before first unlock under File-Based Encryption.
3. Verify the server comes back cleanly after a force-stop, a reboot, and an OOM kill.

**Gate P4:** reboot the device, do nothing, and reach the UI. Then force-stop everything and reach it again.

### Phase 5 — WebView APK

Keep the APK resolutely dumb — a viewer plus a lifecycle owner. No harness logic in Java/Kotlin, so upstream changes never touch it. "Dumb" is not "small"; the integration surface below is real work.

- **Activity:** a `WebView` pointed at `http://127.0.0.1:3080`. Enable JavaScript and DOM storage; keep in-app navigation inside the WebView; handle the back button as history; render a first-run/error screen when the server is not up.
- **Cleartext:** loopback HTTP requires the manifest/network-security-config to permit cleartext for `127.0.0.1` specifically — not globally.
- **Foreground service:** a single service owning server start/stop, with a persistent notification exposing Restart/Stop, and a `PARTIAL_WAKE_LOCK` held only while the server is meant to be up.
- **Permissions:** notifications (needed for a visible foreground service on modern Android). Prompt for battery-optimization exemption, but treat a refusal as degraded rather than fatal.
- **Readiness:** poll the loopback port before navigating, so a cold start does not flash a connection error.
- **WebView plumbing the harness needs:** `onShowFileChooser` for file upload, a `DownloadListener` for the session-log export dialog, and clipboard access.
- **Soft keyboard and insets:** the chat composer must survive the keyboard; hook `visualViewport` and set the right `softInputMode`, and respect `env(safe-area-inset-*)` for notches and gesture bars.
- **Features that simply will not work on Android:** the web app resolves "Open In…" against macOS/Windows/Linux applications, and `ui-directory-picker-native` assumes a desktop native dialog. Use the `ui-directory-picker-browse` path instead.
- **Binding:** bind loopback **only**. Never `0.0.0.0` — the harness executes shell commands, and a LAN-exposed agent surface is a remote-code-execution endpoint by design. Note that loopback alone is *not* sufficient on Android (§7).

**Gate P5:** from a cold device, one tap on the app icon reaches a usable UI; the phone-width layout is genuinely usable (not merely unbroken) for chat, sidebar, and terminal; and the server is still alive after thirty minutes in the background.

### Phase 6 — Hardening and updates

1. Pin the harness version and write an update procedure: bump inside the rootfs, smoke-test, keep the previous version for rollback.
2. Back up `DSH_HOME` deliberately — session logs and credentials both live there.
3. Add a "revert to known-good" path and a health check the APK can surface.
4. Re-run the Phase 0 probe table after any kernel/ROM update, since Landlock availability is a kernel property, not a device property.

---

## 6. Traps worth pre-empting

- **`noexec` kills everything.** If the rootfs sits on a `noexec` mount, Node will not run. Check this before anything else (§5 Phase 0).
- **`os`/`cpu` gating passes on Android — and that is a trap, not a win.** Android Node reports `process.platform === 'linux'` and `process.arch === 'arm64'`, so npm's `os`/`cpu` checks in `native/system/packages/linux-arm64/package.json` will happily install the package. Selection is not the problem; loading a glibc `system.node` into a bionic Node is. Under D1 both are glibc, so the coincidence becomes harmless.
- **libc detection has exactly two branches.** `native/system/scripts/build.ts` classifies a Linux host as `glibc` if `process.report` exposes `glibcVersionRuntime`, else `musl`. `bionic` is *neither*, so it silently falls through to `musl`. This is a concrete reason D1 beats the `bionic` path rather than a stylistic preference.
- **A green boot does not prove the terminal works.** `node-pty` is lazily required and only the `minimal` preset loads it, so a healthy startup plus a missing PTY is the *expected* shape of a partial failure. Probe for it deliberately (§5 Phase 0).
- **FUSE-backed `/sdcard` is not a good agent workspace.** Prefer an ext4 path and bind it in. Writes, permissions, `mmap`, and Landlock semantics over FUSE are all places to lose a weekend.
- **A silent sandbox downgrade is a correctness bug.** Upstream deliberately fails closed when no runner is usable; any wrapper that turns that into "run unconfined" must make the difference visible to the user.
- **Loopback trust is misplaced on Android.** See §7 — this is the strongest security finding here, not a footnote.
- **Developer-preview churn.** Upstream has announced breaking changes. Every assumption here about plugin names, preset wiring, bundle rows, and config keys is version-pinned, not durable.
- **OEM ROMs will reap the server anyway.** A foreground service plus wakelock is the correct answer, and Xiaomi/HyperOS, Samsung, Oppo/vivo will still kill it. Battery-optimization whitelisting helps without guaranteeing. ROM-dependent, so mitigable and documentable but not engineerable away.

---

## 7. Security posture (the finding that matters most)

Read together, these are a privilege-escalation path, not a theoretical concern:

1. **The web server ships no authentication.** `packages/host/webserver/src/` contains only `index.ts` and `injections.ts`, and grepping it for `token|authoriz|origin|csrf|auth` returns **zero hits**. `apps/cli/src/` likewise injects no token or origin check — its only "token" matches are doc-comments about argument parsing.
2. **Loopback is not an app-to-app boundary on Android.** Any other app holding the `INTERNET` permission can connect to `127.0.0.1:3080`.
3. **The agent executes shell commands.** Under `danger-full-access` (D3's fallback) those commands are unconfined, and on a rooted device they are **root**.

So the exposure is: *any app on the device can drive a root shell*. Enabling the terminal (D6, §4) makes this worse — it turns the endpoint into an interactive remote shell rather than a file-writing agent.

**Required mitigations before this is allowed to run on a device you care about:** front the server with a token or origin check, or bind a Unix socket instead of TCP, or apply device-local firewall rules restricting loopback access. Verify the chosen control actually blocks a second app; a control that is assumed rather than tested is not a control.

---

## 8. Acceptance criteria

The port is done when **all** of the following hold:

1. Cold boot, no terminal interaction, one tap on the app icon → usable harness UI.
2. An agent completes a real multi-turn task with file edits landing in `/data/local/dsh/workspace`.
3. A session write succeeds, proving the flock-backed lease (§2 item 2) works on this platform.
4. The §4 terminal verdict is honoured: either the terminal works, or the fallback is enabled and the missing terminal is visible to the user rather than silently absent.
5. The server survives backgrounding for at least thirty minutes and recovers from a force-stop with no manual repair.
6. The confinement posture from D3 is observable and honest — enforced-and-demonstrated, or explicitly disclosed as absent.
7. Credentials live in `DSH_HOME`, never in an APK resource, a shell history, or a config file committed anywhere.
8. The server is reachable only through the §7 mitigation, and that mitigation has been **proven** to block a second app on the device — not merely asserted.
9. The harness version is pinned, and a documented rollback to the previous version exists.

---

## 9. Effort sketch

| Phase | Character of the work | Dominant cost |
|---|---|---|
| 0 | Probes and reading | Device access; SELinux and PTY answers |
| 1 | Rootfs assembly, mounts, `chroot` wrapper | Bind-mount, `devpts`, and DNS fiddliness |
| 2 | Install, boot, first real task | Whatever native module surprises survive Phase 0 |
| 3 | Confinement decision + proof | Kernel capability, or writing a custom runner |
| 4 | Supervisor and lifecycle | Android process-death behaviours |
| 5 | WebView APK | Moderate: viewer + service, **plus** file chooser, downloads, clipboard, keyboard/insets, and two host features that have no Android equivalent |
| 6 | Updates, backups, rollback | Discipline, not difficulty |
| — | §7 mitigation | Must be designed, not assumed |

Phases 1–3 are the real work and are all **host-side shell engineering**, which is precisely why D1 dominates the alternatives: no toolchain, no ABI work, and no upstream divergence (D4 keeps the fork unmodified).

---

## 10. Claim audit

Recorded so this document can be re-checked rather than trusted. Every claim was verified by reading the cloned tree at `0.2.1-alpha.1`; where a claim could not be settled by reading, it is listed as unverified instead of asserted.

### Verified by inspection

| Claim | Evidence |
|---|---|
| Native prebuilts exist only for linux/darwin | `native/system/packages/`; `native/system/docs/support-matrix.md` (quote verbatim) |
| Linux payload shape | `native/system/packages/linux-arm64/prebuilds.json` — glibc + musl `system.node`, static-musl `landlock-run` |
| Linux sandbox chain is `bwrap` → Landlock, fails closed | `packages/sandbox/sandbox-local/src/index.ts` module doc + probe functions |
| `danger-full-access` bypasses confinement | `packages/sandbox/sandbox/src/index.ts:27–33` (`ConfinedSandboxMode` excludes it) |
| `runnerCommand` escape hatch exists | `packages/sandbox/sandbox-local/src/index.ts` `Config` |
| Session persistence hard-requires flock | `packages/session/session-persistence-jsonl/src/lease.ts:36` static import of `@deepseek-ai/node-addon-system/flock` |
| `bash-sandbox` consumes the Landlock launcher | `packages/shell/bash-sandbox/package.json` + its `tests/landlock.e2e.ts` |
| `subprocess-local` declares node-pty, lazily loaded | `packages/subprocess/subprocess-local/package.json`; `src/index.ts:50` `createLazyRequire('node-pty', …)` |
| `tool-terminal` is a PTY tool surface | `packages/terminal/tool-terminal/package.json` description |
| Terminal UI is xterm.js and ships with the web app | `packages/client/ui-sidebar-terminal/package.json` (`@xterm/xterm ^6.0.0`, `addon-fit`); `packages/bundle/web-app/cordis.patch.yml:295` |
| Only the `minimal` preset wires the PTY stack | `packages/bundle/web-app/presets/*.patch.yml` — terminal rows: `minimal` 3, others 0; `order` standard 1, ptc 2, minimal 3, cordis 4 |
| Base bundle's shell tool is non-PTY | `packages/bundle/base/cordis.patch.yml` rows `dsh-bash-sandbox`, `dsh-shell-env`, `dsh-tool-bash` |
| No web-server authentication | `packages/host/webserver/src/` is `index.ts` + `injections.ts`; zero matches for `token\|authoriz\|origin\|csrf\|auth`. No token/origin injection in `apps/cli/src/` |
| No Material UI; React 18 + in-house CSS Modules | all `package.json` UI deps are `react`, `react-dom`, and one `vue` in `website/` |
| Viewport meta and responsive/touch CSS present | `apps/web/index.html`; breakpoints 400/480/560/720/760/1100px, `@media (pointer: coarse)` |
| It is already a PWA | `apps/web/index.html` links `manifest.webmanifest` |
| SDK runtime is glibc-linked | `python/sdk-runtime/platforms.json` (`manylinux_2_28_aarch64`, etc.) |
| `engine` floor | root `package.json` — `^22.19.0 \|\| >=24.0.0` |
| `require('node:report')` does not exist | executed: returns `ERR_UNKNOWN_BUILTIN_MODULE`; the working form is `process.report.getReport()` |

### Corrected in this revision

- **D4** previously read "Vendor a pinned release; do not fork", which contradicted the fork that now exists. Now states the fork is a read-only mirror.
- **§2 item 3 (old)** framed PTY as avoidable. It is a shipped feature; now §2 item 5 plus §4.
- **§2 item 4 / old §7 item 1** listed "does it hard-require flock?" as an open question. It does, and it is now asserted with a line reference.
- **Gate P1** previously ran `node -e "require('node:report').getReport().header"`, which **cannot execute**. Replaced with a working command.
- **Lazy-`node-pty` trap** previously drew the wrong conclusion ("a broken terminal is probably fine"). Rewritten around the preset wiring.
- **Loopback trap** was a "confirm this" note. It is now §7, the document's strongest security finding.
- **Acceptance criterion 6** ("reachable only on loopback") understated Android's app-to-app reachability; now criterion 8 requires a *proven* control.
- **Phase 5** was costed as "Small: a viewer plus a service". Now names the file chooser, downloads, clipboard, keyboard/insets, and the two host features with no Android equivalent.
- **`/dev/pts`** was absent from the architecture, the mount list, and the probe table. Added to all three.

### Unverified — do not assume these

- Whether a phone-width layout is genuinely *usable* — breakpoints and `pointer: coarse` rules exist, but the UI was never rendered at phone size.
- Which preset is the deployment default (`config.default` / `selectedDefault`), and therefore whether the terminal backend is reachable without an explicit preset change.
- Whether `node-pty` actually allocates a PTY under the Android kernel in a chroot. This is the central Android unknown and only a device can answer it.
- Whether the `web-app` bundle mounts `tool-terminal` as a row; it is mentioned only in a comment at `cordis.patch.yml:475`.
- Whether any *other* host package (outside `packages/host/webserver` and `apps/cli`) adds an auth layer. The absence found is scoped to those paths, not proven repo-wide.
- All kernel-level questions in §5 Phase 0 — Landlock, user namespaces, `noexec`, SELinux mount policy.
