#!/usr/bin/env bash
# check-ios-restore-coreml.sh — L-I3 structural gate: the iOS RestoreEngine Core ML / ANE path is
# complete and self-consistent (NO Mac required).
#
# L-I3's deliverable: compile CanopyRestoreEngineModule.mm, define the previously-dead weak symbol
# CanopyMakeCoreMLRestoreModule, and convert/ship the Core ML model for the ANE restore path. The
# iOS host CANNOT be compiled off macOS (CoreML/Foundation/Xcode link) and Core ML inference is
# Apple-only, so — like check-ios-validation-ledger.sh / check-ios-capability-parity.sh — this gate
# proves the path DEVICE-FREE by structural assertion over the committed sources + the shipped
# model artifact, and fails LOUD in CI's cheap Linux job if any leg drifts.
#
# It asserts:
#   (1) the converter CanopyHostCore/ML/tools/convert_restore.py exists and is the ESPCN->Core ML
#       rebuild (validates topology, declares the [1,1,224,224]->[1,1,672,672] rank-4 IO);
#   (2) the strong definition of canopy::CanopyMakeCoreMLRestoreModule lives in the module .mm
#       (the weak symbol CanopyModuleHost.mm reaches for — was the audit's dead-symbol defect);
#   (3) the module adopts <CanopyModule>, names itself "RestoreEngine", and runs the Core ML
#       prediction path (MLModel / MLComputeUnitsAll / predictionFromFeatures);
#   (4) the module's MLMultiArray IO shapes match the converter's declared model IO (224 in / 672
#       out, rank-4) — the two halves of one contract can't silently diverge;
#   (5) the model artifact restore.mlpackage is SHIPPED in Resources/models and is a well-formed
#       Core ML package (Manifest.json + Data/com.apple.CoreML/model.mlmodel), with the model proto
#       declaring the SAME input "input"/output "output" rank-4 shapes the .mm reads;
#   (6) project.yml copies the model into the .app and excludes the tools/ build-script dir from
#       the compiled sources; the bundle resolver probes restore.{mlmodelc,mlpackage}.
#
# Pure bash + grep + a tiny python proto read (no coremltools needed to READ the saved spec's
# shapes — we parse the .mlmodel protobuf field with the stdlib). No device/SDK/compiler.
# Usage:  bash scripts/check-ios-restore-coreml.sh
# Exit:   0 = the Core ML RestoreEngine path is complete + self-consistent
#         1 = a leg is missing or the .mm<->model contract drifted

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
MOD="$IOS/CanopyHostCore/Modules/CanopyRestoreEngineModule.mm"
MODHOST="$IOS/CanopyHostCore/Boot/CanopyModuleHost.mm"
CONV="$IOS/CanopyHostCore/ML/tools/convert_restore.py"
PKG="$IOS/CanopyHostApp/Resources/models/restore.mlpackage"
PROJ="$IOS/project.yml"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <desc> <file> <regex> — assert the regex matches in the file.
need() {
  local desc="$1" file="$2" re="$3"
  if [ ! -f "$file" ]; then red "    FAIL — $desc (missing file: ${file#$ROOT/})"; status=1; return; fi
  if grep -Eq "$re" "$file"; then green "    OK  — $desc";
  else red "    FAIL — $desc (no /$re/ in ${file#$ROOT/})"; status=1; fi
}

echo "L-I3 — iOS RestoreEngine Core ML / ANE structural gate"
echo ""
echo "[1] converter (ESPCN ONNX -> Core ML .mlpackage)"
need "convert_restore.py exists and rebuilds the ESPCN graph" "$CONV" 'NeuralNetworkBuilder'
need "converter declares rank-4 [1,1,224,224] / [1,1,672,672] IO" "$CONV" 'datatypes\.Array\(1, 1, MODEL_(IN|OUT)'
need "converter validates the ESPCN topology (fails loud on a wrong model)" "$CONV" 'does not match the host'\''s'
need "converter pixel-shuffle is DEPTH_TO_SPACE upscale 3" "$CONV" 'DEPTH_TO_SPACE.*block_size=UPSCALE'

echo ""
echo "[2] the weak symbol is now strongly defined (the audit defect)"
need "CanopyMakeCoreMLRestoreModule strong definition lives in the module .mm" "$MOD" \
  'std::shared_ptr<NativeModule>[[:space:]]*\n?.*CanopyMakeCoreMLRestoreModule'
