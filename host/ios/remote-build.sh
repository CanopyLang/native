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
#   ./remote-build.sh archive            # IOS-10: CONFIG=Release DEVICE archive (signed) — pulls archive.log
#   ./remote-build.sh export             # IOS-10: -exportArchive (ExportOptions.plist) -> signed CanopyHost.ipa
#   ./remote-build.sh validate           # IOS-11: altool --validate-app (ASC dry-run, no upload) on the .ipa
#   ./remote-build.sh testflight         # IOS-11: altool --upload-package -> internal TestFlight (ASC .p8 API key)
#   ./remote-build.sh release            # IOS-11: archive -> export -> validate -> testflight (the full chain)
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
case "${1:-help}" in ""|-h|--help|help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

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
# IOS-10 — release archive (signing/ATS/entitlements). The archive + export path needs a paid Apple
# Developer account; these inject the team + distribution channel WITHOUT committing any secret
# (mirrors AND-2's CANOPY_STORE_* gradle props). APPLE_TEAM_ID is the 10-char Team ID; it is set in
# .remote-build.env (gitignored) or the CI secret, never in a tracked file.
: "${APPLE_TEAM_ID:=}"
# Distribution channel for `export`: app-store-connect (App Store/TestFlight, ExportOptions default)
# or release-testing (ad-hoc, for a UDID-provisioned device / BrowserStack DF-1).
: "${EXPORT_METHOD:=app-store-connect}"
# IOS-11 — TestFlight upload (App Store Connect API key, the .p8 auth path). The `testflight` (alias
# `release`/`upload`) subcommand uploads the IOS-10 .ipa to an internal TestFlight group via the ASC
# API. These mirror the IOS-10 fail-closed posture: NO secret is committed — the three ASC creds come
# from .remote-build.env (gitignored) or the CI secrets, and the .p8 itself is referenced by path,
# never inlined into a tracked file.
#   ASC_KEY_ID     — the 10-char App Store Connect API Key ID (Users and Access ▸ Keys).
#   ASC_ISSUER_ID  — the issuer UUID for that key (same page, top of the Keys tab).
#   ASC_API_KEY_P8 — a path ON THE MAC to the downloaded AuthKey_<KEYID>.p8 (you can only download it
#                    ONCE from ASC). altool/notarytool read it via --apiKey/--apiIssuer + the
#                    private-keys search path; we point that search path at this file's directory.
: "${ASC_KEY_ID:=}"
: "${ASC_ISSUER_ID:=}"
: "${ASC_API_KEY_P8:=}"
# Upload tool: altool (xcrun altool --upload-package, the documented ASC upload CLI) is the default.
# `validate` runs `altool --validate-app` first (a dry-run App Store Connect validation, no upload).
: "${UPLOAD_TOOL:=altool}"

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

# ------------------------------------------------------------------------------------------
# IOS-10 — Release archive (signing / ATS / entitlements). The iOS analog of the Android
# `release-security` path. `archive` builds a CONFIG=Release DEVICE (generic iOS) archive with
# automatic signing; `export` re-signs it into a distributable .ipa via ExportOptions.plist.
#
# Both are GATED ON A PAID APPLE DEVELOPER ACCOUNT (a real Team ID + a distribution cert/profile).
# Without APPLE_TEAM_ID, `archive` fails LOUD ("Signing requires a development team") — the
# deliberate fail-closed posture (project.yml leaves DEVELOPMENT_TEAM unset). This is correct: a
# simulator build (the `build` subcommand) needs no team; only the signed device archive does.
# ------------------------------------------------------------------------------------------
cmd_archive() {
  local ws scheme arch log
  ws="$(detect_workspace | tr -d '[:space:]')"
  [ -n "$ws" ] || die "no .xcworkspace on the Mac — run: ./remote-build.sh gen"
  scheme="$(detect_scheme)"
  arch="$REMOTE_IOS/build/CanopyHost.xcarchive"
  log="$REMOTE_IOS/remote-artifacts/archive.log"

  [ -n "$APPLE_TEAM_ID" ] || warn "APPLE_TEAM_ID is unset — the archive will fail at the signing step \
(\"Signing requires a development team\"). Set APPLE_TEAM_ID in .remote-build.env (your 10-char Apple \
Developer Team ID). This is the paid-account gate the IOS-10 plan calls out."

  say "xcodebuild archive  workspace=$ws  scheme=$scheme  config=Release  sdk=iphoneos  team=${APPLE_TEAM_ID:-<unset>}"
  # CONFIG=Release device archive. -allowProvisioningUpdates lets Xcode resolve the distribution
  # cert + profile for the team (automatic signing). DEVELOPMENT_TEAM is injected here (never
  # committed). The Release config in project.yml supplies the production entitlements
  # (aps-environment=production) + the dead-strip-safe link flags (-ObjC/-all_load).
  mac_ios "mkdir -p remote-artifacts && set -o pipefail && xcodebuild \
      -workspace $(printf '%q' "$ws") \
      -scheme $(printf '%q' "$scheme") \
      -configuration Release \
      -sdk iphoneos \
      -destination 'generic/platform=iOS' \
      -archivePath $(printf '%q' "$arch") \
      DEVELOPMENT_TEAM=$(printf '%q' "$APPLE_TEAM_ID") \
      -allowProvisioningUpdates \
      $* \
      archive 2>&1 | tee remote-artifacts/archive.log" \
    && { pull "$log" "$ARTIFACTS/archive.log"; ok "ARCHIVE SUCCEEDED — $arch (log: $ARTIFACTS/archive.log)"; \
         say "next: ./remote-build.sh export   # -> signed CanopyHost.ipa"; } \
    || { pull "$log" "$ARTIFACTS/archive.log"; warn "ARCHIVE FAILED — errors below + full log at $ARTIFACTS/archive.log"; \
         grep -nE 'error:|Signing|provisioning|team' "$ARTIFACTS/archive.log" | head -40 || true; \
         die "archive failed (often: no APPLE_TEAM_ID, or no distribution cert/profile for the team)"; }
}

