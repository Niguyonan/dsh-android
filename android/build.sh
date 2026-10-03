#!/bin/sh
# build.sh — assemble the APK with the Android SDK's own tools.
#
# No Gradle, no AndroidX, no network: the app is a few Java files against the
# framework API, so aapt2 + javac + d8 + zipalign + apksigner is the whole build.
# That matters beyond taste — the artifact this script produces is the artifact
# this repository can *verify*, and a build that needs a dependency-resolution
# step is a build whose inputs change without the commit changing.
#
# What it does, in order:
#
#   1. tools/mkpayload.sh   build android/assets/payload.tar + payload.id from
#                           the working tree. The APK ships that tar, so the
#                           payload is versioned by the same commit as the app
#   2. aapt2 compile/link   resources + manifest -> base.apk, with assets/
#   3. javac                src/ + the generated R.java, against android.jar with
#                           -source/-target 8 and the android.jar bootclasspath,
#                           which is what makes "this API does not exist on
#                           Android" a compile error instead of a crash
#   4. d8                   dex, with --min-api from the manifest
#   5. zipalign then apksigner, then apksigner verify — a signed APK that does
#      not verify is not a build, and this script fails on it
#
# usage: build.sh [--sdk DIR] [--out FILE] [--ks FILE] [--ks-pass PASS]
#                 [--alias NAME] [--version-name V] [--version-code N]
#                 [--no-payload]
#
# env: ANDROID_HOME or ANDROID_SDK_ROOT, unless --sdk is given.
#      DSH_KS_FILE, DSH_KS_PASS, DSH_KS_ALIAS — the same three settings as the
#      flags, because a password on a command line is a password in `ps`. CI
#      passes them this way, from repository secrets.
#
# Signing: with no keystore given, one is generated in the build directory and
# the APK is debug-signed — installable, and not distributable. The last line of
# the output always says which of the two happened.
#
# exit: 0 ok · 1 usage or no SDK · 2 the payload could not be built · 3 a build
#       step failed · 4 the APK did not verify
#
# POSIX sh: this runs on the development host (macOS or Linux), never on the
# device.

set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
ROOT=$(cd "$HERE/.." && pwd) || exit 1
BUILD="$HERE/.build"
ASSETS="$HERE/assets"
SOURCE="$HERE/src"
RES="$HERE/res"
MANIFEST="$HERE/AndroidManifest.xml"

PKG=dev.dshd.app
VERSION_NAME=0.1.1
VERSION_CODE=2
OUT=""
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
KEYSTORE="${DSH_KS_FILE:-}"
KS_PASS="${DSH_KS_PASS:-android}"
KS_ALIAS="${DSH_KS_ALIAS:-dshd}"
DEBUG_SIGNED=0
WITH_PAYLOAD=1

die() {
  rc=$1
  shift
  printf 'build: %s\n' "$*" >&2
  exit "$rc"
}

say() { printf '%s\n' "$*"; }

usage() {
  sed -n '2,40p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)
      shift
      SDK=${1:-}
      ;;
    --out)
      shift
      OUT=${1:-}
      ;;
    --ks)
      shift
      KEYSTORE=${1:-}
      ;;
    --ks-pass)
      shift
      KS_PASS=${1:-}
      ;;
    --alias)
      shift
      KS_ALIAS=${1:-}
      ;;
    --version-name)
      shift
      VERSION_NAME=${1:-}
      ;;
    --version-code)
      shift
      VERSION_CODE=${1:-}
      ;;
    --no-payload) WITH_PAYLOAD=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die 1 "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

# --- find the SDK -----------------------------------------------------------

sdk_tools() {
  # The newest build-tools and platform present, not a pinned version: a pinned
  # one turns "your SDK is newer" into a build failure for no reason.
  [ -n "$SDK" ] && [ -d "$SDK" ] || return 1
  BT=$(ls "$SDK/build-tools" 2>/dev/null | sort -n | tail -n 1)
  [ -n "$BT" ] || return 1
  PLATFORM=$(ls "$SDK/platforms" 2>/dev/null | sort | tail -n 1)
  [ -n "$PLATFORM" ] || return 1
  BT="$SDK/build-tools/$BT"
  ANDROID_JAR="$SDK/platforms/$PLATFORM/android.jar"
  [ -f "$ANDROID_JAR" ] || return 1
  for tool in aapt2 d8 zipalign apksigner; do
    [ -x "$BT/$tool" ] || return 1
  done
  return 0
}