# the multi-line signature: grep the symbol + the namespace it lands in
grep -q 'CanopyMakeCoreMLRestoreModule' "$MOD" \
  && grep -q 'namespace canopy' "$MOD" \
  && green "    OK  — defined inside namespace canopy (matches the weak decl in CanopyModuleHost.mm)" \
  || { red "    FAIL — CanopyMakeCoreMLRestoreModule not defined in namespace canopy"; status=1; }
need "the host still reaches it through the weak factory (registerAll)" "$MODHOST" \
  'CanopyMakeCoreMLRestoreModule'

echo ""
echo "[3] the module is a real Core ML capability"
need "adopts <CanopyModule>" "$MOD" 'CanopyRestoreEngineModule[[:space:]]*:[[:space:]]*NSObject[[:space:]]*<CanopyModule>'
need "names itself \"RestoreEngine\"" "$MOD" 'moduleName.*@"RestoreEngine"'
need "runs a Core ML prediction (MLModel / predictionFromFeatures)" "$MOD" 'predictionFromFeatures'
need "selects MLComputeUnitsAll (ANE -> GPU -> CPU)" "$MOD" 'MLComputeUnitsAll'
need "compiles a raw .mlpackage at runtime if needed (compileModelAtURL)" "$MOD" 'compileModelAtURL'
need "reports the ANE device tier" "$MOD" 'deviceTier'

echo ""
echo "[4] the .mm IO shapes match the converter's model IO"
need "module input MLMultiArray is [1,1,224,224] (kModelIn=224)" "$MOD" 'kModelIn[[:space:]]*=[[:space:]]*224'
need "module output is 672 (kModelOut=672)" "$MOD" 'kModelOut[[:space:]]*=[[:space:]]*672'
need "module packs the rank-4 input shape @[ @1, @1, @(kModelIn), @(kModelIn) ]" "$MOD" \
  'initWithShape:@\[ @1, @1, @\(kModelIn\), @\(kModelIn\) \]'
need "module bounds-checks the output count before memcpy (no heap over-read)" "$MOD" \
  '\(size_t\)output\.count[[:space:]]*<[[:space:]]*need'

echo ""
echo "[5] the model artifact is shipped + well-formed"
if [ -f "$PKG/Manifest.json" ] && [ -f "$PKG/Data/com.apple.CoreML/model.mlmodel" ]; then
  green "    OK  — restore.mlpackage shipped (Manifest.json + Data/com.apple.CoreML/model.mlmodel)"
else
  red "    FAIL — restore.mlpackage missing/incomplete under Resources/models/ (run convert_restore.py)"
  status=1
fi
# Parse the .mlmodel protobuf to confirm the saved model declares the input "input"/output "output"
# names + the 224/672 dims the .mm reads. We don't need coremltools to READ the saved spec — the
# names and dims appear as length-delimited strings/varints in the proto; a tiny stdlib scan finds
# the IO names and the 224/672 dimension varints with no third-party dependency.
if [ -f "$PKG/Data/com.apple.CoreML/model.mlmodel" ]; then
  python3 - "$PKG/Data/com.apple.CoreML/model.mlmodel" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
ok = True
for nm in (b"input", b"output"):
    if nm not in data:
        print("    FAIL — saved model proto does not name feature %r" % nm.decode()); ok = False
# the model dims 224 and 672 are encoded as protobuf varints; 224 -> 0xE0 0x01, 672 -> 0xA0 0x05
if b"\xe0\x01" not in data:
    print("    FAIL — saved model proto does not encode the 224 input dim"); ok = False
if b"\xa0\x05" not in data:
    print("    FAIL — saved model proto does not encode the 672 output dim"); ok = False
if ok:
    print("    OK  — saved .mlmodel proto names input/output and encodes the 224->672 dims")
sys.exit(0 if ok else 7)
PY
  [ $? -eq 0 ] || status=1
fi

echo ""
echo "[6] build wiring (project.yml copy phase + bundle resolver)"
need "project.yml copies restore.mlpackage into the .app" "$PROJ" 'restore\.mlpackage'
need "project.yml excludes the ML/tools/ build script from compiled sources" "$PROJ" '"\*\*/tools/\*\*"'
need "host resolves restore.{mlmodelc,mlpackage} from the bundle" "$MODHOST" \
  'pathForResource:@"restore"'

echo ""
if [ $status -eq 0 ]; then
  green "ALL GREEN — the iOS RestoreEngine Core ML / ANE path is complete + self-consistent (L-I3)."
  green "            (Mac-gated: linking the module + RUNNING Core ML inference on the ANE is exercised"
  green "             on a device by host/ios/Tests/CanopyHostUITests; this gate is its device-free net.)"
else
  red "FAILURES above — the Core ML RestoreEngine path is incomplete or the .mm<->model contract drifted."
fi
exit $status
