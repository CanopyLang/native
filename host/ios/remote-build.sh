#!/usr/bin/env bash
# remote-build.sh — build + validate the Canopy iOS host on a remote Mac over SSH.
#
# No Mac is available on the dev box (Linux), and the iOS host is Objective-C++/UIKit/Swift that
# only Xcode can compile. This harness drives a Mac build host over SSH: it mirrors the source up,
# bootstraps the toolchain (XcodeGen + CocoaPods + the matched Hermes/Yoga pods via a pinned RN),
# builds for the simulator, installs + launches the app, and pulls the build log + a screenshot +
# the os_log back to Linux so the whole loop is driveable from here.
#
# It is intentionally idempotent and resumable: each phase is a subcommand, and `all` runs them in
# order. Build output is teed to a remote log and pulled into ./remote-artifacts/ every time, so a
# failed compile surfaces its errors locally for the next fix iteration.
#
#   1. cp .remote-build.env.example .remote-build.env   &&  edit it (MAC_SSH, REMOTE_DIR)
#   2. ./remote-build.sh provision       # install the Mac toolchain (Homebrew + xcodegen + cocoapods + node)
#   3. ./remote-build.sh doctor          # verify the Mac toolchain (Xcode, xcodegen, pod, ruby)
#   4. ./remote-build.sh all             # sync → bootstrap → gen → build → run (full pipeline)
# or step-by-step:
#   ./remote-build.sh provision          # one-time: install Homebrew + xcodegen + cocoapods + node on the Mac
#   ./remote-build.sh sync               # rsync host/{ios,shared} to the Mac
#   ./remote-build.sh bootstrap          # npm i react-native@pin (vends Hermes/Yoga podspecs)
#   ./remote-build.sh gen                # xcodegen generate + pod install
#   ./remote-build.sh build              # xcodebuild (simulator) — pulls build.log back
#   ./remote-build.sh run                # boot sim, install, launch — pulls screenshot + log
#   ./remote-build.sh test               # xcodebuild test (unit + UI bundles)
#   ./remote-build.sh logs               # re-pull the last build.log
#   ./remote-build.sh shell              # interactive ssh into REMOTE_DIR
#   ./remote-build.sh clean              # remove generated project/pods/build on the Mac
#
# Everything after the subcommand is passed through (e.g. `build -- -quiet`).

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(cd "$HERE/.." && pwd)"          # .../native/host  (parent of ios/ and shared/)
ENV_FILE="$HERE/.remote-build.env"
ARTIFACTS="$HERE/remote-artifacts"

# Usage/help needs no config — print and exit before the required-var checks.
case "${1:-help}" in ""|-h|--help|help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

: "${MAC_SSH:?Set MAC_SSH in $ENV_FILE (copy .remote-build.env.example). e.g. ci@mac.local}"
: "${MAC_SSH_PORT:=22}"
: "${MAC_SSH_KEY:=}"
: "${REMOTE_DIR:?Set REMOTE_DIR in $ENV_FILE (an absolute path on the Mac)}"
: "${SIM_DEVICE:=iPhone 15}"
: "${CONFIG:=Debug}"
: "${WORKSPACE:=}"
: "${SCHEME:=}"
: "${APP_BUNDLE_ID:=com.canopyhost.app}"
: "${CANOPY_BUNDLE:=}"
: "${RN_VERSION:=0.76.9}"   # must match the Podfile $RN_VERSION pin
# Path-B (offline / tarball-404 fallback): a path ON THE MAC to a vendored Hermes prebuilt
# tarball (hermes-ios-debug.tar.gz / .../universal/hermes.xcframework already extracted into a
# destroot tarball). When set, `gen` exports HERMES_ENGINE_TARBALL_PATH so the hermes-engine
# podspec uses the LOCAL_PREBUILT source type and never downloads from the network. Leave empty
# for the normal CocoaPods download path. See README "Path-B".
: "${HERMES_TARBALL:=}"

REMOTE_IOS="$REMOTE_DIR/ios"

# ------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------
c_blue=$'\033[34m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s ! %s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

