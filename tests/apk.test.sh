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

  # `check` is a query, and the bytes below are the ones a phone wrote when it was
  # asked: `setup --check` on a device that is simply not set up yet. It exits 3 —
  # "not running", the code the runbook documents for exactly this — and it never
  # says `done ok`, because it is not doing anything. Judged by the setup rule,
  # that screen read "Setup stopped — the setup stopped without saying why (exit
  # 3)" every time the app opened, above a header that already said "Not set up",
  # and on a healthy device, where this check exits 0, the same sentence came back
  # with a 0 in it.
  cat >"$TMP/check-fresh.txt" <<'EOF'
##dshd check info installed no
##dshd check info harness no
##dshd check info running no
##dshd check info posture unresolved (run tools/confinement-check.sh)
##dshd check info root kernelsu-next
##dshd check info app_uid unset
EOF
  out=$(parse --exit 3 --verb check <"$TMP/check-fresh.txt")
  contains "a check that answered is not a failure" "ok=true" "$out"
  contains "and has nothing to report as broken" "reason=null" "$out"
  contains "with the answer still on the info lines" "info  | installed = no" "$out"

  # The same bytes as a *setup* that exited 3: still a failure, which is the half
  # that must not move.
  out=$(parse --exit 3 <"$TMP/check-fresh.txt")
  contains "the same exit from a setup is still one" "ok=false" "$out"
  contains "and says so" "the setup stopped without saying why (exit 3)" "$out"

  # A check whose exit is 0 because the device *is* set up: it says no `done ok`
  # either, and it is not a failure for that.
  printf '##dshd check info installed yes\n##dshd check info running yes\n' >"$TMP/check-ok.txt"
  out=$(parse --exit 0 --verb check <"$TMP/check-ok.txt")
  contains "a healthy check is a success" "ok=true" "$out"

  # And the narrow half: a check that answered nothing, or that named a failure,
  # is still a failure — the rule must not turn a broken run into a quiet screen.
  out=$(parse --exit 3 --verb check </dev/null)
  contains "a check that answered nothing is a failure" "ok=false" "$out"
  printf '##dshd check info installed no\n##dshd check fail payload the payload did not extract\n' \
    >"$TMP/check-failed.txt"
  out=$(parse --exit 6 --verb check <"$TMP/check-failed.txt")
  contains "and so is a check that named a failing step" "ok=false" "$out"
  contains "with the step that failed" "setup failed at payload" "$out"
  printf '##dshd check info installed no\n' >"$TMP/check-nonroot.txt"
  out=$(parse --exit 2 --verb check <"$TMP/check-nonroot.txt")
  contains "and a check that could not ask is one too" "ok=false" "$out"
  contains "because root was not granted" "root was not granted" "$out"

  # The verbs that are not `setup` and do not say `done ok` either — start, stop,
  # status, url, logs, token, mounts, boot. dshd answers those with a status block
  # and an exit code, and the setup rule read every one of them as a failure: the
  # device below was running perfectly, and the screen said "Setup stopped — the
  # setup stopped without saying why (exit 0)" over the status it had just asked
  # for. The bytes are that status's shape, from the line dshd prints first.
  printf 'supervisor:  running (pid 30266)\nharness:     running (pid 30289), port 3080 listening\nguard:       running (pid 30395), port 3081 listening\n' \
    >"$TMP/started.txt"
  out=$(parse --exit 0 --verb start <"$TMP/started.txt")
  contains "a start that exited 0 is a success" "ok=true" "$out"
  contains "and has nothing to report as broken" "reason=null" "$out"
  out=$(parse --exit 1 --verb start <"$TMP/started.txt")
  contains "a start that exited 1 is not" "ok=false" "$out"
  contains "and says which command refused" "start exited 1" "$out"
  out=$(parse --exit 0 --verb status <"$TMP/started.txt")
  contains "and a status that answered is a success too" "ok=true" "$out"
  # The setup rule is untouched: a setup that never said `done ok` is still not a
  # success, whatever it exited with.
  out=$(parse --exit 0 <"$TMP/started.txt")
  contains "a setup with no done line is still not a success" "ok=false" "$out"
  contains "and still says so" "the setup stopped without saying why (exit 0)" "$out"

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

# --- the download decisions -------------------------------------------------

