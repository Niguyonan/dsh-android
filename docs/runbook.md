# Runbook — from a rooted phone to a working harness

Written for someone holding the device. Every command here runs **on the phone**,
as root, and every one of them has a pass condition rather than a vibe. Where the
answer is "nobody has run this yet", that is said out loud instead of implied.

Two paths lead to the same place, and they are the same scripts either way:

- **the app** — install the APK, grant it root, tap Set up. This is the product,
  and steps 1–4 below are what it does for you.
- **a root shell** — the same seven steps, one command each. This is what to
  reach for when a device will not cooperate, when `adb` is already plugged in,
  or when something has to be watched line by line.

## 0. Before you start

| | |
|---|---|
| Root | Magisk 24+, KernelSU, or KernelSU-Next. All three are supported; `dshd root` reports which one answered. |
| Space | ~2 GB free under `/data`. The Linux base is ~1 GB compressed, plus the harness and its dependencies. |
| Network | Needed on the first run only (the base image, Node, npm). |
| Storage | `/data` must be ext4/f2fs and executable. Never `noexec`, never FUSE — Phase 0 checks this and stops if it is not true. |
| A second device | Useful, not required: for the §7 proof in step 6 you want a *different* app uid to attack from. A terminal app works. |

If you have not filled in `docs/phase-0-probe-ledger.md` for this device, do that
first. It takes two minutes and it is where every later decision gets its
evidence:

```sh
sh /data/local/dsh/tools/probe.sh --save /data/local/dsh/log/p0.txt
```

Probe verdicts are *pass*, *warn* or *fail*. A `fail` on executable storage, the
chroot, or mounting means D1 does not work on this device, and no amount of
continuing will change that.

## 1. Install the APK

Build it (the payload and the app are built together, so they cannot drift):

```sh
sh android/build.sh                     # → android/.build/dshd-0.1.0.apk
adb install -r android/.build/dshd-0.1.0.apk
```

Or copy the APK to the device and open it. It is signed with a debug key unless
you pass `--ks`, so your installer will warn about an unknown source: that
warning is correct, and the only thing it should make you check is that you built
the file yourself.

