#!/bin/sh
# Host-side tests for the APK: the build, the artifact, and the one part of the
# app whose correctness a development host can actually decide.
#
# The app cannot be run here — it needs a phone and root — so this suite is
# deliberately split into what can be *proved* on a laptop and what is merely
# asserted, and it only does the former:
#
#   * android/build.sh produces a signed APK that apksigner verifies, with the
#     permissions, exported components and cleartext policy the manifest claims
#   * the payload inside the APK is byte-identical to the payload in the working
#     tree, so "what root installs" and "what the app ships" cannot drift
#   * the path the app hands to su exists in the payload the app ships — a Java
#     constant and a tar member agreeing is a real contract, and it is the one
#     that would fail on a device at the worst moment
#   * every verb the app can send is a verb dshd dispatches, derived from both
#     sides rather than listed here
#   * Protocol.java parses the output of the *real* dshd, and its two-signal
#     success rule refuses a run that says `done ok` and then exits non-zero
#
# It skips, loudly, when there is no JDK or no Android SDK: a green suite that
# quietly tested nothing would be worse than no suite.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
BUILD="$REPO/android/build.sh"
SHELL_JAVA="$REPO/android/src/dev/dshd/app/Shell.java"
PROTO_JAVA="$REPO/android/src/dev/dshd/app/Protocol.java"
DSHD="$REPO/bin/dshd"

[ -f "$BUILD" ] || { echo "android/build.sh not found at $BUILD" >&2; exit 1; }

# --- tiny test framework ----------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '     %s\n' "$2"
  return 0
}

skip() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf 'skip %s (%s)\n' "$1" "${2:-}"
}

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain [$2] in: $(printf '%s' "$3" | tail -n 8)" ;;
  esac
}

lacks() {
  case "$3" in
    *"$2"*) fail "$1" "did not expect [$2] in: $(printf '%s' "$3" | tail -n 8)" ;;
    *) pass "$1" ;;
  esac
}

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

TMP=$(mktemp -d "${TMPDIR:-/tmp}/apk-test.XXXXXX") || exit 1

have_jdk() { command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; }

# --- protocol parser, against the real dshd ---------------------------------

printf '\n== the app reads what dshd says ==\n'

if have_jdk; then
  mkdir -p "$TMP/classes"
  if javac -source 8 -target 8 -Xlint:-options -d "$TMP/classes" "$PROTO_JAVA" 2>"$TMP/javac.err"; then
    pass "Protocol.java compiles with plain javac (no Android on the classpath)"
  else
    fail "Protocol.java compiles with plain javac" "$(head -3 "$TMP/javac.err")"
  fi

  parse() {
    java -cp "$TMP/classes" dev.dshd.app.Protocol "$@" 2>&1
  }

  # A real run: the same stubs tests/setup.test.sh uses, because the point is to
  # feed the parser the bytes dshd actually writes, not a fixture shaped like
  # them.
  BASE="$TMP/dsh"
  mkdir -p "$BASE/bin" "$BASE/tools" "$BASE/state" "$BASE/log" "$BASE/etc" "$BASE/run" \
    "$BASE/rootfs/bin" "$BASE/rootfs/usr/local/bin"
  cp "$DSHD" "$BASE/bin/dshd"
  for f in bin/sh usr/local/bin/node usr/local/bin/dsh; do
    printf '#!/bin/sh\nexit 0\n' >"$BASE/rootfs/$f"
    chmod 755 "$BASE/rootfs/$f"
  done
  for t in probe.sh rootfs-setup.sh install-harness.sh firewall.sh; do
    printf '#!/bin/sh\nexit 0\n' >"$BASE/tools/$t"
    chmod 755 "$BASE/tools/$t"
  done
  cat >"$BASE/tools/confinement-check.sh" <<'EOF'
#!/bin/sh
save=""
while [ $# -gt 0 ]; do
  case "$1" in --save) shift; save=${1:-} ;; esac
  shift
