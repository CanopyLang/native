#!/usr/bin/env bash
# init-rn-project.sh — scaffold a runnable RN 0.76.9 project around the portable bench sources.
#
# WHY THIS EXISTS
# ---------------
# The RN sibling app is kept as just THREE portable files in bench/rn-comparison/rn/
# (App.js, index.js, app.json) so it lives in this repo without vendoring a ~700MB RN
# project (android/, ios/, node_modules/). To actually BUILD + RUN it on a device you need
# the native shell + Metro that `@react-native-community/cli init` generates. This script
# does that once: it scaffolds a vanilla RN 0.76.9 app and copies our sources over its
# placeholder App.tsx/index.js/app.json. The result is a normal RN app you can `run-android`.
#
# RN 0.76.9 is the version Canopy/native is ABI-pinned to (host/.../vendor.lock.json,
# hermes-android 0.76.9). Using the SAME RN version the Canopy host links against is what
# makes the head-to-head fair: same Hermes, same Yoga, same Fabric — only the framework on
# top differs.
#
# Usage:
#   bench/rn-comparison/scripts/init-rn-project.sh [<dest-dir>]
#
#     <dest-dir>   where to scaffold the runnable project (default: /tmp/canopy-bench-rn).
#                  Kept OUTSIDE the repo by default so the generated android/node_modules
#                  never bloat the canopy/native tree.
#
# Requires: node >= 18, a JDK 17, the Android SDK, and network access (the CLI downloads the
# RN 0.76.9 template + npm deps). On THIS sandbox RN 0.76.9 is NOT installed (only an unrelated
# Expo RN 0.81.5 elsewhere on disk), so this script is the DOCUMENTED run path — author once on a
# box that has the RN toolchain; the Canopy side runs here today (see bench-compare.sh / README).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rn"
DEST="${1:-/tmp/canopy-bench-rn}"
RN_VERSION="0.76.9"
APP_NAME="CanopyBenchRN"

say() { echo "==> $*"; }

command -v npx >/dev/null 2>&1 || { echo "npx (node) required" >&2; exit 1; }

if [ -d "$DEST" ]; then
  echo "destination already exists: $DEST" >&2
  echo "remove it or pass a fresh <dest-dir>." >&2
  exit 1
fi

say "scaffolding RN $RN_VERSION app '$APP_NAME' -> $DEST"
# --skip-install keeps the first pass fast; we install after copying package.json so our pinned
# react/react-native versions win. --version pins the template to the ABI-matched RN.
npx --yes @react-native-community/cli@latest init "$APP_NAME" \
  --directory "$DEST" \
  --version "$RN_VERSION" \
  --skip-install \
  --pm npm

say "overlaying portable bench sources (App.js / index.js / app.json)"
cp "$SRC/App.js"   "$DEST/App.js"
cp "$SRC/index.js" "$DEST/index.js"
cp "$SRC/app.json" "$DEST/app.json"
# The RN 0.76.9 template ships App.tsx; remove it so index.js resolves OUR App.js.
rm -f "$DEST/App.tsx"

# spec.json is imported by App.js with a relative path `../spec.json`; mirror it next to the
# scaffolded project root's parent so the import resolves, OR copy it inside and rewrite the
# import. Simplest + hermetic: copy spec.json INTO the project and point App.js at it.
cp "$(dirname "$SRC")/spec.json" "$DEST/spec.json"
# rewrite `../spec.json` -> `./spec.json` for the scaffolded layout
sed -i "s#from '../spec.json'#from './spec.json'#" "$DEST/App.js"

say "installing deps (npm) — react@18.3.1 react-native@$RN_VERSION"
( cd "$DEST" && npm install --no-audit --no-fund )

cat <<EOF

Done. Runnable RN $RN_VERSION project at: $DEST

Next:
  1. Boot an emulator or attach a device (the SAME device you benchmark Canopy on).
  2. cd "$DEST" && npx react-native run-android        # builds + installs the debug APK
  3. From the repo:  bench/rn-comparison/scripts/bench-compare.sh --rn-dir "$DEST"
     (drives the same scripted fling/tap on both apps and emits the side-by-side table)

NOTE: package name of the scaffolded app is com.canopybenchrn (RN default from the app name).
      bench-compare.sh autodetects it from android/app/build.gradle applicationId.
EOF
