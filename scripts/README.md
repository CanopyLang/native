# Scripts — local dev + remote device testing

## Test on a box you give by IP (the "provide an SSH IP" flow)

The model: **build the JS bundle locally, ship it + the host source to a remote box, the box
builds the native app and runs it.** The remote box only needs the *host* toolchain (Android SDK,
or Xcode) — `provision` installs all of it. No Canopy/Haskell toolchain on the box.

```sh
# 0. (once) build the bundle for the app you want to test, locally:
canopy-native build examples/counter        # -> examples/counter/build/canopy.bundle.js

# 1. point the harness at your box (user@IP). One file per platform:
cp host/android/.remote-build.env.example host/android/.remote-build.env
$EDITOR host/android/.remote-build.env       # set LINUX_SSH="ubuntu@<IP>" and REMOTE_DIR
#   (iOS: cp host/ios/.remote-build.env.example host/ios/.remote-build.env ; set MAC_SSH="user@<IP>")

# 2. install EVERYTHING on the box (idempotent):
./scripts/remote.sh android provision        # JDK 17 + Android SDK/NDK/CMake + emulator + AVD
./scripts/remote.sh android doctor           # verify

# 3. build + install + launch + screenshot, in one shot:
CANOPY_BUNDLE=examples/counter/build/canopy.bundle.js ./scripts/remote.sh android all
#   -> pulls host/android/remote-artifacts/{build.log, screen.png, logcat.txt} back here
```

`ios` is identical: `./scripts/remote.sh ios provision|doctor|all` (drives a Mac over SSH:
Homebrew + xcodegen + cocoapods + node, then xcodegen → pod install → xcodebuild → run on a
simulator, pulling `screen.png` + `canopy.log`). See `host/ios/remote-build.sh`.

Subcommands (both platforms): `provision · doctor · bundle · sync · build · run · test · logs · shell · clean · all`.
The `.remote-build.env` file holds the IP and is git-ignored — never committed.

## Local dev box

```sh
./scripts/setup-local.sh        # export JAVA_HOME / ANDROID_HOME / PATH (toolchain is under ~/android-tools)
canopy-native doctor            # confirm the toolchain is visible
./scripts/dev.sh <app-dir> --watch   # hot-reload loop: rebuild bundle + adb-push on every src change
./scripts/ci-test.sh            # device-free regression gate (canopy test + harness/run*.js)
```
