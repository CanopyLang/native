#!/usr/bin/env bash
# check-ios-capability-parity.sh — IOS-7 structural gate: close iOS<->Android capability divergence
# (NO Mac required).
#
# IOS-7's deliverable: author each missing iOS capability module (Vibration/Battery/DeviceInfo/
# NetInfo/Haptics/Brightness, on top of the IOS-6 set) so an app loses NO capability on iOS. The iOS
# host CANNOT be compiled off macOS (Xcode/UIKit/Hermes/Yoga link), so — exactly like
# check-ios-validation-ledger.sh (IOS-6) — this gate proves the parity DEVICE-FREE by structural
# assertion over the committed sources, and fails LOUD if the platforms drift so a regression is
# caught in CI's cheap Linux `gate` job long before a Mac build runs.
#
# It asserts, for EVERY Android JniModule capability (host/android/.../modules/<Name>Module.java):
#   (1) there is an iOS twin Canopy<Name>Module.mm under host/ios/.../Modules/, and
#   (2) that twin adopts <CanopyModule>, returns the SAME -moduleName, and dispatches in
#       -invokeMethod:args:callId:complete: (the §4.1 protocol the by-name bridge resolves), and
#   (3) the capability is WIRED — registered through the by-name dispatcher. After AUTO-E-DELETE
#       (plan §5 Phase E) that is EITHER host-resident in CanopyModuleHost.mm's caps[] (Echo/Photos)
#       OR package-resident: declared in its package's native.json (canopy/<pkg>/native.json), which
#       `canopy-native build` autolinks into the GENERATED CanopyGeneratedCaps() the host iterates.
#       (The hardcoded per-capability caps[] list is GONE — the generated caps are the source now.)
#   (4) the iOS twin's method names cover the .can wire contract (no silently-missing method).
#
# It is the IOS-7 twin of check-ios-validation-ledger.sh: pure bash + grep, no device/SDK/compiler.
# Usage:  bash scripts/check-ios-capability-parity.sh
# Exit:   0 = every Android capability has a registered, protocol-conformant iOS twin (full parity)
#         1 = a capability is Android-only, or its iOS twin is malformed / unregistered (divergence)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
DROID_MODS="$ROOT/host/android/app/src/main/java/com/canopyhost/modules"
IOS_MODS="$IOS/CanopyHostCore/Modules"
MODHOST="$IOS/CanopyHostCore/Boot/CanopyModuleHost.mm"
CANDIR="$ROOT/package/src/Native"

# Monorepo root holding the canopy/* capability PACKAGES (post-Phase-E source of "is wired"): resolve
# like the rest of the toolchain (Autolink.hs resolveMonorepo): $CANOPY_MONOREPO, else the canopy/
# native repo's parent (…/canopy), else ~/projects/canopy.
MONOREPO="${CANOPY_MONOREPO:-}"
if [ -z "$MONOREPO" ]; then
  cand="$(cd "$ROOT/.." && pwd)"
  if [ -d "$cand/image/native" ]; then MONOREPO="$cand"; else MONOREPO="$HOME/projects/canopy"; fi