printf '\n== what the app will and will not save ==\n'

DOWNLOAD_JAVA="$REPO/android/src/dev/dshd/app/Download.java"

if have_jdk; then
  mkdir -p "$TMP/dl"
  if javac -source 8 -target 8 -Xlint:-options -d "$TMP/dl" "$DOWNLOAD_JAVA" 2>"$TMP/dl.err"; then
    pass "Download.java compiles with plain javac (no Android on the classpath)"
  else
    fail "Download.java compiles with plain javac" "$(head -3 "$TMP/dl.err")"
  fi

  GUARD=http://127.0.0.1:3081
  dl() { java -cp "$TMP/dl" dev.dshd.app.Download "$1" "$2" "$3" 2>&1; }
  # The driver prints both decisions; the name is the line after the refusal, and
  # comparing the whole answer is how one of them silently stops being tested.
  name_of() { printf '%s\n' "$1" | sed -n 's/^name=//p'; }

  # The harness's own bytes. `dsh-client-ui-deliverables`' sibling
  # dsh-session-log-export answers its menu item by clicking an anchor on this
  # route, and the route replies with `attachment; filename="dsh-session-…zip"`.
  # A WebView hands that click to DownloadListener and an app with no listener
  # saves nothing: the dialog said the browser was downloading the ZIP and there
  # was no file in any folder.
  out=$(dl 'attachment; filename="dsh-session-abc.zip"' \
    "$GUARD/api/session.export?sessionId=abc&includeDescendants=true" "$GUARD")
  contains "the harness's own download is answered" "refuse=null" "$out"
  contains "and it is saved under the name the response gave" "name=dsh-session-abc.zip" "$out"

  # A name is a name, not a path. Content-Disposition is a header from a server
  # and this app is the one running as root and writing the file.
  out=$(dl 'attachment; filename="../../databases/dshd"' "$GUARD/api/session.export" "$GUARD")
  contains "a name that climbs out of the folder is cut to one segment" "name=dshd" "$out"
  out=$(dl "attachment; filename*=UTF-8''%2e%2e%2f%2e%2e%2fetc%2fpasswd" "$GUARD/api/x" "$GUARD")
  contains "and the same through a percent-encoded one" "name=passwd" "$out"
  out=$(dl 'attachment; filename="a/b/c/report.zip"' "$GUARD/api/x" "$GUARD")
  check "a quoted absolute-looking path keeps only its last segment" "report.zip" "$(name_of "$out")"

  # The other encodings a real server sends, and the ones the harness does not.
  out=$(dl "attachment; filename*=UTF-8''dsh%20session%20log.zip" "$GUARD/api/x" "$GUARD")
  check "RFC 5987 ext-value names survive decoding" "dsh session log.zip" "$(name_of "$out")"
  out=$(dl 'attachment; filename="session log.zip"' "$GUARD/api/x" "$GUARD")
  check "a quoted name keeps its spaces" "session log.zip" "$(name_of "$out")"
  out=$(dl 'attachment; filename=bare.zip' "$GUARD/api/x" "$GUARD")
  check "and an unquoted one is read too" "bare.zip" "$(name_of "$out")"
  out=$(dl 'attachment; filename="re:port?.zip"' "$GUARD/api/x" "$GUARD")
  check "characters a filesystem refuses are dropped" "report.zip" "$(name_of "$out")"

  # With no header at all the URL's last segment is the name, percent-decoded,
  # with the query and fragment left out of it.
  out=$(dl - "$GUARD/api/workspace/report%20final.pdf?rev=3#top" "$GUARD")
  check "a URL names the file when the response does not" "report final.pdf" "$(name_of "$out")"
  out=$(dl - "$GUARD/" "$GUARD")
  check "and a URL with no name at all falls back" "download" "$(name_of "$out")"
  out=$(dl 'attachment; filename=""' "$GUARD/" "$GUARD")
  check "an empty name in the header falls back too" "download" "$(name_of "$out")"

  # What must never be fetched. The page is agent-generated output and this app
  # holds a session cookie for one loopback server.
  out=$(dl - "blob:$GUARD/6f1e" "$GUARD")
  contains "a file the page made in the renderer is refused" "refuse=generated" "$out"
  out=$(dl - "data:text/plain,hello" "$GUARD")
  contains "and so is a data: URL" "refuse=generated" "$out"
  out=$(dl 'attachment; filename="x.zip"' "http://evil.example/x.zip" "$GUARD")
  contains "a download from another host is refused" "refuse=external" "$out"
  # The boundary, not the first characters: a prefix check that stops at
  # startsWith lets a server on port 30810 answer for a login pinned to 3081.
  out=$(dl 'attachment; filename="x.zip"' "http://127.0.0.1:30810/x.zip" "$GUARD")
  contains "a host that merely starts with the origin is refused" "refuse=external" "$out"
  out=$(dl - "file:///data/local/dsh/workspace/x" "$GUARD")
  contains "a file: URL is refused" "refuse=scheme" "$out"
  out=$(dl - - "$GUARD")
  contains "and a download with no URL is not guessed at" "refuse=scheme" "$out"
  out=$(dl - "$GUARD/api/x" -)
  contains "nothing is fetched before a page has pinned an origin" "refuse=external" "$out"
  # The same origin with a path, a query and no path at all is the one that is
  # answered: a rule that refuses these would be a rule that never saves.
  for u in "$GUARD/api/x" "$GUARD/?a=1" "$GUARD"; do
    out=$(dl - "$u" "$GUARD")
    contains "the pinned origin itself is answered: $u" "refuse=null" "$out"
  done
