# Security posture and proof procedure (§7)

This document is the design record for the §7 mitigation, and the procedure for
proving it on the device. It is deliberately written so that the *unproven* parts
are as visible as the proven ones: the plan's §7 says a control that is assumed
rather than tested is not a control, and the same applies to this document.

## The exposure, stated plainly

The harness is a web server that executes shell commands. On this deployment it
runs as **root**, inside a glibc rootfs, with the agent's workspace bind-mounted
in.

On Android, `127.0.0.1` is **not** an app-to-app boundary. Any app holding the
`INTERNET` permission can connect to loopback. So the unmitigated exposure is:

> any app on the device can drive a root shell.

Enabling the sidebar terminal (D6, plan §4) makes that an interactive remote
shell rather than a file-writing agent.

### Correction, measured on 0.2.0-rc.2: the harness does authenticate

This document and the plan's §7 both said upstream ships **no authentication**.
That finding came from grepping `packages/host/webserver/src/` and `apps/cli/src/`
for `token|authoriz|origin|csrf|auth`. It was true of those two paths and false of
the product: the auth lives in **`packages/client/connection`**
(`@deepseek-ai/dsh-client-connection`), the package the plan's own README already
names as the one every `/api` request *and upgrade* passes through. Grepping the
web server for auth does not find auth that sits in front of it.

Measured by booting `@deepseek-ai/dsh@0.2.0-rc.2` and issuing requests:

| Request | Result |
|---|---|
| `GET /` | **401** `dsh web authentication required; reopen the URL printed by dsh web.` |
| `GET /api` | **401** |
| `GET /?token=<launch token>` | **303** + `set-cookie: dsh-auth-<hash>=v1.<payload>.<hmac>; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict` |
| `GET /?token=<wrong>` | **401** |
| `POST /api` with a valid cookie and `Origin: http://evil.example` | **403** |
| `POST /api` with a valid cookie and `Origin: http://127.0.0.1:9999` | **403** (loopback, wrong port) |
| `--host 0.0.0.0` | **refused** — *"intentionally not supported yet for safety: it would expose remote code execution to the network"* |

So there are two upstream layers: a **Host/Origin fence** on `/api` (anti-DNS-
rebinding and anti-CSRF — explicitly *"not an auth layer"* in its own source), and
a **signed, authority-bound session cookie** whose secret is persisted `0600` in
`$DSH_HOME/.credentials.yaml`, bootstrapped by a per-process launch token the
harness prints to stdout. `timingSafeEqual` compares the token; the cookie is
`HttpOnly` and `SameSite=Strict`. The bind is loopback by default.

What that changes here, and what it does not:

- It is **no longer true** that a co-resident app can drive a root shell by
  sending `Host: 127.0.0.1:3080`. Without the launch token or the signing secret
  it gets 401, and neither is reachable without root.
- The **firewall rule is still required**, and its justification improves: it
  turns "any app may connect and be rejected" into "only two UIDs may connect at
  all", which removes the reachability that brute force, parser bugs and future
  upstream regressions would otherwise have to get past.
- The **guard is now defence in depth rather than the only lock** — which is the
  right reason to keep it, because D4 pins this deployment to a *developer
  preview* with announced breaking changes. A control we own does not disappear
  when upstream reworks its auth.
- **The security boundary moved to file permissions.** The launch token is
  printed into `$DSH_LOG/harness.log`, so the secrecy of that file is now the
  strength of the primary control, and `/data/local` is traversable on Android.
  Hence `umask 077` in `dshd` before it creates anything, `0600` on the token
  files, and `dshd url` so the APK can obtain a URL without any token being
  readable by the app's uid.
- **Root remains out of scope.** A co-resident app *with* root can read the
  token or the signing key, delete the firewall rule, or attach to the process.
  No control in this repository changes that, and none of them are claimed to.

## The two controls, and why one is not enough