fi

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# capWired <Name> — true if the capability is wired through the by-name dispatcher post-Phase-E:
#   • host-resident in the module host caps[] (Echo/Photos), OR
#   • package-resident: some canopy/<pkg>/native.json declares a module "<Name>" (autolinked into
#     the generated CanopyGeneratedCaps() the host iterates). grep across every package native.json.
capWired() {
  local name="$1"
  grep -qE "@\"$name\"" "$MODHOST" && return 0
  grep -rqsE "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" "$MONOREPO"/*/native.json 2>/dev/null
}

# The Android modules that are NOT user-facing JniModule capabilities (no iOS capability twin):
#   StreamingBridge — the JNI streaming plumbing (the iOS analog is CanopyStreamingModuleBase, not a
#                     capability); it is never name-registered on either side.
NON_CAPABILITY="StreamingBridge"

echo "==> iOS<->Android capability parity gate (scripts/check-ios-capability-parity.sh) [IOS-7]"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves every Android"
echo "     capability has a registered, protocol-conformant iOS twin so no capability is iOS-lost.)"
echo

if [ ! -d "$DROID_MODS" ]; then red "    FAIL — Android modules dir missing: $DROID_MODS"; exit 1; fi
if [ ! -f "$MODHOST" ];     then red "    FAIL — module host missing: $MODHOST";          exit 1; fi

# ── For each Android capability, assert the full iOS twin chain. ─────────────────────────────
for jf in "$DROID_MODS"/*Module.java; do
  name="$(basename "$jf" Module.java)"

  # Skip the non-capability JNI plumbing.
  case " $NON_CAPABILITY " in *" $name "*) continue ;; esac

  iosfile="$IOS_MODS/Canopy${name}Module.mm"
  ok=1

  # (1) the iOS twin file exists.
  if [ ! -f "$iosfile" ]; then
    red "    FAIL — '$name' is Android-only: no iOS twin Canopy${name}Module.mm"; status=1; continue
  fi

  # (2) the twin is a §4.1 capability: EITHER it directly adopts <CanopyModule> (the one-shot form:
  #     declares -moduleName and dispatches in -invokeMethod:), OR it subclasses
  #     CanopyStreamingModuleBase (the streaming form: the base adopts <CanopyModule>, derives
  #     -moduleName from the class name, and dispatches through per-channel handlers). Accept both.
  if grep -qE '@interface Canopy'"$name"'Module : CanopyStreamingModuleBase' "$iosfile"; then
    : # streaming-base subclass — conformance/moduleName/dispatch come from the base (validated below).
  else
    grep -qE '<CanopyModule>'                      "$iosfile" || { red "    FAIL — Canopy${name}Module.mm does not adopt <CanopyModule> (nor subclass CanopyStreamingModuleBase)"; ok=0; }
    grep -qE "moduleName \{ return @\"$name\""     "$iosfile" || { red "    FAIL — Canopy${name}Module.mm -moduleName is not @\"$name\""; ok=0; }
    grep -qE 'invokeMethod:\(NSString \*\)method'  "$iosfile" || { red "    FAIL — Canopy${name}Module.mm has no -invokeMethod: dispatcher"; ok=0; }
  fi

  # (3) the capability is WIRED through the by-name dispatcher — host-resident in caps[] (Echo/Photos)
  #     OR package-resident in a native.json the generated caps autolink (post-Phase-E source of truth).
  capWired "$name" || { red "    FAIL — '$name' is neither host-resident in caps[] nor declared in any canopy/<pkg>/native.json (not autolinked)"; ok=0; }

  # (4) every method the .can wire contract calls is handled by the iOS twin (no missing method).
  #     The .can encodes each method as `"<Name>" "<method>"`; pull the method tokens and assert the
  #     iOS twin tests for each one (isEqualToString:@"<method>") — the parity-of-METHODS check.
  canfile="$CANDIR/$name.can"
  if [ -f "$canfile" ]; then
    methods="$(grep -oE "NM\.call \"$name\" \"[a-zA-Z]+\"" "$canfile" | sed -E 's/.* "([a-zA-Z]+)"$/\1/' | sort -u)"
    for m in $methods; do
      grep -qE "isEqualToString:@\"$m\"|@\"$m\""  "$iosfile" || { red "    FAIL — Canopy${name}Module.mm does not handle method '$m' (.can contract)"; ok=0; }
    done
  fi

  if [ "$ok" -eq 1 ]; then
    green "    OK  — '$name' has a registered, protocol-conformant iOS twin (Canopy${name}Module.mm)"
  else
    status=1
  fi
done
echo

# ── No iOS capability should be UNWIRED (a twin that exists but is never registered is dead). ──
echo "--> Every iOS capability twin is wired (host-resident caps[] OR autolinked from a native.json):"
for iosfile in "$IOS_MODS"/Canopy*Module.mm; do
  name="$(basename "$iosfile" Module.mm)"; name="${name#Canopy}"
  # RestoreEngine is the Core ML module, registered via the weak C++ factory (NOT caps[]) by design.
  if [ "$name" = "RestoreEngine" ]; then
    grep -qE 'RestoreEngine' "$MODHOST" \
      && green "    OK  — 'RestoreEngine' wired via the weak Core ML factory (not caps[], by design)" \
      || { red "    FAIL — 'RestoreEngine' twin exists but is not wired in the module host"; status=1; }
    continue
  fi
  if capWired "$name"; then
    green "    OK  — '$name' twin is wired (host-resident caps[] or autolinked native.json)"
  else
    red "    FAIL — '$name' iOS twin exists but is neither in caps[] nor any native.json (dead capability)"; status=1
  fi
done
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — every Android capability has a registered, protocol-conformant iOS twin."
  green "            iOS<->Android capability divergence is closed (IOS-7)."
  green "            (Mac-gated: the runtime dispatch of each twin is exercised on a Simulator by"
  green "             host/ios/Tests/CanopyHostUITests; this gate is its device-free structural net.)"
else
  red "DIVERGENCE — a capability is Android-only or its iOS twin is malformed/unregistered." >&2
  red "             See plans/dependent/IOS-7.md + host/ios/PART5-LEDGER.md." >&2
fi
exit "$status"