else
  skip "the download decisions are exercised on the host" "no JDK"
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

# The page's file input. A WebView hands <input type="file"> to a
# WebChromeClient, and an app that has none is answered *for* it with null: no
# picker, no error, nothing the page can report. The harness attaches files with
# that input, and it does so in a browser — which is exactly why this looked like
# an app that could not upload while the browser could.
contains "the page's file input is answered at all" "onShowFileChooser" "$sources"
contains "with an intent built from the page's own parameters" \
  "params.createIntent()" "$sources"
contains "and the answer is tied to the request that asked" "REQUEST_PICK_FILES" "$sources"
# FileChooserParams.parseResult reads intent.getData() and nothing else, and the
# system picker returns a multiple selection as ClipData with no data URI at all.
# The harness's input is `multiple`, so that difference is every file after the
# first — silently dropped, in a page that saw one arrive.
contains "a multiple selection is read from the ClipData" "data.getClipData()" "$sources"
# The result of a picker is untrusted, and the platform's own documentation says
# it can name this app's private files. Content URIs are taken; file URIs are
# taken only from outside this app's data directory.
contains "a picked file that is this app's own is refused" \
  "getApplicationInfo().dataDir" "$sources"
contains "compared on canonical paths, not on spelling" "getCanonicalPath()" "$sources"

# The page's downloads. The same shape in the other direction: a WebView saves
# nothing by itself, so the harness's "Download session log" reported success and
# wrote no file anywhere. The app fetches the bytes itself — with the WebView's
# own cookie, because the session that authenticates the page is a cookie, and
# without following a redirect, because the one origin it trusts is the one it
# pinned — and it says where the file went.
contains "the page's downloads are answered at all" "onDownloadStart" "$sources"
contains "by a listener that is set on the WebView" "setDownloadListener" "$sources"
contains "the request carries the session the page is using" \
  "CookieManager.getInstance().getCookie" "$sources"
contains "and does not follow a redirect off the pinned origin" \
  "setInstanceFollowRedirects(false)" "$sources"
contains "the decision to fetch is Download.java's, not a second copy here" \
  "Download.refuse(url, allowedPrefix)" "$sources"
contains "public Downloads takes the file where the platform has one" \
  "MediaStore.Downloads.EXTERNAL_CONTENT_URI" "$sources"
contains "and before that, this app's own directory rather than a permission" \
  "getExternalFilesDir" "$sources"