| Control | What it does | What it does not do |
|---|---|---|
| `guard/guard.mjs` (`127.0.0.1:3081`) | Requires a per-install token; enforces a Host/Origin allowlist; refuses non-loopback binds; proxies HTTP, SSE, WebSocket; **replays the harness's own launch-token bootstrap** so its login yields both cookies | Cannot stop an app that talks to `127.0.0.1:3080` **directly**, bypassing it entirely |
| `tools/firewall.sh` (`DSH_ANDROID` chain) | Rejects every UID except the app's and root on both ports | Cannot stop root, the kernel, or SELinux; cannot help if `iptables`/`xt_owner` is unavailable |

Both are required. The guard is what an attacker must get past; the firewall rule
is whether they can reach it at all. Either one alone leaves the exposure open —
which is exactly the state the repository was in until `tools/firewall.sh`
existed, and the reason `dshd` refuses to start when `DSH_FIREWALL=on` and the
script is missing.

The two layers stay **independent** on purpose, and that is testable: the
guard's own cookie alone still gets a 401 from the harness. `dshd` therefore
refuses to start a guard it cannot authenticate to the harness, because a guard
that authenticates clients while the harness refuses the browser behind it is
worse than no guard at all — everything reports healthy and the UI is dead.

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

### 3b. The harness authenticates too, and the two layers are independent

This is the check that would have caught the defect this document's correction
describes, and it is the one most worth repeating after an upgrade, because
upstream's auth is the layer we do not own:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/          # 401
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/api       # 401
```

Then, through the guard, prove the login yields **two** cookies and that the
guard's alone is not enough:

```sh
# -i to see both set-cookie lines; expect 303 and a dsh-auth-* among them
curl -sS -i "http://127.0.0.1:3081/?token=$(su -c 'dshd token')"
# with only the guard cookie, the harness must still refuse:
curl -sS -o /dev/null -w '%{http_code}\n' -H "Cookie: dsh_guard=$TOKEN" \
     http://127.0.0.1:3081/                                               # 401
```

A `200` on the last line means the harness's own layer is gone — most likely an
upstream version whose auth moved or changed shape. That is a finding for the
Phase 0 ledger, not something to paper over: `tools/install-harness.sh` asserts
the same contract at install time so an upgrade announces itself.

Both ports must also **not** be reachable from a non-loopback address, and the
listening socket must be `127.0.0.1` and not `0.0.0.0`:

```sh
grep -E ':(0C1A|0C1B) ' /proc/net/tcp    # 3080/3081; the local address column
                                          # must read 0100007F, never 00000000
```

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

There are **two** secrets now, and they are different in kind:

- `state/guard.token` — ours. Generated by `dshd` with `umask 077` before the
  redirect, so the file is never briefly world-readable; `status` reports
  presence, and `tests/dshd.test.sh` asserts mode `0600`.
- `state/harness.token` — upstream's **per-process launch token**, captured by
  `dshd` from the `dsh web: http://127.0.0.1:<port>/?token=...` line the harness
  prints at startup. It is what the guard replays to obtain the harness's session
  cookie. It is regenerated on every harness start and passes through
  `$DSH_LOG/harness.log` on the way, which is why that log is `0600` and why
  `dshd` sets `umask 077` before it creates anything: on Android `/data/local` is
  traversable, so a world-readable log would hand the primary control to any
  co-resident app that can guess the path.

The rest of the handling rules apply to both:

- A **dry run never mints a token** — a credential is not a side effect of a
  rehearsal.
- The guard **fails closed** without one: there is no "auth disabled" mode to
  leave switched on by accident, and `dshd` refuses to start a guard whose
  upstream token it could not capture.
- Neither token appears in a log: the guard redacts its own token, the upstream
  token, the cookie, the bearer header, and any `?token=` query; a test asserts
  this against the real log output.
- Nothing needs to be readable by the app's uid: `dshd url` prints the URL to
  open (via `su`), so the APK never touches a token file.
- Credentials for model providers live in `DSH_HOME` (plan acceptance criterion 7)
  and are backed up by `tools/backup.sh`, never inlined into the APK or a shell
  history. `DSH_HOME` also holds `.credentials.yaml` — the harness's cookie
  **signing key** — so it is `0700`/`0600` throughout and is the single most
  sensitive directory in the deployment.
