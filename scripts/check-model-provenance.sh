#!/usr/bin/env bash
# check-model-provenance.sh — fail-closed ship-gate over the MODEL assets the app actually bundles.
#
# The canopy/native analog of apps/lumen/ml/tools/shipgate.py, run device-free in CI: every model file
# shipped inside the APK/IPA MUST be accounted for in LICENSES/model-provenance.tsv with a sha256 that
# matches the bytes on disk, carry no banned (FFHQ/StyleGAN2/NC/ArcFace/…) token, and declare a verdict.
#
# Verdicts:
#   CLEAN   — commercially-clean (trained-from-scratch / MIT / Apache-2.0 / BSD / CC0 / CC-BY); shippable.
#   STANDIN — a DEV-ONLY proof model (e.g. the ESPCN super-res stand-in trained on a research dataset).
#             Allowed in CI/dev so the ORT/Core ML path is exercised end-to-end, but the future store-
#             submission gate (SHIP) MUST reject it — this gate prints a LOUD warning so it can't ship
#             unnoticed. Replace with a trained-from-scratch model (apps/lumen/ml/) before a release.
#
# Pure bash + sha256sum + a tiny python dir-hash for the .mlpackage bundle. No network, no SDK.
# Usage:  bash scripts/check-model-provenance.sh
# Exit:   0 = every shipped model is accounted-for, untampered, and not banned · 1 = a leg drifted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROV="$ROOT/LICENSES/model-provenance.tsv"
status=0
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }

# The model assets the build bundles into the app (keep in sync with project.yml / the Android assets dir).
SHIPPED=(
  "host/android/app/src/main/assets/models/super-resolution-10.onnx"
  "host/ios/CanopyHostApp/Resources/models/restore.mlpackage"
)

BANNED='codeformer|gfpgan|restoreformer|gpen|vqfr|stylegan|ffhq|insightface|arcface|scrfd|retinaface|ms-celeb|msceleb|webface|vgg19_in|imagenet1k|yolo|ultralytics|stable-diffusion|sd-v1|sd-v2|creativeml'
NC='(^|[^a-z])nc([^a-z]|$)|noncommercial|non-commercial|s-lab|nvidia-nc|cc-by-nc|research-only|research_only'
ALLOWED_CLEAN='MIT|Apache-2.0|BSD|BSD-3|CC0|CC-BY|trained-from-scratch'

echo "==> model-provenance ship-gate (scripts/check-model-provenance.sh)"
[ -f "$PROV" ] || { red "    FAIL — missing $PROV"; exit 1; }

# sha256 of a file, or the deterministic (relpath+bytes, sorted) hash of a .mlpackage directory.
hash_asset() {
  local p="$1"
  if [ -d "$p" ]; then
    python3 - "$p" <<'PY'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1]); h = hashlib.sha256()
for f in sorted(root.rglob("*")):
    if f.is_file():
        h.update(f.relative_to(root).as_posix().encode()); h.update(f.read_bytes())
print(h.hexdigest())
PY
  else
    sha256sum "$p" | cut -d' ' -f1
  fi
}

# Look up column N (1-based) of the provenance row whose model== $1 (tab-separated).
prov_field() { awk -F'\t' -v m="$1" -v c="$2" '$1==m {print $c; exit}' "$PROV"; }

standins=0
for rel in "${SHIPPED[@]}"; do
  abs="$ROOT/$rel"
  name="$(basename "$rel")"
  if [ ! -e "$abs" ]; then red "    FAIL — shipped model missing on disk: $rel"; status=1; continue; fi

  # banned token in the filename itself
  if printf '%s' "$name" | grep -qiE "$BANNED"; then
    red "    FAIL — $name: banned token in filename"; status=1; continue
  fi

  row="$(awk -F'\t' -v m="$name" '$1==m {print; exit}' "$PROV")"
  if [ -z "$row" ]; then
    red "    FAIL — $name has NO provenance row in LICENSES/model-provenance.tsv (fail-closed)"; status=1; continue
  fi

  # banned / NC token anywhere in the row
  if printf '%s' "$row" | grep -qiE "$BANNED"; then red "    FAIL — $name: banned token in provenance row"; status=1; fi
  if printf '%s' "$row" | grep -qiE "$NC";     then red "    FAIL — $name: non-commercial token in provenance row"; status=1; fi

  verdict="$(prov_field "$name" 6)"
  wlic="$(prov_field "$name" 4)"
  declared_sha="$(prov_field "$name" 7)"
  actual_sha="$(hash_asset "$abs")"

  if [ "$declared_sha" != "$actual_sha" ]; then
    red "    FAIL — $name: sha256 drift (disk ${actual_sha:0:12}… != provenance ${declared_sha:0:12}…) — tamper/stale"; status=1
  fi

  case "$verdict" in
    CLEAN)
      if ! printf '%s' "$wlic" | grep -qiE "^($ALLOWED_CLEAN)$"; then
        red "    FAIL — $name: CLEAN verdict but weights_licence '$wlic' not in the commercial allow-set"; status=1
      else
        green "    OK  — $name: CLEAN ($wlic), sha matches"
      fi
      ;;
    STANDIN)
      standins=$((standins+1))
      warn "    WARN — $name: STANDIN (dev-only, weights='$wlic'); sha matches. The SHIP/store gate MUST reject this — replace with a trained-from-scratch model (apps/lumen/ml/) before a release."
      ;;
    *)
      red "    FAIL — $name: unknown verdict '$verdict' (must be CLEAN or STANDIN)"; status=1
      ;;
  esac
done

echo ""
if [ "$status" -eq 0 ]; then
  if [ "$standins" -gt 0 ]; then
    warn "model-provenance OK — every shipped model is accounted-for + untampered, but $standins is a STANDIN (dev-only; not store-shippable)."
  else
    green "model-provenance OK — every shipped model is CLEAN, accounted-for, and untampered."
  fi
else
  red "model-provenance FAILED — a shipped model is unaccounted-for, tampered, banned, or NC. See LICENSES/model-provenance.tsv."
fi
exit "$status"