contains "the message says where the file is, which is what was missing" \
  "R.string.download_saved" "$sources"

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

    # Two builds, one key. The keystore is kept outside the build directory for
    # exactly this: a keystore inside it is wiped by the next build, which then
    # generates a new key, which signs an APK that cannot be installed over the
    # one on the device. That is INSTALL_FAILED_UPDATE_INCOMPATIBLE, an uninstall,
    # and a root grant asked for again — found by rebuilding to verify a fix on a
    # phone, where it is the only place the cost shows up.
    sh "$BUILD" --out "$TMP/out/sign-a.apk" --no-payload >/dev/null 2>&1
    sh "$BUILD" --out "$TMP/out/sign-b.apk" --no-payload >/dev/null 2>&1
    # Only the digest is read, never the label in front of it: that label is
    # build-tools' business and it differs by platform and by which signing
    # schemes the APK carries — the macOS build-tools here print
    # "Signer #1 certificate SHA-256 digest:" and the Linux runner's print
    # "V3.0 Signer: certificate SHA-256 digest:" for the same APK. Anchored to
    # "^Signer #1", this check found nothing on the runner, and "both builds
    # agree" passed on two empty strings while the next line said the certificate
    # was 0 bytes long: the CI job for a release was red for exactly this, and no
    # local run could see it.
    cert_a=$("$BT/apksigner" verify --print-certs "$TMP/out/sign-a.apk" 2>/dev/null |
      sed -n 's/.*certificate SHA-256 digest: *//p' | head -n 1)
    cert_b=$("$BT/apksigner" verify --print-certs "$TMP/out/sign-b.apk" 2>/dev/null |
      sed -n 's/.*certificate SHA-256 digest: *//p' | head -n 1)
    check "a second build is signed with the same key as the first" "$cert_a" "$cert_b"
    check "and the key is a real certificate" "yes" \
      "$(printf '%s' "$cert_a" | grep -Eq '^[0-9a-fA-F]{64}$' && echo yes || echo no)"
    # The two spellings, as literal text, so the next person to touch the parse
    # has the evidence rather than the story.
    for label in "Signer #1 certificate SHA-256 digest: " "V3.0 Signer: certificate SHA-256 digest: "; do
      check "the digest is read from '$label'" "abc123" \
        "$(printf '%s\n' "${label}abc123" | sed -n 's/.*certificate SHA-256 digest: *//p' | head -n 1)"
    done

    badging=$("$BT/aapt2" dump badging "$APK" 2>/dev/null)
    contains "the package name is the one the manifest claims" "package: name='dev.dshd.app'" "$badging"
    contains "minSdk is 24" "minSdkVersion:'24'" "$badging"
    contains "and it targets 34" "targetSdkVersion:'34'" "$badging"
    contains "the launcher activity is declared" "launchable-activity: name='dev.dshd.app.MainActivity'" "$badging"
    contains "INTERNET is requested" "android.permission.INTERNET" "$badging"
    contains "the foreground service type is declared" "android.permission.FOREGROUND_SERVICE_DATA_SYNC" "$badging"
    lacks "nothing asks for storage access" "WRITE_EXTERNAL_STORAGE" "$badging"
    # The file picker is the system's, and it grants this app a read on the one
    # file the user chose. A storage or media permission here would mean the app
    # had gone back to reading the filesystem itself.
    lacks "the file picker needs no storage permission" "READ_EXTERNAL_STORAGE" "$badging"
    lacks "nor a media permission" "READ_MEDIA_IMAGES" "$badging"
    lacks "and the page cannot ask for a camera" "android.permission.CAMERA" "$badging"
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
    # And hands that tar's output to the bootstrap, rather than leaving it to read
    # a stdin the tar has already drained: without this flag the setup stops at
    # exit 6 on a device with "the payload did not extract", which is what one did.
    check "and hands the stage it extracted to the bootstrap" "1" \
      "$(grep -ac -- '--from "$S" ' "$TMP/classes.dex")"
    # The built artifact, not the source of it: a WebChromeClient that never made
    # it into the dex is the difference between an app that attaches files and one
    # that silently answers the page's file input with null.
    check "the shipped dex answers the page's file input" "1" \
      "$(grep -ac -- 'onShowFileChooser' "$TMP/classes.dex")"
    # And the other half of the same contract: a DownloadListener that never made
    # it into the dex is a download button that silently writes nothing.
    check "the shipped dex answers the page's downloads" "1" \
      "$(grep -ac -- 'onDownloadStart' "$TMP/classes.dex")"
    check "and carries the collection the file is saved in" "1" \
      "$(grep -ac -- 'Landroid/provider/MediaStore$Downloads;' "$TMP/classes.dex")"
    check "and the cookie header the fetch needs to be authenticated" "yes" \
      "$(grep -aq -- 'Cookie' "$TMP/classes.dex" && echo yes || echo no)"
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
