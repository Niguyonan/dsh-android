#!/bin/sh
# Host-side test entry point for dsh-android.
#
# Ten suites, all runnable on any machine with `sh` (the guard suite and the
# Phase 2 smoke test also need Node; the APK suite needs a JDK and an Android SDK
# and skips, loudly, without them):
#
#   * guard/test/guard.test.mjs — the §7 guard: token auth, Host/Origin policy,
#     loopback-bind enforcement, HTTP/SSE/WebSocket proxying, and the teardown
#     of upgraded sockets.
#   * tests/dshd.test.sh       — bin/dshd's lifecycle: exit-code contract,
#     posture resolution, token handling, stale-PID sweeping, log rotation, the
#     firewall handover, and the supervisor's pair semantics against the real
#     guard.
#   * tests/firewall.test.sh   — tools/firewall.sh's rule set, driven against a
#     fake iptables: apply, verify, tamper detection, removal, idempotence.
#   * tests/probe.test.sh      — tools/probe.sh's contract and verdicts, with the
#     device stubbed out: it must fail loudly on a host, not quietly.
#   * tests/rootfs-setup.test.sh — tools/rootfs-setup.sh, with local tarballs
#     instead of downloads: extraction, checksums, the refusal to clobber, and
#     the paths that only break on a re-run.
#   * tests/install-harness.test.sh — tools/install-harness.sh, with the registry
#     and the chroot stubbed: the version pin, --ignore-scripts, the manifest,
#     and the Phase 2 contract asserted against a stand-in harness that can be
#     told to satisfy it, ignore it, or bind the wrong interface.
#   * tests/setup.test.sh     — `dshd setup`, the one command the APK runs: step
#     order and failure propagation, the skip-not-repeat rule, the protocol the
#     app renders, the inputs it refuses, and the two failures the plan calls
#     survivable (an unenforceable firewall, an unprovable sandbox).
#   * tests/payload.test.sh   — tools/mkpayload.sh and android/payload/
#     bootstrap.sh: what can and cannot get into the archive that root installs,
#     and what happens when the transfer is truncated, a file is tampered with,
#     the install directory is writable by another uid, or there is no sha256 to
#     verify with.
#   * tests/docs.test.sh      — the documentation's checkable claims: every
#     script and verb it names exists, every path in the README's layout table
#     exists, and every suite in tests/ is one that runs.
#   * tests/apk.test.sh       — android/build.sh and the APK it produces: a
#     signed, verifiable artifact, its permissions and cleartext policy, the
#     payload inside it compared byte for byte with the working tree, and
#     Protocol.java driven with the real dshd's output. Skips without a JDK and
#     an Android SDK, loudly.
#
# None of them can prove anything kernel-level: mounts, devpts, chroot,
# Landlock and SELinux are Phase 0 probes on the device. See PORTING-PLAN.md §5.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
cd "$REPO" || exit 1

failed=0

printf '== documentation claims ==\n'
sh tests/docs.test.sh || failed=1

printf '== guard (§7) ==\n'
if command -v node >/dev/null 2>&1; then
  node --test "guard/test/*.test.mjs" || failed=1
else
  printf 'skip: node is not installed\n'
fi

printf '\n== §7 firewall rule ==\n'
sh tests/firewall.test.sh || failed=1

printf '\n== Phase 0 probes ==\n'
sh tests/probe.test.sh || failed=1

printf '\n== Phase 1 rootfs ==\n'
sh tests/rootfs-setup.test.sh || failed=1

printf '\n== Phase 2 harness install ==\n'
sh tests/install-harness.test.sh || failed=1

printf '\n== Phase 5 payload ==\n'
sh tests/payload.test.sh || failed=1

printf '\n== Phase 5 setup orchestrator ==\n'
sh tests/setup.test.sh || failed=1

printf '\n== Phase 5 APK ==\n'
sh tests/apk.test.sh || failed=1

printf '\n== dshd lifecycle ==\n'
sh tests/dshd.test.sh || failed=1

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'all host-side suites passed\n'
else
  printf 'FAILURES — see the output above\n'
fi
exit "$failed"