ssh_opts=(-p "$MAC_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
[ -n "$MAC_SSH_KEY" ] && ssh_opts+=(-i "$MAC_SSH_KEY")

# Run a command on the Mac. Wrapped in a login shell so PATH picks up Homebrew (xcodegen, pod).
mac() {
  ssh "${ssh_opts[@]}" "$MAC_SSH" "bash -lc $(printf '%q' "$*")"
}
# Run a command on the Mac inside REMOTE_IOS.
mac_ios() {
  mac "cd $(printf '%q' "$REMOTE_IOS") && $*"
}
# Interactive ssh (TTY).
mac_tty() { ssh -t "${ssh_opts[@]}" "$MAC_SSH" "$@"; }

rsync_opts=(-az --delete -e "ssh ${ssh_opts[*]}")

pull() {  # pull REMOTE:$1 -> LOCAL:$2
  mkdir -p "$(dirname "$2")"
  rsync -az -e "ssh ${ssh_opts[*]}" "$MAC_SSH:$1" "$2" 2>/dev/null || \
    scp "${ssh_opts[@]/-p/-P}" "$MAC_SSH:$1" "$2" 2>/dev/null || \
    warn "could not pull $1"
}

# Resolve WORKSPACE/SCHEME from the generated project if not pinned in the env.
detect_workspace() {
  [ -n "$WORKSPACE" ] && { echo "$WORKSPACE"; return; }
  mac_ios "ls -d *.xcworkspace 2>/dev/null | head -1" || true
}
detect_scheme() {
  [ -n "$SCHEME" ] && { echo "$SCHEME"; return; }
  echo "CanopyHost"   # the ONE scheme declared under `schemes:` in project.yml
}

# ------------------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------------------
cmd_provision() {
  say "Provisioning the Mac toolchain on $MAC_SSH (idempotent — safe to re-run)…"
  mac "echo connected as \$(whoami) on \$(sw_vers -productName) \$(sw_vers -productVersion)" \
    || die "cannot ssh to $MAC_SSH — enable Remote Login (System Settings ▸ General ▸ Sharing) and check MAC_SSH/key"
  # Xcode itself cannot be installed non-interactively (App Store / xcodes); we install the rest
  # and surface a clear instruction if the full Xcode app is missing.
  mac '
    set -e
    # Command Line Tools (provides git, clang; required before brew).
    if ! xcode-select -p >/dev/null 2>&1; then
      echo "==> installing Command Line Tools (a GUI prompt may appear on the Mac)…"
      xcode-select --install || true
      echo "   …if a dialog appeared, finish it, then re-run provision."
    fi
    # Homebrew.
    if ! command -v brew >/dev/null 2>&1; then
      echo "==> installing Homebrew…"
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    # Put brew on PATH for this shell (Apple Silicon vs Intel).
    eval "$([ -x /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv || /usr/local/bin/brew shellenv)" 2>/dev/null || true
    echo "==> brew install xcodegen cocoapods node…"
    brew install xcodegen cocoapods node 2>&1 | tail -3 || true
    # Full Xcode (not just CLT) is required for xcodebuild + simulators.
    if ! xcodebuild -version >/dev/null 2>&1; then
      echo "  ✗ Xcode.app not found. Install it from the App Store (or: brew install --cask xcodes && open -a Xcodes),"
      echo "    then: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept"
    else
      echo "  ✓ $(xcodebuild -version | head -1)"
    fi
  ' && ok "provision step complete — now run: ./remote-build.sh doctor" \
    || die "provision hit an error (see output above)"
}

cmd_doctor() {
  say "Checking local prerequisites…"
  command -v rsync >/dev/null || die "rsync not found locally"
  command -v ssh   >/dev/null || die "ssh not found locally"
  ok "local: rsync + ssh present"

  say "Connecting to $MAC_SSH (port $MAC_SSH_PORT)…"
  mac "echo connected as \$(whoami) on \$(sw_vers -productName) \$(sw_vers -productVersion)" \
    || die "cannot ssh to $MAC_SSH — check MAC_SSH / key / that the Mac allows Remote Login"
  ok "ssh reachable"

  say "Checking the Mac toolchain…"
  mac '
    set -e
    fail=0
    check() { if command -v "$1" >/dev/null; then printf "  ✓ %-12s %s\n" "$1" "$($2 2>&1 | head -1)"; else printf "  ✗ %-12s MISSING — %s\n" "$1" "$3"; fail=1; fi; }
    check xcodebuild "xcodebuild -version" "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
    check xcrun      "xcrun --version"      "comes with Xcode"
    check xcodegen   "xcodegen --version"   "brew install xcodegen"
    check pod        "pod --version"        "brew install cocoapods   (or: sudo gem install cocoapods)"
    check node       "node --version"       "brew install node"
    check npm        "npm --version"        "comes with node"
    check git        "git --version"        "xcode-select --install"
    echo "  -- simulators --"; xcrun simctl list devices available | grep -iE "iphone" | head -5 || true
    exit $fail
  ' && ok "Mac toolchain OK" || die "Mac toolchain incomplete — install the MISSING tools above and re-run doctor"
}

cmd_sync() {
  say "Mirroring host/{ios,shared} → $MAC_SSH:$REMOTE_DIR"
  mac "mkdir -p $(printf '%q' "$REMOTE_DIR")"
  [ -n "$CANOPY_BUNDLE" ] && cmd_bundle
  # ios/: exclude generated + local-only artifacts so we never clobber the Mac's Pods/node_modules.
  rsync "${rsync_opts[@]}" \
    --exclude '.git/' --exclude 'remote-artifacts/' --exclude '.remote-build.env' \
    --exclude 'build/' --exclude 'DerivedData/' --exclude 'Pods/' --exclude 'node_modules/' \
    --exclude '*.xcodeproj/' --exclude '*.xcworkspace/' --exclude 'Podfile.lock' \
    "$HOST_DIR/ios/" "$MAC_SSH:$REMOTE_IOS/"
  # shared/: the C++ engine the iOS target compiles via ../shared/... paths.
  rsync "${rsync_opts[@]}" --exclude '.git/' \
    "$HOST_DIR/shared/" "$MAC_SSH:$REMOTE_DIR/shared/"
  ok "source synced"
}

cmd_bundle() {
  [ -z "$CANOPY_BUNDLE" ] && { warn "CANOPY_BUNDLE not set — skipping bundle stage (build uses placeholder)"; return; }
  [ -f "$CANOPY_BUNDLE" ] || die "CANOPY_BUNDLE=$CANOPY_BUNDLE does not exist (run: canopy-native build <appdir>)"
  say "Staging $CANOPY_BUNDLE → CanopyHostApp/Resources/canopy.bundle.js"
  mkdir -p "$HERE/CanopyHostApp/Resources"
  cp -f "$CANOPY_BUNDLE" "$HERE/CanopyHostApp/Resources/canopy.bundle.js"
  ok "bundle staged ($(wc -c < "$CANOPY_BUNDLE") bytes) — it ships on the next sync"
}

cmd_bootstrap() {
  say "Bootstrapping RN $RN_VERSION on the Mac (vends the matched Hermes + Yoga podspecs)…"
  mac_ios "
    set -e
    [ -f package.json ] || npm init -y >/dev/null
    if [ ! -d node_modules/react-native ]; then
      echo 'installing react-native@$RN_VERSION (first run only; this pulls the Hermes prebuilt)…'
      npm i --no-audit --no-fund react-native@$RN_VERSION
    else
      echo 'node_modules/react-native already present'
    fi
    test -f node_modules/react-native/scripts/react_native_pods.rb && echo 'react_native_pods.rb present'
    test -f node_modules/react-native/sdks/hermes-engine/hermes-engine.podspec && echo 'hermes-engine.podspec present'
    test -f node_modules/react-native/ReactCommon/yoga/Yoga.podspec && echo 'Yoga.podspec present'
  " && ok "RN deps in place" || die "bootstrap failed (see output above)"
}

cmd_gen() {
  say "xcodegen generate + pod install on the Mac…"
  # Path-B: when HERMES_TARBALL is set, point the hermes-engine podspec at a vendored prebuilt so
  # `pod install` skips the network download (the env var takes precedence over the release
  # tarball URL — see the podspec's hermes_source_type). Exported into the remote pod env only.
  local hermes_env=""
  if [ -n "$HERMES_TARBALL" ]; then
    say "Path-B: HERMES_ENGINE_TARBALL_PATH=$HERMES_TARBALL (vendored Hermes — no download)"
    hermes_env="export HERMES_ENGINE_TARBALL_PATH=$(printf '%q' "$HERMES_TARBALL"); "
  fi
  mac_ios "
    set -e
    ${hermes_env}xcodegen generate
    echo '--- pod install ---'
    pod install
  " && ok "project generated + pods installed" || {
    warn "gen failed. If the failure is a 404 / could-not-download on hermes-engine, this is the"
    warn "0.76.9 prebuilt tarball going missing — fall to Path-B: set HERMES_TARBALL in"
    warn ".remote-build.env to a vendored hermes prebuilt on the Mac (see host/ios/Frameworks/"
    warn "VENDOR-LAYOUT.md + README 'Path-B') and re-run: ./remote-build.sh gen"
    die "gen failed — fix project.yml/Podfile (or set HERMES_TARBALL) and re-run"
  }
  local ws; ws="$(detect_workspace | tr -d '[:space:]')"
  [ -n "$ws" ] && ok "workspace: $ws"
}

