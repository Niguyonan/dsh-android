# Security posture and proof procedure (§7)

This document is the design record for the §7 mitigation, and the procedure for
proving it on the device. It is deliberately written so that the *unproven* parts
are as visible as the proven ones: the plan's §7 says a control that is assumed
rather than tested is not a control, and the same applies to this document.

## The exposure, stated plainly

The harness is a web server that executes shell commands. On this deployment it
runs as **root**, inside a glibc rootfs, with the agent's workspace bind-mounted
in. Upstream ships **no authentication** (`packages/host/webserver/src/` has zero
matches for `token|authoriz|origin|csrf|auth`), and the only thing upstream gates
on is a loopback-derived `trustedHosts` policy — a **host allowlist, not
authentication**. A co-resident app sends `Host: 127.0.0.1:3080` and satisfies it.

On Android, `127.0.0.1` is **not** an app-to-app boundary. Any app holding the
`INTERNET` permission can connect to loopback. So the unmitigated exposure is:

> any app on the device can drive a root shell.

Enabling the sidebar terminal (D6, plan §4) makes that an interactive remote
shell rather than a file-writing agent.

## The two controls, and why one is not enough

| Control | What it does | What it does not do |
|---|---|---|
| `guard/guard.mjs` (`127.0.0.1:3081`) | Requires a per-install token; enforces a Host/Origin allowlist; refuses non-loopback binds; proxies HTTP, SSE, WebSocket | Cannot stop an app that talks to `127.0.0.1:3080` **directly**, bypassing it entirely |
| `tools/firewall.sh` (`DSH_ANDROID` chain) | Rejects every UID except the app's and root on both ports | Cannot stop root, the kernel, or SELinux; cannot help if `iptables`/`xt_owner` is unavailable |

Both are required. The guard is what an attacker must get past; the firewall rule
is whether they can reach it at all. Either one alone leaves the exposure open —
which is exactly the state the repository was in until `tools/firewall.sh`
existed, and the reason `dshd` refuses to start when `DSH_FIREWALL=on` and the
script is missing.

### What the rule set allows, and why

```
-A DSH_ANDROID -o lo -p tcp --dport 3080 -m owner --uid-owner <app>  -j ACCEPT
-A DSH_ANDROID -o lo -p tcp --dport 3080 -m owner --uid-owner 0      -j ACCEPT
-A DSH_ANDROID -o lo -p tcp --dport 3080                             -j REJECT
```

- **The app's UID** is the only unprivileged UID allowed anywhere near the ports.
- **UID 0** must be allowed because the guard's hop to the harness comes from
  root inside the rootfs. Without it, the mitigation would cut the harness off
  from its own guard and the UI would simply stop working.
- **`REJECT`, not `DROP`**, so the other app gets an immediate error rather than
  a silent hang that looks like a network fault and leaves no trace in its logs.

Rules live in a dedicated chain per table and are hooked into `OUTPUT` per port,
so `remove` and `status` act on chain membership rather than pattern-matching
rule text and can never disturb another tool's rules.

## Proof procedure (on the device)

Run as root. Every step states what a *pass* looks like, and what a failure means.

### 1. The rule set is installed and verified

```sh
su -c 'sh /data/local/dsh/tools/firewall.sh apply --uid <APP_UID>'
su -c 'sh /data/local/dsh/tools/firewall.sh status'
```

`apply` re-checks its own work with `iptables -C` before reporting success, so a
green result means the rules are present, not merely that they were issued.
`status` exits **5** when they are not.

Review the rule set without touching the device — no root, no iptables:

```sh
sh tools/firewall.sh print --uid <APP_UID>
```

### 2. A second app is actually blocked (the step that matters)

The rule set existing is not the claim. The claim is *another app cannot reach the
ports*. Test it from a UID that is neither root nor the app's:

```sh
# From a root shell, drop to an unrelated app uid and try both ports.
su -c 'setpriv --reuid=10099 --regid=10099 --clear-groups sh -c \
  "echo > /dev/tcp/127.0.0.1/3080" ; echo "exit=$?"'
```

- **Pass:** connection refused / permission denied, and the guard port behaves the
  same way.
- **Fail (connection succeeds):** the mitigation is not in effect. Check
  `firewall.sh status`, then `dmesg | grep -i avc` — SELinux denials on netfilter
  from a Magisk `su` context are a known failure mode and belong in the Phase 0
  ledger.

If `/dev/tcp` is unavailable in the shell you have, any client works: a two-line
app, `nc`, or a `toybox` equivalent. What matters is the **source UID**, which is
why this cannot be tested from a root shell.

### 3. The guard rejects what does reach it

From the app's UID (or a root shell, which the rules allow):

```sh
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3081/          # 401
curl -sS -o /dev/null -w '%{http_code}\n' -H "x-dsh-token: $TOKEN" \
     http://127.0.0.1:3081/__guard/health                                 # 200
```

`dshd token` prints the token (via `su`). A `200` on the first line means the
guard is not enforcing and must be treated as a compromise of the whole posture.

### 4. Re-run after every kernel or ROM update

Landlock, `xt_owner`, and SELinux policy are kernel/ROM properties, not device
properties. The rule set that verified last month is not evidence about this
month's kernel — re-run this procedure, and the Phase 0 probe table with it.

## What this design does not defend against

Stated so that nobody mistakes the controls for something stronger:

- **Root, and anything running as root.** The rules allow UID 0 by necessity, and
  a rooted device has many ways to acquire it — under KernelSU, `su` is granted
  per app by the manager, but the kernel-side root is one policy change away.
  This posture protects against *other apps*, which is the actual threat model on
  a single-user device.
- **An app that shares the allowed UID** — including a compromised WebView
  process, or anything injected into it. The token lives in the app's process.
- **A kernel without `xt_owner` or with SELinux blocking netfilter.** The script
  fails loudly (exit 4, with the reason in `dshd`'s log) rather than pretending,
  but the exposure remains open until that is fixed. `tools/probe.sh` answers
  whether the owner match exists before you rely on it, and the answer is a
  property of your kernel, not of Magisk vs KernelSU — see
  [`root-solutions.md`](./root-solutions.md).
- **Shoulder-surfing, screenshots, and the notification.** Out of scope.
- **Supply-chain risk in the harness itself.** Upstream is a developer preview;
  the version is pinned (`tools/install-harness.sh`) and rollback exists.

## Token handling

- Generated by `dshd` at `state/guard.token` with `umask 077` before the redirect,
  so the file is never briefly world-readable; `status` reports presence, and
  `tests/dshd.test.sh` asserts mode `0600`.
- A **dry run never mints a token** — a credential is not a side effect of a
  rehearsal.
- The guard **fails closed** without one: there is no "auth disabled" mode to
  leave switched on by accident.
- The token never appears in a log: the guard redacts the cookie, the bearer
  header, and any `?token=` query, and a test asserts it against the real log
  output.
- Credentials for model providers live in `DSH_HOME` (plan acceptance criterion 7)
  and are backed up by `tools/backup.sh`, never inlined into the APK or a shell
  history.