The app asks for `INTERNET`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_DATA_SYNC` and `POST_NOTIFICATIONS`, and nothing else. No
storage permission, because it does not read your files: everything it installs
comes out of its own APK.

## 2. Grant root, once

Open the app. The first screen explains what it is about to do and why it needs
root — read it, then tap **Continue**. Your root manager will ask once:

- **Magisk** — Superuser tab, the app appears as a request, grant it. Set it to
  remember if you do not want to be asked again.
- **KernelSU / KernelSU-Next** — Superuser tab, the app is listed when it asks.
  KernelSU has a per-app profile; the default is fine.

If no prompt appears, or the app says root was not granted:

| What you see | What it means |
|---|---|
| The prompt appears every time | The grant was allowed once, not remembered. Fix it in the root manager's list. |
| No prompt at all | The app is not in the manager's Superuser list because the request never arrived: check that you are on a rooted boot (Magisk shows "Installed: <version>"), and that you are not in Magisk's "Deny list" for this app. |
| `su did not grant root (exit 1: Permission denied)` | The request arrived and was denied. Open the manager and grant it, then tap Retry. |

After that first grant, the app never holds a root shell open. Each action is one
`su -c` command that ends when it is done; the server keeps running because it is
a detached process, not because the app is alive.

## 3. Tap Set up

Seven steps, in this order, each one a script you could have run yourself:

| Step | What it does | Roughly |
|---|---|---|
| **Checking for root** | Installs the payload into `/data/local/dsh` after verifying every file against the manifest, and confirms the shell is uid 0. | seconds |
| **Checking what this device can do** | Phase 0 (`tools/probe.sh`) → `log/p0.txt`. Stops if a critical probe fails. | seconds |
| **Installing the Linux system** | Phase 1 (`tools/rootfs-setup.sh`): downloads the Ubuntu base and glibc Node, verifies their published checksums, builds the chroot skeleton, then proves glibc **inside** the chroot. | 5–20 min |
| **Installing the harness** | Phase 2 (`tools/install-harness.sh`): installs `libstdc++6` if missing, then `@deepseek-ai/dsh` with `--ignore-scripts`, then proves the loopback-only bind, the 401 without a session, the launch-token line and the cross-origin fence. | 3–10 min |
| **Checking the sandbox** | Phase 3 (`tools/confinement-check.sh`): runs the harness's own `landlock-run --probe`, then a write inside the granted root that must succeed and a write outside it that must fail. | seconds |
| **Locking the ports to this app** | §7 (`tools/firewall.sh apply --uid <this app>`): a UID-owner rule set on 3080/3081, verified with `-C` after it is installed. Stops setup if it cannot be enforced. | seconds |
| **Saving settings** | Writes `etc/dshd.conf` with this app's uid, the ports and the autostart key, so a later `dshd start` re-applies the firewall without being told again. | instant |
| **Starting the server** | Mounts `/proc`, `/dev` (with `/dev/pts`), the workspace and the state directory; mints the guard token; spawns the guard and the harness; waits for both ports. | 5–30 s |

You can leave the app in the background — a foreground notification keeps the
download alive. Keep the screen on if your device is aggressive about doze.

**Success looks like:** the status line reads *Running*, and the WebView loads.
If it does not, tap **Log**: the protocol lines say which step failed and the raw
output above them says why.

### Two things the run tells you about itself

- **A step that says `skip`** was already done. That is normal on a second run,
  and it means the step was not repeated — not that it silently failed.
- **A warning banner** means the sandbox is not proven. The harness's Landlock
  confinement needs kernel support; when it is missing, `permission_mode` is
  pinned to `danger-full-access` and the app says so, because "the agent is
  confined to its workspace" would otherwise be a claim with nothing behind it.

## 4. The same seven steps from a root shell

```sh
sh /data/local/dsh/tools/probe.sh --save /data/local/dsh/log/p0.txt   # P0
sh /data/local/dsh/tools/rootfs-setup.sh       # P1
sh /data/local/dsh/tools/install-harness.sh    # P2
sh /data/local/dsh/tools/confinement-check.sh  # P3
sh /data/local/dsh/tools/firewall.sh apply --uid <APP_UID>   # §7
sh /data/local/dsh/bin/dshd start              # P4
```

…which is exactly this, and is what the app runs:

```sh
sh /data/local/dsh/bin/dshd setup --app-uid <APP_UID>
sh /data/local/dsh/bin/dshd setup --check      # what is installed, what is running
sh /data/local/dsh/bin/dshd url                # the URL to open, token included
```

`<APP_UID>` is the app's uid. `dshd setup` will not proceed without it — a
firewall rule installed against a guessed or empty uid is worse than no rule,
because it reports success. The app passes its own; from a shell you can read it
with `dumpsys package dev.dshd.app | grep userId=` (Android 11+) or
`stat -c %u /data/data/dev.dshd.app`.

### The install directory, when a setup refuses to use it

`/data/local/dsh` is where root-executed scripts live, so the bootstrap makes it
0700 before installing anything, and will not install into a directory it cannot
close. It reports each case on the protocol, with the reason, as `fail base`:

| What it finds | What it does |
|---|---|
| A mode that is not 0700, owned by root | closes it to 0700 and says so in the log (`was mode 0775; it is mode 0700 now`). This is what an install directory created by an older build looks like |
| A mode that is *already* 0700, in the log as `mode 0700 and the group or other write bits could not be closed` | nothing is wrong with the device: that was a defect in the payload, where the mode test was `$((mode & 022))` and `0700` is decimal to the sh Android runs, so a directory with no write bits to close looked writable. Builds with the fix do not print this; `rm -rf /data/local/dsh` did not help, because the next run created it 0700 again |
| Owned by another uid | refuses (exit 7): that uid would decide what root runs |
| A symlink in its place, or an install directory inside it (`bin`, `tools`, `guard`, `boot/service.d`) that is one | refuses (exit 7): root would write wherever it points |

To recover: `rm -rf /data/local/dsh` from a root shell, then tap **Set up** again.
The payload is verified by digest on the way back in, so nothing else is lost
except `state/` — see §9 if that matters.

## 5. Fill in the gates

The plan's gates are not ceremony: each one is the evidence for a decision that
everything later depends on. Record the verdict, the date and the device.

| Gate | The claim it settles | Where the verdict goes |
|---|---|---|
| P0 | This device can execute from `/data`, mount from a `su` context, and chroot. | `docs/phase-0-probe-ledger.md` |
| P1 | A glibc Node runs inside the chroot, with working DNS. | `rootfs-setup.sh` exit 0, and its last lines |
| P2 | The harness serves the API with its own auth in force, loopback only. | `install-harness.sh` smoke output |
| P3 | The agent's writes outside the workspace are denied — or the fallback is pinned and disclosed. | `state/posture.conf`, `deny=` and `permission_mode=` |
| P4 | The server survives a reboot, a swipe-away and a force-stop, and comes back. | this file, below |
| P5 | The app reaches the harness and the harness reaches the model. | this file, below |

### P4 — does the server survive the phone

```sh
sh /data/local/dsh/bin/dshd start
sh /data/local/dsh/bin/dshd status        # running, both ports listening
```

Then, in order, and re-checking after each:

1. **Swipe the app away.** The server is a detached `setsid` process and should
   not care. If it dies, the supervisor is not detached on this device's kernel.
2. **Force-stop the app** (`Settings → Apps → Force stop`). Android kills the
   app's process group; whether a detached root process in a different cgroup
   survives is exactly what this checks. If it does not survive, boot autostart
   is the answer, not a bug fix.
3. **Reboot.** With autostart on (the **Start at boot** toggle, or
   `autostart=on` in `etc/dshd.conf`), `/data/adb/service.d/dshd.sh` runs at
   `late_start` and brings the server up. `log/autostart.log` records what it
   did. File-based encryption is why it waits: `/data/local` is available early,
   but a `DSH_HOME` inside credential-encrypted storage is not.

### P5 — does it actually work

Open the app's WebView (or the URL from `dshd url`) and run one real request
through the agent. A harness that serves its UI and cannot reach a model is a
green status line and no product; this is the gate that says otherwise.

## 6. Prove the two §7 controls by hand

Both halves exist because **loopback is not an app-to-app boundary on Android**:
any app holding `INTERNET` can open `127.0.0.1:3080`, which is the harness with
its own auth in front of it, or `:3081`, which is the guard. The token is the
first control; the firewall rule is whether the ports are reachable at all.
`docs/security.md` has the full analysis and the measured table; this is the
procedure that proves it *on your device*.

**The firewall rule.** From a terminal app whose uid is *not* the app's uid (or
`adb shell`, which is uid 2000 unless you `su`):

```sh
sh /data/local/dsh/tools/firewall.sh status     # exit 0 = enforced
nc -z 127.0.0.1 3081 && echo REACHABLE || echo blocked
nc -z 127.0.0.1 3080 && echo REACHABLE || echo blocked
```

Expected as a non-app uid: **blocked, blocked**. Reachable means the rule is
installed against the wrong uid, or not at all — `firewall.sh print` shows the
commands it would run, and `iptables-save | grep DSH_ANDROID` shows what is
there.

**The guard.** As the app's uid the ports are reachable, and the guard must still
refuse everything without a token:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3081/          # 401
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3081/api       # 401
```

