# Signing keys

Nothing in this directory is committed except this file. `*.keystore` is ignored,
and it has to stay that way: the key that signs a release is the only thing
proving an APK update came from the same place as the last one. Anyone holding it
can sign an APK that Android will install over yours.

## For a local build

Do nothing. `sh android/build.sh` generates a debug keystore in
`android/.build/debug.keystore` on first use and reuses it afterwards, and it
prints `signing: DEBUG key` so you are never in doubt about what you installed.
Debug-signed APKs are fine for your own device and are not for distribution.

## For releases built by CI

The release workflow uses a keystore from four repository secrets. Add them under
**Settings → Secrets and variables → Actions**:

| Secret | What it is |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore file, base64-encoded (see below) |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | the key's alias, if it is not `dshd` |
| `ANDROID_KEY_PASSWORD` | the key's password, if it differs from the store's |

Without them the workflow still builds and publishes, with a debug-signed APK and
a line in the release notes saying so — a release that cannot be produced is
worse than one that says which key it used.

## Making the key

```sh
keytool -genkeypair -v \
  -keystore dshd-release.keystore \
  -alias dshd \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=dshd release, O=your name"
```

Keep the file and both passwords somewhere you will still have them in five
years. Losing them means you cannot update the app on a device that already has
it installed: Android refuses an update signed by a different key, and the only
way forward is uninstall-and-reinstall, which loses the app's data.

Base64-encode it for the secret:

```sh
base64 -i dshd-release.keystore | pbcopy     # macOS
base64 -w0 dshd-release.keystore            # Linux
```

## Checking a signed APK

```sh
"$ANDROID_HOME"/build-tools/*/apksigner verify --print-certs dshd-0.1.0.apk
```

Compare the SHA-256 digest with the one from the previous release. If it changed
and you did not change it, do not install the update.