sdk_tools || die 1 "no usable Android SDK. Set ANDROID_HOME (or ANDROID_SDK_ROOT, or pass --sdk DIR) to an SDK with build-tools, a platform, and android.jar."
[ -n "$OUT" ] || OUT="$BUILD/dshd-$VERSION_NAME.apk"
# Absolute before anything else: the packaging below happens after a `cd` into
# the build directory, and a relative --out would be resolved against that
# instead of against where the caller was standing. Every local run passed an
# absolute path and never noticed; the release workflow passed `dist/...` and
# published nothing.
case "$OUT" in
  /*) ;;
  *) OUT="$(pwd)/$OUT" ;;
esac

for tool in javac keytool; do
  command -v "$tool" >/dev/null 2>&1 || die 1 "$tool is not on PATH (a JDK is required)"
done

say "sdk:      $SDK"
say "tools:    $BT"
say "platform: $ANDROID_JAR"

# --- payload ----------------------------------------------------------------

if [ "$WITH_PAYLOAD" = 1 ]; then
  sh "$ROOT/tools/mkpayload.sh" --out "$ASSETS" --quiet || die 2 "tools/mkpayload.sh failed"
  say "payload:  $(cat "$ASSETS/payload.id") ($(wc -c <"$ASSETS/payload.tar" | tr -d ' ') bytes)"
else
  [ -f "$ASSETS/payload.tar" ] || die 2 "--no-payload was given and $ASSETS/payload.tar does not exist"
  say "payload:  unchanged ($(cat "$ASSETS/payload.id" 2>/dev/null || echo unknown))"
fi

# --- resources and manifest -------------------------------------------------

rm -rf "$BUILD"
mkdir -p "$BUILD/compiled" "$BUILD/classes" "$BUILD/dex" "$BUILD/gen" || die 3 "cannot create $BUILD"

"$BT/aapt2" compile --dir "$RES" -o "$BUILD/compiled/res.zip" || die 3 "aapt2 compile failed"

"$BT/aapt2" link \
  -o "$BUILD/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$MANIFEST" \
  -A "$ASSETS" \
  --java "$BUILD/gen" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --version-code "$VERSION_CODE" \
  --version-name "$VERSION_NAME" \
  "$BUILD/compiled/res.zip" || die 3 "aapt2 link failed"

# --- java -------------------------------------------------------------------

# shellcheck disable=SC2046  # the file list is the point
javac -source 8 -target 8 -bootclasspath "$ANDROID_JAR" -Xlint:-options \
  -d "$BUILD/classes" \
  $(find "$SOURCE" "$BUILD/gen" -name '*.java') || die 3 "javac failed"

# shellcheck disable=SC2046
"$BT/d8" --min-api 24 --lib "$ANDROID_JAR" --output "$BUILD/dex" \
  $(find "$BUILD/classes" -name '*.class') || die 3 "d8 failed"

# --- package, align, sign ---------------------------------------------------

cd "$BUILD" || die 3 "cannot enter $BUILD"
cp base.apk unsigned.apk || die 3 "cannot copy base.apk"
# The dex goes in beside the resources aapt2 linked, then the whole thing is
# aligned: zipalign refuses to touch a signed archive, so the order is fixed.
zip -q -j unsigned.apk dex/classes.dex || die 3 "cannot add classes.dex"
"$BT/zipalign" -f 4 unsigned.apk aligned.apk || die 3 "zipalign failed"

if [ -z "$KEYSTORE" ]; then
  DEBUG_SIGNED=1
  KEYSTORE="$BUILD/debug.keystore"
  if [ ! -f "$KEYSTORE" ]; then
    say "signing:  generating a debug keystore at $KEYSTORE"
    keytool -genkeypair -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" \
      -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=dshd debug, O=dsh-android" >/dev/null 2>&1 ||
      die 3 "keytool could not create a debug keystore"
  fi
fi
[ -f "$KEYSTORE" ] || die 1 "--ks $KEYSTORE does not exist"

mkdir -p "$(dirname "$OUT")" || die 3 "cannot create $(dirname "$OUT")"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --ks-key-alias "$KS_ALIAS" --min-sdk-version 24 --out "$OUT" aligned.apk ||
  die 3 "apksigner failed"

"$BT/apksigner" verify --min-sdk-version 24 "$OUT" >/dev/null 2>&1 ||
  die 4 "the APK does not verify — refusing to report a build"

# --- report -----------------------------------------------------------------

if [ "$DEBUG_SIGNED" = 1 ]; then
  say "signing:  DEBUG key (generated) — installable, and not for distribution."
  say "          For a release, set DSH_KS_FILE/DSH_KS_PASS/DSH_KS_ALIAS (or --ks)."
else
  say "signing:  $KEYSTORE (alias $KS_ALIAS)"
fi
say "apk:      $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
say "package:  $PKG $VERSION_NAME ($VERSION_CODE)"
say "sha256:   $(shasum -a 256 "$OUT" 2>/dev/null | cut -d' ' -f1 || sha256sum "$OUT" | cut -d' ' -f1)"
"$BT/aapt2" dump badging "$OUT" 2>/dev/null |
  grep -E "^(package|launchable-activity|uses-permission|sdkVersion|targetSdkVersion)" |
  sed 's/^/          /'
