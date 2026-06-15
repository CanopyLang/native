#!/usr/bin/env bash
# remote-build.sh — build + validate the Canopy Android host on a remote Linux box over SSH.
#
# Sibling of host/ios/remote-build.sh, same shape. You give it the IP of a Linux box you can ssh
# into; it installs the whole Android toolchain there (JDK 17 + the version-matched SDK/NDK/CMake +
# emulator), mirrors host/{android,shared} up, builds the APK with the committed gradle wrapper,
# boots an emulator (or uses a connected device), installs + launches the app, and pulls a
# screenshot + logcat back to here. The JS bundle is built LOCALLY (canopy-native build) and shipped
# in, so the remote box never needs the Canopy/Haskell toolchain — only the Android host toolchain.
#
#   1. cp .remote-build.env.example .remote-build.env   &&  edit it (LINUX_SSH, REMOTE_DIR)
#   2. ./remote-build.sh provision       # one-time: install JDK + Android SDK/NDK/CMake + emulator on the box
#   3. ./remote-build.sh doctor          # verify the box toolchain
#   4. CANOPY_BUNDLE=/path/to/build/canopy.bundle.js ./remote-build.sh all   # ship → build → run
# or step-by-step:
#   ./remote-build.sh provision          # install everything on the remote Linux box
#   ./remote-build.sh bundle             # stage a locally-built canopy.bundle.js into the app assets
#   ./remote-build.sh sync               # rsync host/{android,shared} to the box
#   ./remote-build.sh build              # ./gradlew :app:assembleDebug — pulls build.log back
#   ./remote-build.sh run                # boot emulator/device, install, launch — pulls screenshot + logcat
#   ./remote-build.sh test               # smoke: launch + assert the process is alive + screenshot
#   ./remote-build.sh logs               # re-pull the last build.log
#   ./remote-build.sh shell              # interactive ssh into REMOTE_DIR/android
#   ./remote-build.sh clean              # remove build/ .cxx/ .gradle/ on the box
#
# Everything after the subcommand is passed through (e.g. `build -- --info`).

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # .../native/host/android
HOST_DIR="$(cd "$HERE/.." && pwd)"                            # .../native/host  (parent of android/ and shared/)
ENV_FILE="$HERE/.remote-build.env"
ARTIFACTS="$HERE/remote-artifacts"

# Usage/help needs no config — print and exit before the required-var checks.
case "${1:-help}" in ""|-h|--help|help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

: "${LINUX_SSH:?Set LINUX_SSH in $ENV_FILE (copy .remote-build.env.example). e.g. ubuntu@192.168.1.50}"
: "${LINUX_SSH_PORT:=22}"
: "${LINUX_SSH_KEY:=}"
: "${REMOTE_DIR:?Set REMOTE_DIR in $ENV_FILE (an absolute path on the box, e.g. /home/ubuntu/canopy-android-build)}"
: "${REMOTE_SDK:=}"                 # default computed on the box as $HOME/android-sdk
: "${APP_PKG:=org.canopy.echo}"     # applicationId (host/android/app/build.gradle)
: "${APP_ACT:=com.canopyhost.MainActivity}"
: "${CONFIG:=Debug}"                # Debug | Release
: "${API_LEVEL:=34}"
: "${NDK_VER:=26.3.11579264}"       # must match app/build.gradle ndkVersion
: "${CMAKE_VER:=3.22.1}"            # must match app/build.gradle externalNativeBuild cmake version
: "${BUILD_TOOLS:=34.0.0}"
: "${SYSIMG:=system-images;android-${API_LEVEL};google_apis;x86_64}"
: "${AVD_NAME:=canopy_test}"
: "${CANOPY_BUNDLE:=}"              # absolute path to a built canopy.bundle.js (from canopy-native build <app>)

REMOTE_ANDROID="$REMOTE_DIR/android"
APK_REL="app/build/outputs/apk/${CONFIG,,}/app-${CONFIG,,}.apk"

# ------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------
c_blue=$'\033[34m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s ! %s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