A 200 from either is the whole §7 story failing: an app that can reach the port
can then drive the agent. Note that this is *not* the only thing protecting the
harness — the harness authenticates too, and `docs/security.md` records the
measurement — but it is the half that stops a stranger reaching it.

## 7. Troubleshooting, by symptom

| Symptom | Most likely cause | What to run |
|---|---|---|
| Setup stops before *Checking what this device can do* | Root was not granted (exit 2), or the install directory is not safe (exit 7) — the screen names the check and quotes its reason | grant root in the manager; for exit 7, see §5's note on `/data/local/dsh` |
| Setup stops at *Checking what this device can do* | Storage is `noexec`, or `su` cannot mount | `sh tools/probe.sh` and read the `fail` lines; `log/p0.txt` |
| Stops at *Installing the Linux system* | Checksum mismatch or no network | the raw log above the step; the script names the file and the URL |
| Says the Linux base exists but is incomplete | A previous run died mid-extract | `sh bin/dshd setup --app-uid N --replace-rootfs` (deletes `rootfs/`) |
| Stops at *Installing the harness* | Missing `libstdc++6`, or npm cannot reach the registry | `tools/install-harness.sh` from a shell prints the same run with more detail |
| *The sandbox is NOT proven* banner | No Landlock in this kernel, or the launcher is missing | `sh tools/confinement-check.sh --probe-only` |
| Stops at *Locking the ports* | No `iptables`, or a kernel without the owner match | `sh tools/firewall.sh apply --uid N` prints the reason and the exit code |
| *Starting the server* times out | `/dev/pts` not mounted, or the harness exited at once | `log/harness.log`, `log/guard.log`, then `sh bin/dshd mounts` |
| The app says *Stopped* after a reboot | Autostart is off, or the boot script did not run | `sh bin/dshd boot status`, `log/autostart.log` |
| The WebView is blank but the status says *Running* | The token was not accepted, or the page is being blocked | `sh bin/dshd url`, then open that URL in the device's browser to see the guard's own answer |

`sh bin/dshd doctor` prints the status summary plus the Phase 6 `tools/doctor.sh`
if it is installed; it is not written yet.

## 8. The other verbs

Small, and all safe to run while the server is up unless noted:

| Verb | What it does |
|---|---|
| `dshd status` | process, both ports, permission mode, confinement verdict, root solution, mount summary |
| `dshd logs [-f]` | the last lines of the supervisor, harness and guard logs — or follow them |
| `dshd restart` | `stop` then `start`, for when a config change needs picking up |
| `dshd token` | the guard token on its own (0600). Prefer `dshd url`, which is the same secret in a form that logs in |
| `dshd url --harness` | the harness's own port and launch token, bypassing the guard — for telling the two layers apart when something is wrong |
| `dshd mounts` | create the chroot bind mounts and report each one, without starting anything |
| `dshd umount` | tear the chroot mounts down and leave the server alone; useful before moving the workspace |
| `dshd rotate` | rotate oversized logs. Only while stopped: the running processes hold their own file descriptors |
| `dshd root` | which root solution granted this shell, which `su` was used, and the SELinux domain it runs in |

## 9. Recovery and removal

```sh
sh /data/local/dsh/bin/dshd stop                     # children + mounts down
sh /data/local/dsh/bin/dshd boot remove              # autostart off
sh /data/local/dsh/tools/firewall.sh remove          # §7 rule set out
rm -rf /data/local/dsh                               # rootfs, state, logs
```

`stop` is safe to run twice and takes the mounts down with it. `boot remove`
leaves a boot script it did not install alone — if `/data/adb/service.d/dshd.sh`
is not the copy `dshd` wrote, it says so and only flips `autostart=off`.
`firewall.sh remove` deletes only its own chain and jumps; it will not touch
rules another tool installed. Uninstalling the APK does not remove any of this:
the runtime lives in `/data/local/dsh` and in the root manager's service
directory, not in the app.

Do not delete `state/` if you care about sessions: it is `DSH_HOME`, holding
conversations and the harness's credentials. `state/guard.token` and
`state/harness.token` are 0600 and can be deleted safely — the next start mints
new ones.

## 10. What has never been run

This is a macOS development host's implementation of a device-targeted plan, and
the split is deliberate (§10). Nothing below has been executed on real hardware
**by this repository**, so treat it as the thing to verify rather than a
description of something observed:

- the APK itself: it compiles, `apksigner` verifies it, and its protocol parser
  is tested against the real `dshd` — but the UI has never been rendered, and no
  root prompt has ever been answered.
- whether Magisk, KernelSU and KernelSU-Next forward **stdin** to `su -c`. The
  payload arrives that way; if one of them does not, the fix is a different
  delivery path, not a different payload.
- what each manager's root prompt looks like, and how a *refusal* is reported —
  the app distinguishes "not root" by exit code 2 from the bootstrap, and by the
  absence of an `ok root` event.
- what umask a `su` shell starts with, on each manager. The first version of the
  app left that to the shell and got a 0775 install directory on a real device,
  which the bootstrap then refused and the app reported as a bad payload. The app
  now creates it under `umask 077` and the bootstrap closes a mode it can close,
  but the umask itself is unmeasured here.
- whether the WebView's cookie store persists the guard's session the way the
  login needs it to.
- Landlock: availability, ABI, and whether the deny is really denied. The script
  reports what it observes and refuses to round up.
- `xt_owner` in this device's kernel, `noexec` on the target path, SELinux policy
  for `mount` from a `su` context, devpts/PTY behaviour, and whether a detached
  `setsid` supervisor survives a force-stop.

**Since added, from one device:** a Xiaomi tablet on Android 16 with
KernelSU-Next (`com.rifsxd.ksunext`) rendered the APK's UI, answered the root
prompt, and ran the app's `su -c` command through a **complete setup**: the
payload verified and installed by digest, the Ubuntu base and the pinned Node
downloaded and checksummed, `@deepseek-ai/dsh@0.2.0-rc.2` installed with npm
inside the chroot, the posture recorded, and the server started —
`supervisor: running`, `harness: running …, port 3080 listening`, `guard: running
…, port 3081 listening`, `harness: 0.2.0-rc.2`, the app's status line reading
**Running**, and the harness UI answering a prompt in the app's window. Eight
defects in this repository surfaced doing it, each in a path only a device ran:
they are the entries at the end of
[`engineering.md`](engineering.md#defects-the-host-tests-caught-and-what-they-cost-on-a-device).
What the run confirms about the device, rather than about this repository:
KernelSU-Next forwards stdin to `su -c`; `su` is not on `PATH` for an app that has
not been granted (the probe reports `no su binary answered`, not exit 2); the su
context carries BusyBox applets, which is why the payload's `wget` path is the
BusyBox one; and the kernel has **no Landlock**, so the app shows its sandbox
warning — "no landlock: the agent is NOT confined to the workspace" — with the
harness running anyway, which is the documented behaviour for a device without it
([`security.md`](security.md)). Still unverified here: whether the server survives
a reboot, a swipe-away and a force-stop (P4 row), and what the firewall rule looks
like from another app's side once it is in force.

Everything in that list is a row in `docs/phase-0-probe-ledger.md` or a gate
above. Fill them in on the device you care about, and this file becomes a record
instead of a plan.