done
( umask 077; printf 'confinement=landlock-full, a denied write was observed\npermission_mode=workspace-write\nprobe=full\ndeny=proven\n' >"${save:-$DSH_STATE/posture.conf}" )
exit 0
EOF
  chmod 755 "$BASE/tools/confinement-check.sh"
  printf 'a-guard-token\n' >"$BASE/state/guard.token"

  DSH_BASE="$BASE" DSHD_DRY_RUN=1 sh "$BASE/bin/dshd" setup --app-uid 10123 \
    >"$TMP/real-setup.txt" 2>&1
  out=$(parse --exit 0 <"$TMP/real-setup.txt")

  contains "it reports success for a real successful run" "ok=true" "$out"
  check "it sees every step exactly once" "7" "$(printf '%s\n' "$out" | grep -c '^step  |')"
  contains "the first step is the device probe" "step  | probe state=1" "$out"
  contains "the last step is the server" "step  | start state=1" "$out"
  check "the run is identified by a nonce" "yes" \
    "$(printf '%s\n' "$out" | grep -q '^nonce=.' && echo yes || echo no)"
  lacks "no nonce conflict in a single run" "conflict=true" "$out"
  contains "it keeps the url" "url=http://127.0.0.1:3081/?token=a-guard-token" "$out"

  # The two-signal rule: a run that says it succeeded and then exits non-zero is
  # a failure. That is the shape of a truncated pipe or a shell that died
  # mid-sentence, and it must not be rendered as a working app.
  out=$(parse --exit 1 <"$TMP/real-setup.txt")
  contains "done ok with a non-zero exit is not success" "ok=false" "$out"
  contains "and it says which two things disagreed" \
    "the setup reported success and then exited 1" "$out"

  # A failing run: the step that failed is the diagnosis the screen shows.
  printf '##dshd 42 step firewall keeping other apps off the ports\n##dshd 42 fail firewall exit 5\ndone\n' \
    >"$TMP/fail.txt"
  out=$(parse --exit 5 <"$TMP/fail.txt")
  contains "a failed step is named" "setup failed at firewall: exit 5" "$out"
  check "and that step is marked failed" "1" "$(printf '%s\n' "$out" | grep -c 'firewall state=3')"

  # Not root, told apart from everything else. The bytes are the real bootstrap's,
  # refused at its first check: this is the end-to-end proof that a refusal
  # reaches the screen with the words the script wrote, and not with a summary
  # derived from the exit code.
  sh "$REPO/tools/mkpayload.sh" --out "$TMP/proto" --quiet || fail "cannot build a payload to refuse"
  mkdir -p "$TMP/bin-nonroot"
  printf '#!/bin/sh\necho 2000\n' >"$TMP/bin-nonroot/id"
  chmod 755 "$TMP/bin-nonroot/id"
  cat "$TMP/proto/payload.tar" | PATH="$TMP/bin-nonroot:$PATH" DSH_BASE="$TMP/boot-base" \
    sh "$REPO/android/payload/bootstrap.sh" setup --app-uid 10123 \
    >"$TMP/boot-nonroot.txt" 2>&1
  boot_rc=$?
  check "the real bootstrap refuses a non-root shell with exit 2" "2" "$boot_rc"
  out=$(parse --exit 2 <"$TMP/boot-nonroot.txt")
  contains "and the screen names the check that refused" "setup failed at root" "$out"
  contains "with the sentence the script wrote, not a summary" "not root" "$out"
  check "and the refusal created nothing" "no" \
    "$([ -e "$TMP/boot-base" ] && echo yes || echo no)"

  # The order of that judgement is a fix, not a preference: exit 6 used to answer
  # first, and it covers every refusal the bootstrap can make, so a root-owned
  # directory left group-writable by a previous run reached the screen as a
  # corrupt payload. A named check outranks the code.
  printf '##dshd pre step base checking /data/local/dsh\n##dshd pre fail base /data/local/dsh is mode 0775 and the group or other write bits could not be closed on it\n' \
    >"$TMP/base.txt"
  out=$(parse --exit 7 <"$TMP/base.txt")
  contains "a named check outranks the exit-code summary" "setup failed at base" "$out"
  contains "and the reason is the script's own sentence" "could not be closed" "$out"
  lacks "not the payload story the exit code would have told" "did not verify" "$out"

  # The codes are still the fallback when nothing named a step: an older payload
  # on the device, or a stream cut off before a refusal finished its sentence.
  printf '##dshd 42 step payload installing the app payload\n' >"$TMP/bare.txt"
  out=$(parse --exit 6 <"$TMP/bare.txt")
  contains "exit 6 with no named step still reads as a payload problem" \
    "the payload did not verify" "$out"
  out=$(parse --exit 7 <"$TMP/bare.txt")
  contains "exit 7 with no named step reads as an install directory problem" \
    "the install directory is not safe" "$out"
  out=$(parse --exit 2 <"$TMP/bare.txt")
  contains "exit 2 with no named step reads as a root problem" "root was not granted" "$out"

  # A stream that stops without a done event.
  printf '##dshd 42 step probe checking\n' >"$TMP/short.txt"
  out=$(parse --exit 5 <"$TMP/short.txt")
  contains "a run that never finished says so" "the setup stopped without saying why" "$out"

  # Unknown kinds are kept, not dropped: an older app and a newer dshd is a
  # normal pairing, and silence is how a progress list hangs forever.
  printf '##dshd 42 step probe checking\n##dshd 42 shiny new thing\n' >"$TMP/unknown.txt"
  out=$(parse --exit 0 <"$TMP/unknown.txt")
  contains "an unknown event kind is surfaced" "unknown:shiny" "$out"
  contains "and does not stop the run from parsing" "step  | probe" "$out"

  # Two nonces on one pipe: two writers. Flagged, not merged.
  printf '##dshd aa step probe one\n##dshd bb step rootfs two\n' >"$TMP/two.txt"
  out=$(parse --exit 0 <"$TMP/two.txt")
  contains "a second nonce in one stream is flagged" "conflict=true" "$out"

  # Ordinary output is not protocol: the log pane shows it, the steps do not.
  printf 'npm notice total files: 11\n##dshd 42 step probe checking\n' >"$TMP/noise.txt"
  out=$(parse --exit 0 <"$TMP/noise.txt")
  contains "ordinary output is passed through as raw" "raw   | npm notice" "$out"
  check "and does not become a step" "1" "$(printf '%s\n' "$out" | grep -c '^step  |')"
