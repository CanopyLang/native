#!/usr/bin/env bash
# setup-local.sh — configure THIS dev box so `canopy`, the Android toolchain, and the build
# scripts all work in a fresh shell. The toolchain is already installed under ~/android-tools
# on this machine; it just isn't exported. This writes the exports to your shell rc and prints
# what to source now. Safe to re-run.
#
# Usage:  ./scripts/setup-local.sh            # detect + persist exports
#         source <(./scripts/setup-local.sh --print)   # just print exports for `source`
set -euo pipefail

TOOLS="${CANOPY_ANDROID_TOOLS:-$HOME/android-tools}"
JDK="$(ls -d "$TOOLS"/jdk-* 2>/dev/null | sort -V | tail -1 || true)"
SDK="$TOOLS/sdk"
LOCALBIN="$HOME/.local/bin"

emit() {
  echo "export JAVA_HOME=\"$JDK\""
  echo "export ANDROID_HOME=\"$SDK\""
  echo "export ANDROID_SDK_ROOT=\"$SDK\""
  echo "export PATH=\"$LOCALBIN:$JDK/bin:$SDK/platform-tools:$SDK/cmdline-tools/latest/bin:$SDK/emulator:\$PATH\""
}

[ "${1:-}" = "--print" ] && { emit; exit 0; }

[ -n "$JDK" ] || { echo "✗ no JDK under $TOOLS (expected jdk-*). Set CANOPY_ANDROID_TOOLS or install one." >&2; exit 1; }
[ -d "$SDK" ] || { echo "✗ no Android SDK at $SDK." >&2; exit 1; }

echo "Detected:"
echo "  JAVA_HOME    = $JDK"
echo "  ANDROID_HOME = $SDK"
echo "  canopy       = $(command -v canopy || echo "$LOCALBIN/canopy (not on PATH)")"
echo

# Persist to the active shell's rc (bash + fish, since this box uses fish).
MARK="# >>> canopy/native env >>>"
add_bash() {
  local rc="$1"
  grep -qF "$MARK" "$rc" 2>/dev/null && { echo "  (already in $rc)"; return; }
  { echo "$MARK"; emit; echo "# <<< canopy/native env <<<"; } >> "$rc"
  echo "  wrote exports to $rc"
}
add_fish() {
  local rc="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$rc")"
  grep -qF "$MARK" "$rc" 2>/dev/null && { echo "  (already in $rc)"; return; }
  {
    echo "$MARK"
    echo "set -gx JAVA_HOME \"$JDK\""
    echo "set -gx ANDROID_HOME \"$SDK\""
    echo "set -gx ANDROID_SDK_ROOT \"$SDK\""
    echo "fish_add_path $LOCALBIN $JDK/bin $SDK/platform-tools $SDK/cmdline-tools/latest/bin $SDK/emulator"
    echo "# <<< canopy/native env <<<"
  } >> "$rc"
  echo "  wrote exports to $rc"
}
[ -f "$HOME/.bashrc" ] && add_bash "$HOME/.bashrc"
[ -f "$HOME/.profile" ] && add_bash "$HOME/.profile"
add_fish

echo
echo "Open a new shell, or for this one:"
echo "  bash:  source <(./scripts/setup-local.sh --print)"
echo "  fish:  ./scripts/setup-local.sh --print | source   # (after translating exports; new shell is simpler)"
echo
echo "Verify:  canopy-native doctor"