cmd_build() {
  local ws scheme dest log
  ws="$(detect_workspace | tr -d '[:space:]')"
  [ -n "$ws" ] || die "no .xcworkspace on the Mac — run: ./remote-build.sh gen"
  scheme="$(detect_scheme)"
  dest="platform=iOS Simulator,name=$SIM_DEVICE"
  log="$REMOTE_IOS/remote-artifacts/build.log"

  say "xcodebuild  workspace=$ws  scheme=$scheme  config=$CONFIG  dest=[$dest]"
  mac_ios "mkdir -p remote-artifacts && set -o pipefail && xcodebuild \
      -workspace $(printf '%q' "$ws") \
      -scheme $(printf '%q' "$scheme") \
      -configuration $(printf '%q' "$CONFIG") \
      -sdk iphonesimulator \
      -destination $(printf '%q' "$dest") \
      -derivedDataPath build \
      $* \
      build 2>&1 | tee remote-artifacts/build.log" \
    && { pull "$log" "$ARTIFACTS/build.log"; ok "BUILD SUCCEEDED — log: $ARTIFACTS/build.log"; } \
    || { pull "$log" "$ARTIFACTS/build.log"; warn "BUILD FAILED — errors below + full log at $ARTIFACTS/build.log"; \
         grep -nE 'error:|warning:|note:' "$ARTIFACTS/build.log" | grep 'error:' | head -40 || true; \
         die "build failed"; }
}