else
  skip "the protocol parser is exercised against real dshd output" "no JDK"
fi

# --- source-level invariants ------------------------------------------------

printf '\n== what the app must not do ==\n'

sources=$(cat "$SELF_DIR/../android/src/dev/dshd/app/"*.java)

# The *call*, not the word: the sources mention the bridge in order to say why
# there isn't one, and a check that cannot tell a comment from a call would have
# to be deleted the moment someone documented the decision.
lacks "no JavaScript bridge into a root-holding app" "addJavascriptInterface(" "$sources"
contains "and the absence is a decision, written down" "no addJavascriptInterface" "$sources"
lacks "no file: access for the page" "setAllowFileAccess(true)" "$sources"
contains "file access is off" "setAllowFileAccess(false)" "$sources"
contains "content access is off" "setAllowContentAccess(false)" "$sources"
contains "mixed content is refused" "MIXED_CONTENT_NEVER_ALLOW" "$sources"
contains "the WebView is created without a view id" "No view id on purpose" "$sources"

# The one command the app sends to root, and the mode it creates the install
# directory with. That directory is where root runs scripts from, and leaving its
# mode to the umask of whatever `su` shell the device happens to start is how a
# first run got a 0775 base that the bootstrap then refused. The check is on the
# source because the command is built in Java that needs Android to run.
contains "the app creates the install directory closed to everyone else" \
  "(umask 077; mkdir -p" "$(grep -o 'b.append("S=").*' "$SHELL_JAVA")"

