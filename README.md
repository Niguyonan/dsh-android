# DeepSeek Harness for Android

Run the [DeepSeek Harness](https://github.com/deepseek-harness/deepseek-harness)
on your own phone or tablet, as an app.

Install the APK, grant it root once, tap **Set up** — the app downloads a small
Linux system, installs the harness, starts it, and shows it in a window. There is
no terminal, no `adb`, and no script to run by hand.

**[Download the latest APK →](../../releases/latest)**

> Requires a rooted device. If that sentence needs explaining, this app is not
> for you yet — see [Requirements](#requirements).

## What it does

- **One-tap setup.** Checking the device, downloading the Linux base (~1 GB,
  first run only), installing the harness, checking the sandbox, locking the
  ports to this app, saving settings, starting the server. Each step is shown as
  it happens, with the raw output behind a **Log** toggle.
- **Survives being backgrounded.** Setup takes a while, so it runs in a
  foreground service with a progress notification: switch apps, and it keeps
  going. The server itself is a separate process — it does not need the app open,
  and the app does not hold a root shell between actions.
- **Start at boot, if you want it.** One toggle installs an autostart script
  through Magisk's or KernelSU's own service directory, so the harness is up
  before you unlock the phone. Off by default.
- **Your data stays on the device.** The agent reads and writes in
  `/data/local/dsh/workspace`; sessions, credentials and logs live in
  `/data/local/dsh/state`, and nothing is uploaded anywhere by this app.
- **Restart, stop and re-run setup from the app.** No shell needed for any of it,
  including the "something went wrong, try again" path.
- **Honest about its sandbox.** The harness confines the agent to the workspace
  with Linux's Landlock. Where the kernel does not support it, the app says so on
  screen instead of pretending — you get a warning banner, not a false sense of
  safety.

## Requirements

| | |
|---|---|
| Root | Magisk 24+, KernelSU, or KernelSU-Next. The app asks for root once; you grant it in your root manager like any other app, and you can revoke it there. |
| Android | 7.0 (API 24) or newer, `arm64` |
| Space | ~2 GB free under `/data` |
| Network | Needed for the first setup (the Linux base, Node, npm) |

## Install

1. Download the APK from [Releases](../../releases/latest), or build it yourself
   (see below).
2. Open it and install it. Android will warn that it comes from an unknown
   source — that warning is correct for any app installed outside a store.
3. Open **DeepSeek Harness**. The first screen explains what the app is about to
   do; tap **Continue**.
4. Your root manager asks for permission. Grant it. If you want the grant to be
   permanent, tick "remember" in Magisk or use the per-app profile in KernelSU.
5. Tap **Set up** and leave it alone. First run is 10–20 minutes, mostly download
   and `npm`.

When it finishes, the status line reads **Running** and the harness UI loads
inside the app.

## What it needs root for, and what that means

The harness runs a Linux userspace with Node inside a `chroot`, and the agent it
starts executes shell commands. On Android both of those need root — there is no
unprivileged way to do it.

So the app is a root client, and it is built like one: it never keeps a root
shell open, every command it runs is assembled from constants plus its own uid,
and it hands no JavaScript bridge to the page it renders (that page is agent
output). Its permissions are `INTERNET`, a foreground service, and notifications
— no storage access, because it reads everything it installs out of its own APK.

The full analysis, including what this deliberately does *not* protect against,
is in [`docs/security.md`](docs/security.md).

**The short version:** installing this gives a language model a root shell on
your device. That is the product, and it is worth being deliberate about.

## Troubleshooting

The app's **Log** toggle shows exactly what the device said. Most first runs fail
in one of these five ways:

| What you see | What to do |
|---|---|
| "root was not granted" | Open your root manager's Superuser list, check the app is allowed, then tap Retry. |
| A failure naming **base** — the install directory | The app keeps its runtime in `/data/local/dsh` and will not run scripts from a directory another app could write to. It fixes a mode it can close and says so; if it refuses instead, the log says why, and `rm -rf /data/local/dsh` from a root shell then **Set up** again is the way back. |
| Setup stops at *Installing the Linux base* | Almost always network or free space. The log names the file it could not fetch or verify. |
| A warning banner about the sandbox | This device's kernel has no Landlock, or the launcher is missing. The harness still runs; the agent is not confined to its workspace. |
| Setup stops at *Locking the ports* | This kernel has no `iptables` owner match, so other apps on the device cannot be kept off the ports. The log says so rather than installing a rule that does nothing. |

[`docs/runbook.md`](docs/runbook.md) has the full version: every symptom with the
command that diagnoses it, the gates to record on your device, and how to prove
the two port controls yourself.

## Build it yourself

You need a JDK and an Android SDK — that is all. No Gradle, and no dependency
resolution: the app is a few Java files against the framework API, plus the
on-device runtime bundled as one verified archive.

```sh
sh android/build.sh
# -> android/.build/dshd-0.1.0.apk
```

`build.sh` assembles the APK with the SDK's own tools (aapt2, javac, d8,
zipalign, apksigner) and then verifies what it signed. Pushing a `v*` tag runs
the same build on GitHub Actions and attaches the APK to a release;
[`.github/workflows/release.yml`](.github/workflows/release.yml) documents the
signing secrets that turn a debug-signed build into a properly signed one.

Host-side tests, if you want to change anything:

```sh
tests/run.sh
```

## Documentation

| | |
|---|---|
| [`docs/runbook.md`](docs/runbook.md) | On the device: install, the seven steps, the gates, proving the controls, troubleshooting, recovery |
| [`docs/security.md`](docs/security.md) | The exposure, the controls, and what was measured rather than assumed |
| [`docs/engineering.md`](docs/engineering.md) | How the port works, what is verified on a host, what still needs hardware, and the defects the tests caught |
| [`docs/root-solutions.md`](docs/root-solutions.md) | Magisk vs KernelSU vs KernelSU-Next: what actually differs |

## Not affiliated

An unofficial port. DeepSeek and DeepSeek Harness belong to their owners; this
repository contains no upstream code, no fork of it, and no modification of it —
it installs the published `linux-arm64` packages verbatim into a Linux userspace
on your device. Upstream is a developer preview with announced
compatibility-breaking changes, so anything here is version-pinned rather than
durable.