ssh_opts=(-p "$LINUX_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
[ -n "$LINUX_SSH_KEY" ] && ssh_opts+=(-i "$LINUX_SSH_KEY")

# Run a command on the box in a login shell (so ~/.profile exports ANDROID_HOME/PATH).
lin()      { ssh "${ssh_opts[@]}" "$LINUX_SSH" "bash -lc $(printf '%q' "$*")"; }
lin_andr() { lin "cd $(printf '%q' "$REMOTE_ANDROID") && $*"; }
lin_tty()  { ssh -t "${ssh_opts[@]}" "$LINUX_SSH" "$@"; }
# Stream a heredoc script to the box's bash, with env vars set on the command line.
lin_script() { ssh "${ssh_opts[@]}" "$LINUX_SSH" "$1 bash -s"; }

rsync_opts=(-az --delete -e "ssh ${ssh_opts[*]}")
pull() {  # pull REMOTE:$1 -> LOCAL:$2
  mkdir -p "$(dirname "$2")"
  rsync -az -e "ssh ${ssh_opts[*]}" "$LINUX_SSH:$1" "$2" 2>/dev/null \
    || scp "${ssh_opts[@]/-p/-P}" "$LINUX_SSH:$1" "$2" 2>/dev/null \
    || warn "could not pull $1"
}

# ------------------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------------------
cmd_provision() {
  say "Provisioning the Android toolchain on $LINUX_SSH (idempotent — safe to re-run)…"
  lin "echo connected as \$(whoami)@\$(hostname) — \$(. /etc/os-release 2>/dev/null; echo \$PRETTY_NAME)" \
    || die "cannot ssh to $LINUX_SSH — check LINUX_SSH / key / that the box allows SSH"

  # The big install runs as a remote bash script; versions come in as env on the command line.
  lin_script "ANDROID_API='$API_LEVEL' NDK_VER='$NDK_VER' CMAKE_VER='$CMAKE_VER' BUILD_TOOLS='$BUILD_TOOLS' SYSIMG='$SYSIMG' AVD_NAME='$AVD_NAME' REMOTE_SDK='${REMOTE_SDK}'" <<'REMOTE'
set -euo pipefail
SUDO=""; command -v sudo >/dev/null && [ "$(id -u)" -ne 0 ] && SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive
ANDROID_HOME="${REMOTE_SDK:-$HOME/android-sdk}"
CMDTOOLS_ZIP="commandlinetools-linux-11076708_latest.zip"   # Android cmdline-tools 12.0

echo "==> apt: JDK 17 + build deps…"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq openjdk-17-jdk-headless unzip wget curl ninja-build file >/dev/null

echo "==> Android cmdline-tools → $ANDROID_HOME"
mkdir -p "$ANDROID_HOME/cmdline-tools"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  cd /tmp && wget -q "https://dl.google.com/android/repository/$CMDTOOLS_ZIP" -O cmdtools.zip
  rm -rf /tmp/cmdline-tools && unzip -q cmdtools.zip -d /tmp
  rm -rf "$ANDROID_HOME/cmdline-tools/latest" && mv /tmp/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

echo "==> sdkmanager: platform-tools, platform-$ANDROID_API, build-tools $BUILD_TOOLS, ndk $NDK_VER, cmake $CMAKE_VER, emulator, system image"
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
sdkmanager --sdk_root="$ANDROID_HOME" \
  "platform-tools" "platforms;android-$ANDROID_API" "build-tools;$BUILD_TOOLS" \
  "ndk;$NDK_VER" "cmake;$CMAKE_VER" "emulator" "$SYSIMG" >/dev/null

echo "==> persist ANDROID_HOME in ~/.profile"
PROF="$HOME/.profile"
grep -q 'ANDROID_HOME=' "$PROF" 2>/dev/null || cat >> "$PROF" <<EOF

# canopy/native android toolchain (added by remote-build.sh provision)
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH"
EOF

echo "==> create AVD '$AVD_NAME' (if missing)"
if ! avdmanager list avd 2>/dev/null | grep -q "Name: $AVD_NAME"; then
  echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$SYSIMG" --device "pixel_6" --force >/dev/null
fi

echo "==> KVM acceleration check"
if [ -e /dev/kvm ]; then
  $SUDO chmod 666 /dev/kvm 2>/dev/null || true
  echo "   /dev/kvm present — hardware acceleration available"
else
  echo "   ! /dev/kvm ABSENT — the x86_64 emulator will be slow (software). Prefer a connected device,"
  echo "     a KVM-enabled host (nested virtualization), or set SYSIMG to an arm image on an arm box."
fi
echo "PROVISION-OK ($(java -version 2>&1 | head -1))"
REMOTE
  ok "provision complete — now run: ./remote-build.sh doctor"
}

cmd_doctor() {
  say "Checking local prerequisites…"
  command -v rsync >/dev/null || die "rsync not found locally"; command -v ssh >/dev/null || die "ssh not found locally"
  ok "local: rsync + ssh present"
  say "Connecting to $LINUX_SSH (port $LINUX_SSH_PORT)…"
  lin "true" || die "cannot ssh to $LINUX_SSH"
  ok "ssh reachable"
  say "Checking the box toolchain…"
  lin '
    fail=0
    A="${ANDROID_HOME:-$HOME/android-sdk}"
    chk(){ if command -v "$1" >/dev/null; then printf "  ✓ %-12s %s\n" "$1" "$($2 2>&1|head -1)"; else printf "  ✗ %-12s MISSING — %s\n" "$1" "$3"; fail=1; fi; }
    chk java "java -version" "run: remote-build.sh provision"
    chk adb  "adb version"   "run: remote-build.sh provision"
    [ -d "$A/ndk" ]      && echo "  ✓ ndk          $(ls "$A/ndk" | tr "\n" " ")"        || { echo "  ✗ ndk MISSING"; fail=1; }
    [ -d "$A/cmake" ]    && echo "  ✓ cmake        $(ls "$A/cmake" | tr "\n" " ")"      || { echo "  ✗ cmake MISSING"; fail=1; }
    [ -d "$A/platforms" ]&& echo "  ✓ platforms    $(ls "$A/platforms" | tr "\n" " ")"  || { echo "  ✗ platforms MISSING"; fail=1; }
    echo "  -- devices --"; adb devices 2>/dev/null | sed "1d;/^$/d" || true
    [ -e /dev/kvm ] && echo "  ✓ /dev/kvm (accel)" || echo "  ! /dev/kvm absent (slow emulator)"
    exit $fail
  ' && ok "box toolchain OK" || die "box toolchain incomplete — run: ./remote-build.sh provision"
}

cmd_bundle() {
  [ -z "$CANOPY_BUNDLE" ] && { warn "CANOPY_BUNDLE not set — sync will ship whatever bundle is already in app/src/main/assets/"; return; }
  [ -f "$CANOPY_BUNDLE" ] || die "CANOPY_BUNDLE=$CANOPY_BUNDLE does not exist (run: canopy-native build <appdir>)"
  local dst="$HOST_DIR/android/app/src/main/assets"
  say "Staging $(basename "$CANOPY_BUNDLE") → app/src/main/assets/ ($(wc -c < "$CANOPY_BUNDLE") bytes)"
  mkdir -p "$dst"; cp -f "$CANOPY_BUNDLE" "$dst/canopy.bundle.js"
  [ -f "$CANOPY_BUNDLE.map" ] && cp -f "$CANOPY_BUNDLE.map" "$dst/canopy.bundle.js.map" || true
  local man; man="$(dirname "$CANOPY_BUNDLE")/canopy.manifest.json"
  [ -f "$man" ] && cp -f "$man" "$dst/canopy.manifest.json" || true
  ok "bundle staged — ships on the next sync"
}

cmd_sync() {
  say "Mirroring host/{android,shared} → $LINUX_SSH:$REMOTE_DIR"
  lin "mkdir -p $(printf '%q' "$REMOTE_DIR")"
  [ -n "$CANOPY_BUNDLE" ] && cmd_bundle
  rsync "${rsync_opts[@]}" \
    --exclude '.git/' --exclude 'remote-artifacts/' --exclude '.remote-build.env' \
    --exclude 'build/' --exclude '.cxx/' --exclude '.gradle/' --exclude 'local.properties' --exclude 'node_modules/' \
    "$HOST_DIR/android/" "$LINUX_SSH:$REMOTE_ANDROID/"
  rsync "${rsync_opts[@]}" --exclude '.git/' --exclude 'build-android/' --exclude 'build-host/' \
    "$HOST_DIR/shared/" "$LINUX_SSH:$REMOTE_DIR/shared/"
  ok "source synced"
}

cmd_build() {
  local task="assemble${CONFIG}" log="$REMOTE_ANDROID/remote-artifacts/build.log"
  say "Writing local.properties + ./gradlew :app:$task on the box…"
  lin_andr "mkdir -p remote-artifacts && printf 'sdk.dir=%s\n' \"\${ANDROID_HOME:-\$HOME/android-sdk}\" > local.properties && \
      chmod +x gradlew && set -o pipefail && ./gradlew :app:$task --console=plain $* 2>&1 | tee remote-artifacts/build.log" \
    && { pull "$log" "$ARTIFACTS/build.log"; ok "BUILD SUCCEEDED — apk: $REMOTE_ANDROID/$APK_REL  (log: $ARTIFACTS/build.log)"; } \
    || { pull "$log" "$ARTIFACTS/build.log"; warn "BUILD FAILED — errors below + full log at $ARTIFACTS/build.log"; \
         grep -nE 'error:|FAILURE:|What went wrong|> Task .* FAILED' "$ARTIFACTS/build.log" | head -40 || true; die "build failed"; }
}

# Ensure a booted device; boot the AVD headless if none is connected.
_ensure_device() {
  lin '
    set -e
    A="${ANDROID_HOME:-$HOME/android-sdk}"
    if adb devices | sed "1d" | grep -qw device; then echo "using connected device: $(adb devices|sed "1d"|grep -w device|head -1)"; exit 0; fi
    echo "no device — booting AVD '"$AVD_NAME"' headless…"
    nohup "$A/emulator/emulator" -avd '"$AVD_NAME"' -no-window -no-snapshot -no-audio -gpu swiftshader_indirect >/tmp/emu.log 2>&1 &
    adb wait-for-device
    until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = "1" ]; do sleep 2; done
    adb shell input keyevent 82 >/dev/null 2>&1 || true
    echo "emulator booted."
  '
}