cmd_run() {
  local app
  say "Booting simulator '$SIM_DEVICE', installing + launching $APP_BUNDLE_ID…"
  mac_ios "
    set -e
    DEV='$SIM_DEVICE'
    xcrun simctl boot \"\$DEV\" 2>/dev/null || true
    xcrun simctl bootstatus \"\$DEV\" -b || true
    APP=\$(find build -type d -name '*.app' -path '*iphonesimulator*' | head -1)
    [ -n \"\$APP\" ] || { echo 'no .app found — run build first'; exit 1; }
    echo \"installing \$APP\"
    xcrun simctl install \"\$DEV\" \"\$APP\"
    xcrun simctl launch \"\$DEV\" $APP_BUNDLE_ID || true
    sleep 4
    mkdir -p remote-artifacts
    xcrun simctl io \"\$DEV\" screenshot remote-artifacts/screen.png || true
    # Pull our os_log (subsystem com.canopyhost.canopy covers Boot/JS/modules) for the last 2 min.
    xcrun simctl spawn \"\$DEV\" log show --last 2m --predicate 'subsystem == \"com.canopyhost.canopy\"' \
      > remote-artifacts/canopy.log 2>/dev/null || true
    echo 'launched.'
  " || warn "run reported a problem (see logs)"
  pull "$REMOTE_IOS/remote-artifacts/screen.png" "$ARTIFACTS/screen.png"
  pull "$REMOTE_IOS/remote-artifacts/canopy.log" "$ARTIFACTS/canopy.log"
  ok "screenshot: $ARTIFACTS/screen.png   log: $ARTIFACTS/canopy.log"
  [ -s "$ARTIFACTS/canopy.log" ] && { say "last Canopy log lines:"; tail -20 "$ARTIFACTS/canopy.log"; } || true
}

cmd_test() {
  local ws scheme dest
  ws="$(detect_workspace | tr -d '[:space:]')"; [ -n "$ws" ] || die "run gen first"
  scheme="$(detect_scheme)"
  dest="platform=iOS Simulator,name=$SIM_DEVICE"
  say "xcodebuild test  scheme=$scheme  dest=[$dest]"
  mac_ios "set -o pipefail && xcodebuild \
      -workspace $(printf '%q' "$ws") -scheme $(printf '%q' "$scheme") \
      -configuration $(printf '%q' "$CONFIG") -sdk iphonesimulator \
      -destination $(printf '%q' "$dest") -derivedDataPath build \
      test 2>&1 | tee remote-artifacts/test.log" \
    && { pull "$REMOTE_IOS/remote-artifacts/test.log" "$ARTIFACTS/test.log"; ok "TESTS PASSED — $ARTIFACTS/test.log"; } \
    || { pull "$REMOTE_IOS/remote-artifacts/test.log" "$ARTIFACTS/test.log"; die "tests failed — see $ARTIFACTS/test.log"; }
}

cmd_logs()  { pull "$REMOTE_IOS/remote-artifacts/build.log" "$ARTIFACTS/build.log"; ok "$ARTIFACTS/build.log"; }
cmd_shell() { mac_tty "cd $(printf '%q' "$REMOTE_IOS"); exec bash -l"; }
cmd_clean() {
  say "Removing generated project / Pods / build on the Mac (keeps source + node_modules)…"
  mac_ios "rm -rf *.xcodeproj *.xcworkspace Pods Podfile.lock build DerivedData" && ok "cleaned"
}

cmd_all() {
  cmd_sync
  cmd_bootstrap
  cmd_gen
  cmd_build
  cmd_run
  ok "Full pipeline complete. Review $ARTIFACTS/{build.log,screen.png,canopy.log}"
}

# ------------------------------------------------------------------------------------------
usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"; shift || true
  # allow `build -- -quiet` style passthrough
  [ "${1:-}" = "--" ] && shift || true
  case "$sub" in
    provision) cmd_provision "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    sync)      cmd_sync "$@" ;;
    bundle)    cmd_bundle "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    gen)       cmd_gen "$@" ;;
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