# The two Java-8 APIs that exist on Android only from API 26, which this app does
# not require. Both were hit while writing it; both are silent NoSuchMethodError
# crashes on an Android 7 device.
lacks "no String.join (API 26)" "String.join(" "$sources"
lacks "no Process.waitFor with a timeout (API 26)" "waitFor(120" "$sources"
contains "the bounded wait is hand-rolled for API 24" "polling" "$sources"

# --- the payload the app ships ----------------------------------------------

printf '\n== the payload inside the APK ==\n'

mkdir -p "$TMP/assets"
sh "$REPO/tools/mkpayload.sh" --out "$TMP/assets" --quiet || fail "mkpayload.sh failed"

TAR_MEMBERS=$(tar -tf "$TMP/assets/payload.tar" | sed -e 's|^\./||' | grep -v '/$' | grep .)
contains "the payload installs bootstrap.sh where the app looks for it" "bootstrap.sh" "$TAR_MEMBERS"

# The app's constant and the archive's layout, checked against each other. This
# is the pair that has to agree for `su -c` to work at all on a device, and
# nothing else in the repository would notice if they stopped agreeing.
stage=$(sed -n 's/.*public static final String STAGE = \(.*\);/\1/p' "$SHELL_JAVA")
base=$(sed -n 's/.*public static final String BASE = \(.*\);/\1/p' "$SHELL_JAVA")
check "the app and the bootstrap agree on the base" '"/data/local/dsh"' "$base"
check "the stage directory is under the base" 'BASE + "/.stage"' "$stage"
contains "and the app's bootstrap path is the payload's own file" \
  'BOOTSTRAP = STAGE + "/bootstrap.sh"' "$(grep -o 'BOOTSTRAP = .*;' "$SHELL_JAVA")"

# Every verb the app can send must be one dshd dispatches.
app_verbs=$(sed -n '/private static final String\[\] VERBS/,/};/p' "$SHELL_JAVA" |
  grep -o '"[a-z]*"' | tr -d '"' | LC_ALL=C sort -u)
unknown=""
for verb in $app_verbs; do
  grep -qE "^ *$verb\) " "$DSHD" || unknown="$unknown $verb"
done
check "every verb the app sends is a verb dshd dispatches" "" "$unknown"

# --- the build --------------------------------------------------------------