cmd_export() {
  local arch out log opts
  arch="$REMOTE_IOS/build/CanopyHost.xcarchive"
  out="$REMOTE_IOS/build/export"
  log="$REMOTE_IOS/remote-artifacts/export.log"

  say "xcodebuild -exportArchive  archive=$arch  method=$EXPORT_METHOD  team=${APPLE_TEAM_ID:-<unset>}"
  # Generate a per-run ExportOptions on the Mac from the committed template, substituting the live
  # team + method (the committed ExportOptions.plist keeps the production defaults + placeholder team
  # so no real Team ID is tracked). Pure /usr/bin/python3 plist edit — present on every Mac.
  mac_ios "
    set -e
    export APPLE_TEAM_ID=$(printf '%q' "$APPLE_TEAM_ID") EXPORT_METHOD=$(printf '%q' "$EXPORT_METHOD")
    [ -d $(printf '%q' "$arch") ] || { echo 'no CanopyHost.xcarchive — run: ./remote-build.sh archive'; exit 1; }
    mkdir -p build remote-artifacts
    python3 - <<'PY'
import plistlib, os
src = 'ExportOptions.plist'
with open(src,'rb') as f: opts = plistlib.load(f)
team = os.environ.get('APPLE_TEAM_ID','').strip()
method = os.environ.get('EXPORT_METHOD','app-store-connect').strip()
opts['method'] = method
if team: opts['teamID'] = team
else: opts.pop('teamID', None)   # let Xcode infer from the archive's signing if no team passed
with open('build/ExportOptions.generated.plist','wb') as f: plistlib.dump(opts, f)
print('wrote build/ExportOptions.generated.plist  method=%s team=%s' % (method, team or '<from-archive>'))
PY
    set -o pipefail && xcodebuild \
      -exportArchive \
      -archivePath $(printf '%q' "$arch") \
      -exportPath $(printf '%q' "$out") \
      -exportOptionsPlist build/ExportOptions.generated.plist \
      -allowProvisioningUpdates 2>&1 | tee remote-artifacts/export.log
    # Normalize the exported product name to CanopyHost.ipa (the name the CI device-farm job expects).
    IPA=\$(find $(printf '%q' "$out") -name '*.ipa' | head -1)
    [ -n \"\$IPA\" ] && [ \"\$(basename \"\$IPA\")\" != 'CanopyHost.ipa' ] && mv -f \"\$IPA\" $(printf '%q' "$out")/CanopyHost.ipa || true
  " \
    && { pull "$log" "$ARTIFACTS/export.log"; pull "$out/CanopyHost.ipa" "$ARTIFACTS/CanopyHost.ipa"; \
         ok "EXPORT SUCCEEDED — signed .ipa: $ARTIFACTS/CanopyHost.ipa (log: $ARTIFACTS/export.log)"; } \
    || { pull "$log" "$ARTIFACTS/export.log"; warn "EXPORT FAILED — errors below + full log at $ARTIFACTS/export.log"; \
         grep -nE 'error:|Signing|provisioning|team|exportArchive' "$ARTIFACTS/export.log" | head -40 || true; \
         die "export failed (often: no distribution profile for method=$EXPORT_METHOD, or team mismatch)"; }
}

# ------------------------------------------------------------------------------------------
# IOS-11 — TestFlight upload (App Store Connect API key / .p8 auth path).
#
# Builds on IOS-10's `export`: that produces build/export/CanopyHost.ipa. `testflight` uploads THAT
# .ipa to App Store Connect (which routes it to TestFlight processing → the internal test group) via
# `xcrun altool --upload-app`, authenticated by an ASC API KEY (not an Apple-ID password): the .p8
# private key + its Key ID + Issuer ID. This is the modern, 2FA-proof, CI-friendly auth Apple
# documents for altool/notarytool — exactly the App-Store-Connect-only credential set, no session.
# `--upload-app` (and the `--validate-app` dry-run) read the bundle id / version / build number
# straight out of the .ipa, so no version metadata is hand-passed (it stays the single source of
# truth in project.yml: MARKETING_VERSION / CURRENT_PROJECT_VERSION).
#
# GATED ON A PAID APPLE DEVELOPER ACCOUNT with the App Store Connect "App Manager"/"Admin" role (to
# mint an API key) AND an app record already created in App Store Connect for the bundle id
# (com.canopyhost.app) — the .ipa's version/build must be NEW (ASC rejects a duplicate build number).
# Without the three ASC creds, `testflight` fails LOUD up front (mirrors IOS-10's missing-team gate):
# no secret in a tracked file, the upload simply cannot run unauthenticated.
#
# Why altool and not Transporter/Fastlane: altool ships with Xcode (no extra install on the Mac),
# speaks the ASC API key directly (--apiKey/--apiIssuer), and its --validate-app gives a real
# pre-upload App-Store-Connect validation (the same checks the GUI Organizer runs) so a bad build is
# caught before it consumes an upload slot. notarytool is for notarizing a Developer-ID app (not an
# App Store .ipa), so it is intentionally NOT used here.
# ------------------------------------------------------------------------------------------

# Assert the three ASC creds are present + the .p8 exists ON THE MAC, and echo a one-line summary
# WITHOUT leaking the key bytes. Shared by validate + testflight.
_asc_preflight() {
  local missing=()
  [ -n "$ASC_KEY_ID" ]     || missing+=("ASC_KEY_ID")
  [ -n "$ASC_ISSUER_ID" ]  || missing+=("ASC_ISSUER_ID")
  [ -n "$ASC_API_KEY_P8" ] || missing+=("ASC_API_KEY_P8 (path to AuthKey_*.p8 on the Mac)")
  if [ "${#missing[@]}" -gt 0 ]; then
    die "TestFlight upload needs the App Store Connect API key — set in .remote-build.env (gitignored): ${missing[*]}.
       Mint one at App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API; download AuthKey_<id>.p8 (one chance) and point ASC_API_KEY_P8 at it. See docs/ios-testflight.md."
  fi
  # The .p8 lives on the MAC (uploads run there); verify remotely, not on this Linux box.
  mac "[ -f $(printf '%q' "$ASC_API_KEY_P8") ]" \
    || die "ASC_API_KEY_P8=$ASC_API_KEY_P8 does not exist ON THE MAC ($MAC_SSH). Copy AuthKey_<keyid>.p8 there and set the path."
  say "ASC API key: KeyID=$ASC_KEY_ID  Issuer=$ASC_ISSUER_ID  key=<$(basename "$ASC_API_KEY_P8")> (bytes never printed)"
}

# Emit the remote bash that runs altool with the ASC API key. $1 = the altool verb
# (--validate-app | --upload-app). altool's --apiKey takes the Key ID and finds the matching
# AuthKey_<id>.p8 in one of its private-keys search dirs; we stage the .p8 into a per-run
# ./private_keys (the conventional location) so altool resolves it without touching ~/.appstoreconnect.
_altool_remote() {
  local verb="$1" ipa="$REMOTE_IOS/build/export/CanopyHost.ipa"
  cat <<REMOTE
set -e
IPA=$(printf '%q' "$ipa")
[ -f "\$IPA" ] || { echo 'no CanopyHost.ipa — run: ./remote-build.sh export (IOS-10) first'; exit 1; }
mkdir -p remote-artifacts private_keys
# altool resolves AuthKey_<KeyID>.p8 from ./private_keys (or ~/.appstoreconnect/private_keys, or
# \$API_PRIVATE_KEYS_DIR). Stage a copy with the canonical name so --apiKey just works.
cp -f $(printf '%q' "$ASC_API_KEY_P8") "private_keys/AuthKey_$(printf '%q' "$ASC_KEY_ID").p8"
export API_PRIVATE_KEYS_DIR="\$PWD/private_keys"
set -o pipefail
xcrun altool $verb \\
  --type ios \\
  --file "\$IPA" \\
  --apiKey $(printf '%q' "$ASC_KEY_ID") \\
  --apiIssuer $(printf '%q' "$ASC_ISSUER_ID") \\
  --output-format normal 2>&1 | tee remote-artifacts/${verb#--}.log
rc=\${PIPESTATUS[0]}
# Never leave the private key staged on the build host after the run.
rm -f "private_keys/AuthKey_$(printf '%q' "$ASC_KEY_ID").p8"
exit \$rc
REMOTE
}

# validate — a dry-run App Store Connect validation of the .ipa (no upload, no slot consumed).
cmd_validate() {
  _asc_preflight
  local log="$REMOTE_IOS/remote-artifacts/validate-app.log"
  say "altool --validate-app  (ASC dry-run; no upload) on CanopyHost.ipa"
  mac_ios "$(_altool_remote --validate-app)" \
    && { pull "$log" "$ARTIFACTS/validate-app.log"; ok "VALIDATION PASSED — $ARTIFACTS/validate-app.log"; \
         say "next: ./remote-build.sh testflight   # upload to the internal TestFlight group"; } \
    || { pull "$log" "$ARTIFACTS/validate-app.log"; warn "VALIDATION FAILED — errors below + full log at $ARTIFACTS/validate-app.log"; \
         grep -nE 'ERROR|error|Invalid|provisioning|entitlement|version|build' "$ARTIFACTS/validate-app.log" | head -40 || true; \
         die "validate failed (often: duplicate build number, missing app record, or an entitlement not provisioned for the App ID)"; }
}

# testflight — upload the .ipa to App Store Connect; ASC processes it onto the internal TestFlight
# group. A successful altool upload returns BEFORE TestFlight processing finishes (Apple emails when
# the build is ready); the script reports the upload result + where to watch processing.
cmd_testflight() {
  _asc_preflight
  local log="$REMOTE_IOS/remote-artifacts/upload-app.log"
  say "altool --upload-app  → App Store Connect (TestFlight) for bundle id $APP_BUNDLE_ID"
  warn "the .ipa's CFBundleVersion (build number) must be UNIQUE — ASC rejects a build number it has already seen for this version."
  mac_ios "$(_altool_remote --upload-app)" \
    && { pull "$log" "$ARTIFACTS/upload-app.log"; ok "UPLOAD SUCCEEDED — $ARTIFACTS/upload-app.log"; \
         say "TestFlight is now PROCESSING the build (Apple emails when it is ready for testers)."; \
         say "watch: App Store Connect ▸ your app ▸ TestFlight ▸ Builds; add it to the internal test group when 'Ready to Test'."; } \
    || { pull "$log" "$ARTIFACTS/upload-app.log"; warn "UPLOAD FAILED — errors below + full log at $ARTIFACTS/upload-app.log"; \
         grep -nE 'ERROR|error|Invalid|provisioning|entitlement|version|build|authenticate' "$ARTIFACTS/upload-app.log" | head -40 || true; \
         die "upload failed (often: duplicate build number, missing app record, or the API key lacks the App Manager role)"; }
}

# release — the whole IOS-11 chain from source on the Mac: archive (IOS-10) -> export (IOS-10) ->
# validate (dry-run) -> testflight (upload). Each phase fails LOUD; the chain stops on the first.
cmd_release() {
  say "IOS-11 release chain: archive → export → validate → testflight"
  cmd_archive
  cmd_export
  cmd_validate
  cmd_testflight
  ok "RELEASE COMPLETE — the signed .ipa is uploaded; TestFlight is processing it. Review $ARTIFACTS/{archive,export,validate-app,upload-app}.log"
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
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    archive)   cmd_archive "$@" ;;
    export)    cmd_export "$@" ;;
    validate)  cmd_validate "$@" ;;
    testflight|upload) cmd_testflight "$@" ;;
    release)   cmd_release "$@" ;;
    logs)      cmd_logs "$@" ;;
    shell)     cmd_shell "$@" ;;
    clean)     cmd_clean "$@" ;;
    all)       cmd_all "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown subcommand '$sub' — run: ./remote-build.sh help" ;;
  esac
}
main "$@"