cmd_run() {
  say "Ensuring a device, installing + launching $APP_PKG…"
  _ensure_device || die "could not get a device (connect one, or provision KVM for the emulator)"
  lin_andr "
    set -e
    APK=$APK_REL
    [ -f \"\$APK\" ] || { echo 'no APK — run build first'; exit 1; }
    adb install -r -g \"\$APK\"
    adb shell am force-stop $APP_PKG || true
    adb shell am start -n $APP_PKG/$APP_ACT
    sleep 5
    mkdir -p remote-artifacts
    adb exec-out screencap -p > remote-artifacts/screen.png || true
    adb logcat -d -t 800 -v time > remote-artifacts/logcat.txt 2>/dev/null || true
    if adb shell pidof $APP_PKG >/dev/null 2>&1; then echo 'RUN-OK app alive'; else echo 'RUN-WARN app not running (check logcat)'; fi
  " || warn "run reported a problem (see logcat)"
  pull "$REMOTE_ANDROID/remote-artifacts/screen.png" "$ARTIFACTS/screen.png"
  pull "$REMOTE_ANDROID/remote-artifacts/logcat.txt" "$ARTIFACTS/logcat.txt"
  ok "screenshot: $ARTIFACTS/screen.png   logcat: $ARTIFACTS/logcat.txt"
  [ -s "$ARTIFACTS/logcat.txt" ] && { say "last Canopy log lines:"; grep -iE 'canopy|AndroidRuntime|FATAL' "$ARTIFACTS/logcat.txt" | tail -20 || tail -20 "$ARTIFACTS/logcat.txt"; } || true
}

cmd_test() {
  cmd_run
  say "smoke assertion: app process must be alive"
  lin "adb shell pidof $APP_PKG >/dev/null && echo OK" | grep -q OK \
    && ok "SMOKE PASSED — $APP_PKG is running" || die "SMOKE FAILED — $APP_PKG not running (see $ARTIFACTS/logcat.txt)"
}

cmd_logs()  { pull "$REMOTE_ANDROID/remote-artifacts/build.log" "$ARTIFACTS/build.log"; ok "$ARTIFACTS/build.log"; }
cmd_shell() { lin_tty "cd $(printf '%q' "$REMOTE_ANDROID"); exec bash -l"; }
cmd_clean() {
  say "Removing build/ .cxx/ .gradle/ on the box (keeps source)…"
  lin_andr "rm -rf app/build app/.cxx .gradle && rm -rf ../shared/build-android" && ok "cleaned"
}

cmd_all() { cmd_sync; cmd_build; cmd_run; ok "Full pipeline complete. Review $ARTIFACTS/{build.log,screen.png,logcat.txt}"; }

# ------------------------------------------------------------------------------------------
usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local sub="${1:-}"; shift || true
  [ "${1:-}" = "--" ] && shift || true
  case "$sub" in
    provision) cmd_provision "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    bundle)    cmd_bundle "$@" ;;
    sync)      cmd_sync "$@" ;;
    build)     cmd_build "$@" ;;
    run)       cmd_run "$@" ;;
    test)      cmd_test "$@" ;;
    logs)      cmd_logs "$@" ;;
    shell)     cmd_shell "$@" ;;
    clean)     cmd_clean "$@" ;;
    all)       cmd_all "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown subcommand '$sub' — run: ./remote-build.sh help" ;;
  esac
}
main "$@"