printf '\n== the APK ==\n'

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  skip "the APK builds, verifies, and carries the payload" "no Android SDK (ANDROID_HOME unset)"
else
  APK="$TMP/out/dshd-test.apk"
  out=$(sh "$BUILD" --out "$APK" 2>&1)
  rc=$?
  if [ "$rc" != 0 ]; then
    fail "android/build.sh exits 0" "$(printf '%s' "$out" | tail -5)"
  else
    pass "android/build.sh exits 0"
  fi

  if [ -f "$APK" ]; then
    BT=$(ls "$SDK/build-tools" | sort -n | tail -n 1)
    BT="$SDK/build-tools/$BT"

    "$BT/apksigner" verify --min-sdk-version 24 "$APK" >/dev/null 2>&1 &&
      pass "the APK verifies" || fail "the APK verifies"

    badging=$("$BT/aapt2" dump badging "$APK" 2>/dev/null)
    contains "the package name is the one the manifest claims" "package: name='dev.dshd.app'" "$badging"
    contains "minSdk is 24" "minSdkVersion:'24'" "$badging"
    contains "and it targets 34" "targetSdkVersion:'34'" "$badging"
    contains "the launcher activity is declared" "launchable-activity: name='dev.dshd.app.MainActivity'" "$badging"
    contains "INTERNET is requested" "android.permission.INTERNET" "$badging"
    contains "the foreground service type is declared" "android.permission.FOREGROUND_SERVICE_DATA_SYNC" "$badging"
    lacks "nothing asks for storage access" "WRITE_EXTERNAL_STORAGE" "$badging"
    lacks "nothing asks to install packages" "REQUEST_INSTALL_PACKAGES" "$badging"

    tree=$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null)
    contains "backup is off: the cookie store is a credential" "allowBackup" "$tree"
    contains "and it is false" "allowBackup(0x01010280)=false" "$tree"
    contains "cleartext is not enabled globally" "usesCleartextTraffic(0x010104ec)=false" "$tree"
    contains "a network security config is set" "networkSecurityConfig" "$tree"
    check "exactly one component is exported" "1" "$(printf '%s\n' "$tree" | grep -c 'exported(0x01010010)=true')"
    check "and one is not" "1" "$(printf '%s\n' "$tree" | grep -c 'exported(0x01010010)=false')"
    contains "the service is a dataSync foreground service" "foregroundServiceType(0x01010599)=0x00000001" "$tree"

    nsc=$("$BT/aapt2" dump xmltree --file res/xml/network_security_config.xml "$APK" 2>/dev/null)
    contains "cleartext is off by default in the config" "cleartextTrafficPermitted=false" "$nsc"
    contains "and on for loopback" "127.0.0.1" "$nsc"
    check "loopback is the only exception" "1" "$(printf '%s\n' "$nsc" | grep -c 'cleartextTrafficPermitted=true')"

    # The asset must be the payload that was built here, byte for byte: the app
    # installs what it ships, and this is the only thing that proves it.
    unzip -p "$APK" assets/payload.tar >"$TMP/from-apk.tar" 2>/dev/null
    if cmp -s "$TMP/from-apk.tar" "$TMP/assets/payload.tar"; then
      pass "the APK carries exactly the payload in the working tree"
    else
      fail "the APK carries exactly the payload in the working tree" \
        "built $(wc -c <"$TMP/assets/payload.tar" | tr -d ' ') bytes, in the APK $(wc -c <"$TMP/from-apk.tar" | tr -d ' ') bytes: $(cmp -l "$TMP/assets/payload.tar" "$TMP/from-apk.tar" 2>&1 | head -2 | tr '\n' ' ')"
    fi

    # And the command the app will send to su is in the dex it ships, not only in
    # the source: the mode the install directory is created with is the difference
    # between a first run that works and one that refuses its own directory.
    # grep -a, because a dex is binary and grep would otherwise say "Binary file
    # matches" and count nothing.
    unzip -p "$APK" classes.dex >"$TMP/classes.dex" 2>/dev/null
    check "the shipped dex creates the staging directory under umask 077" "1" \
      "$(grep -ac -- '(umask 077; mkdir -p "$S")' "$TMP/classes.dex")"
    check "and still streams the payload into tar" "1" \
      "$(grep -ac -- ' && tar -xf - -C "$S"' "$TMP/classes.dex")"
    unzip -p "$APK" assets/payload.id >"$TMP/from-apk.id" 2>/dev/null
    check "and the payload id the app compares against" "$(cat "$TMP/assets/payload.id")" "$(cat "$TMP/from-apk.id")"

    unzip -l "$APK" | grep -q 'classes.dex' && pass "the APK has code in it" || fail "the APK has code in it"

    # A *relative* --out, from the repository root, which is how the release
    # workflow calls it. build.sh cd's into its build directory to package, so
    # this is the case that put the APK somewhere nobody looked and let a release
    # publish no artifact at all.
    rm -rf "$TMP/rel" && mkdir -p "$TMP/rel"
    ( cd "$TMP/rel" && sh "$BUILD" --out dist/relative.apk --no-payload >/dev/null 2>&1 )
    check "a relative --out lands where the caller asked" "yes" \
      "$([ -f "$TMP/rel/dist/relative.apk" ] && echo yes || echo no)"
  else
    fail "the APK exists"
  fi
fi

printf '\n%d checks, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
