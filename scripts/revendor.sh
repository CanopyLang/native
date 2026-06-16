#!/usr/bin/env bash
# revendor.sh — vendor provenance gate + scripted re-vendor for canopy/native (RNV-1 + RNV-3).
#
# The host ships third-party prebuilts (Hermes/JSI/fbjni + onnxruntime), their header trees,
# and iOS pod pins. host/vendor.lock.json records source/version/date + a sha256 per file.
# This wrapper drives the `canopy-native` tool's vendor-lock / vendor-verify subcommands, and
# (RNV-3) the `fetch` subcommand that re-downloads + re-extracts the upstream artifacts into the
# vendored layout from a single command, idempotently.
#
#   ./scripts/revendor.sh verify              # recompute every checksum and diff the committed
#                                             # lock; exits NON-ZERO (names the file) on drift.
#   ./scripts/revendor.sh lock                # regenerate host/vendor.lock.json from disk.
#   ./scripts/revendor.sh fetch [<rn-version>]# download/unzip the matched Hermes/JSI/onnx
#                                             # binaries + header trees into host/android/vendor,
#                                             # then verify byte-identity against the lock.
#   ./scripts/revendor.sh fetch --ios-stub    # iOS-only: print the (Mac-gated) pod-vendor steps
#                                             # and validate the Frameworks/ layout doc. Authored
#                                             # + bash-checked here; the real pull needs a Mac.
#   ./scripts/revendor.sh cadence             # RNV-6: validate host/android/vendor/cadence-pin.json
#                                             # (the INDEPENDENT Hermes+Yoga pin, decoupled from RN's
#                                             # release train) + report the 2x/year-review policy.
#                                             # Offline + jq-only, so CI can run it as a cheap gate.
#   ./scripts/revendor.sh cadence --fetch-hermes [<tag>]
#                                             # pull the STANDALONE facebook/hermes runtime (its own
#                                             # version line) into a scratch tree + probe it for the
#                                             # C-ABI vtable (RNV-4 backend-(B) gate). Never touches
#                                             # the active vendored libhermes. See CADENCE-PIN.md.
#
# CI runs `revendor.sh verify` as a cheap early gate (no emulator/Mac needed).
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# IDEMPOTENCY (RNV-3's load-bearing promise) — what `fetch` CAN and CANNOT reproduce
# ─────────────────────────────────────────────────────────────────────────────────────────────
# Empirically (every claim below was verified by downloading the real upstreams and diffing the
# bytes against what is committed — see the per-artifact notes), the vendored set splits in two:
#
#   REPRODUCIBLE byte-identically from a single Maven coordinate (fetch re-creates these):
#     • lib/<abi>/libhermes.so   ⟵ hermes-android-<rn>-release.aar  : jni/<abi>/libhermes.so
#     • lib/<abi>/libjsi.so      ⟵ react-android-<rn>-release.aar   : jni/<abi>/libjsi.so
#     • onnxruntime/lib/<abi>/libonnxruntime.so ⟵ onnxruntime-android-<onnx>.aar : jni/<abi>/…
#     • hermes-include/          ⟵ hermes AAR prefab include/{hermes,hermes_abi,hermes_sandbox}
#                                   PLUS a flattened copy of include/hermes/* at the tree root
#     • jsi-include/jsi/         ⟵ react AAR prefab/modules/jsi/include/jsi  (verbatim)
#     • onnxruntime/include/     ⟵ onnxruntime AAR headers/                  (verbatim)
#
#   NOT reproducible from the obvious upstream — these were hand-extracted / additionally
#   processed with steps that were never recorded, so `fetch` deliberately does NOT overwrite
#   them. It re-verifies them against the lock and FAILS LOUD on any drift (so a bump can't
#   silently clobber known-good bytes with a wrong build):
#     • lib/<abi>/libfbjni.so    — the committed binary is a DIFFERENT build than fbjni 0.6.0's
#                                  or react-android 0.76.9's libfbjni.so (different ELF build-id,
#                                  ~177 KB vs ~185 KB — additionally stripped from an unrecorded
#                                  source). fetch keeps the committed bytes; revendoring it is
#                                  manual archaeology (see "FBJNI — manual" below).
#     • host/shared/third_party/jsi/jsi/ — a 3rd, distinct jsi header set (jsi.h is 55074 B vs
#                                  the AAR's 55434 B); neither the react-android prefab jsi nor
#                                  jsi-include. Hand-curated; fetch leaves it untouched.
#
# So `fetch` followed by `verify` is GREEN today against the committed tree: it reproduces the
# reproducible artifacts byte-for-byte and confirms the two manual ones are unchanged. That is
# the strongest honest idempotency guarantee the real provenance allows.
#
# FBJNI — manual: to revendor libfbjni.so, locate the exact build the committed sha256 came from
# (record its origin in this file when found), strip it for arm64-v8a + x86_64, drop the results
# at host/android/vendor/lib/<abi>/libfbjni.so, then `revendor.sh lock`. Until then `fetch`
# leaves it alone on purpose.
#
# Bump CANOPY_ABI_VERSION / the C++ ABI pin (scripts/check-abi.sh) only if the surface changed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_YAML="$ROOT/tool/stack.yaml"
VENDOR="$ROOT/host/android/vendor"

# ── Upstream pins (kept in lockstep with host/vendor.lock.json + the ABI gate) ───────────────
# The default RN version is the one host/vendor.lock.json pins today; `fetch <rn-version>`
# overrides it for a bump (you then re-run `lock`, then check-abi.sh, then move the C++ pin).
DEFAULT_RN_VERSION="0.76.9"
FBJNI_VERSION="0.6.0"          # documented for the manual fbjni path only (not auto-fetched).
ONNX_VERSION="1.26.0"
MAVEN="https://repo1.maven.org/maven2"

# ── RNV-6 (decouple cadence): the independent Hermes + Yoga pin ─────────────────────────────
# canopy/native does NOT use Fabric, so it does not need to ride RN's release train for the only
# three surfaces it touches (Hermes / JSI / Yoga). The independent pin lives in the machine-
# readable host/android/vendor/cadence-pin.json (human record: CADENCE-PIN.md, same dir). The
# `cadence` subcommand validates it, reports the 2x/year-review policy, and (with --fetch-hermes)
# exercises the standalone facebook/hermes runtime pull + C-ABI vtable probe. See CADENCE-PIN.md.
CADENCE_PIN="$VENDOR/cadence-pin.json"
HERMES_GH_RELEASES="https://github.com/facebook/hermes/releases/download"

run_tool() {
  # `stack run` is incremental; the tool is tiny and warm in CI's stack cache.
  stack --stack-yaml "$STACK_YAML" run canopy-native -- "$@"
}

# Scratch dir for `fetch`, cleaned by a script-level EXIT trap. An EXIT trap (not a function
# RETURN trap) is the robust choice here: it also fires when `set -e` aborts mid-fetch (e.g. a
# verify failure on a drifted manual artifact), so we never leak a multi-hundred-MB temp tree.
WORK=""
# NOTE: must end on a success status. As an EXIT trap, cleanup's own return code becomes the
# script's exit code, so a bare `[ -n "$WORK" ] && rm …` (which returns 1 when WORK is empty,
# i.e. every verify/lock/ios-stub run) would turn a GREEN run into a spurious non-zero exit and
# fail CI's cheap early gate. Guard with an explicit if + `return 0`.
cleanup() {
  if [ -n "$WORK" ]; then
    rm -rf "$WORK"
  fi
  return 0
}
trap cleanup EXIT

# ── small helpers ─────────────────────────────────────────────────────────────────────────────
log()  { printf '%s\n' "$*"; }
die()  { printf 'revendor: %s\n' "$*" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found on PATH (needed for fetch)"
}

# download <url> <dest> — curl with a clear failure, skipping a re-download if the file is
# already present (cheap idempotency; the byte-level guarantee is the later verify step).
download() {
  local url="$1" dest="$2"
  if [ -f "$dest" ]; then
    log "    cached  $(basename "$dest")"
    return 0
  fi
  log "    GET     $url"
  curl -fSL --retry 3 --retry-delay 2 -o "$dest" "$url" \
    || die "download failed: $url"
}

# ── fetch (Android) ───────────────────────────────────────────────────────────────────────────
# Re-creates the reproducible vendored artifacts from upstream AARs into a temp staging tree,
# then swaps each into place, then verifies byte-identity against the lock.
fetch_android() {
  local rn="${1:-$DEFAULT_RN_VERSION}"
  need_tool curl
  need_tool unzip

  log "==> revendor fetch: react-native $rn / onnxruntime $ONNX_VERSION (Android)"
  log "    vendor dir: ${VENDOR#$ROOT/}"
  log

  WORK="$(mktemp -d)"   # cleaned by the script-level EXIT trap (survives a set -e abort)

  local dl="$WORK/dl" stage="$WORK/stage"
  mkdir -p "$dl" "$stage"

  # 1. Download the three AARs we can reproduce from. (fbjni is intentionally NOT fetched.)
  log "--> [1/4] downloading upstream AARs"
  local hermes_aar="$dl/hermes-android-$rn-release.aar"
  local react_aar="$dl/react-android-$rn-release.aar"
  local onnx_aar="$dl/onnxruntime-android-$ONNX_VERSION.aar"
  download "$MAVEN/com/facebook/react/hermes-android/$rn/hermes-android-$rn-release.aar" "$hermes_aar"
  download "$MAVEN/com/facebook/react/react-android/$rn/react-android-$rn-release.aar"   "$react_aar"
  download "$MAVEN/com/microsoft/onnxruntime/onnxruntime-android/$ONNX_VERSION/onnxruntime-android-$ONNX_VERSION.aar" "$onnx_aar"
  log

  # 2. Unzip each AAR once into its own dir under the staging area.
  log "--> [2/4] extracting AARs"
  local hx="$stage/hermes" rx="$stage/react" ox="$stage/onnx"
  mkdir -p "$hx" "$rx" "$ox"
  unzip -q -o "$hermes_aar" -d "$hx"
  unzip -q -o "$react_aar"  -d "$rx"
  unzip -q -o "$onnx_aar"   -d "$ox"
  log

  # 3. Assemble the vendored layout in a fresh build tree, then swap it into host/android/vendor.
  log "--> [3/4] assembling the vendored layout"
  local out="$stage/out"
  mkdir -p \
    "$out/lib/arm64-v8a" "$out/lib/x86_64" \
    "$out/onnxruntime/lib/arm64-v8a" "$out/onnxruntime/lib/x86_64" \
    "$out/onnxruntime/include" \
    "$out/jsi-include/jsi" \
    "$out/hermes-include"

  local abi
  for abi in arm64-v8a x86_64; do
    # .so files come from each AAR's STRIPPED jni/<abi>/ copy (NOT the larger prefab/ copy).
    cp "$hx/jni/$abi/libhermes.so"      "$out/lib/$abi/libhermes.so"
    cp "$rx/jni/$abi/libjsi.so"         "$out/lib/$abi/libjsi.so"
    cp "$ox/jni/$abi/libonnxruntime.so" "$out/onnxruntime/lib/$abi/libonnxruntime.so"
  done

  # hermes-include = prefab include/{hermes,hermes_abi,hermes_sandbox} + a flattened copy of
  # include/hermes/* at the tree root (so both `#include "hermes.h"` and "hermes/hermes.h" work).
  local hinc="$hx/prefab/modules/libhermes/include"
  cp -R "$hinc/hermes"          "$out/hermes-include/hermes"
  cp -R "$hinc/hermes_abi"      "$out/hermes-include/hermes_abi"
  cp -R "$hinc/hermes_sandbox"  "$out/hermes-include/hermes_sandbox"
  cp -R "$hinc/hermes/." "$out/hermes-include/"

  # jsi-include/jsi = react AAR prefab/modules/jsi/include/jsi (verbatim).
  cp -R "$rx/prefab/modules/jsi/include/jsi/." "$out/jsi-include/jsi/"

  # onnxruntime/include = onnx AAR headers/ (verbatim).
  cp -R "$ox/headers/." "$out/onnxruntime/include/"

  # Swap the reproducible parts into place. We touch ONLY what we can reproduce, leaving the
  # two manual artifacts (libfbjni.so, third_party/jsi) and the iOS pins untouched on disk.
  cp -f "$out/lib/arm64-v8a/libhermes.so" "$VENDOR/lib/arm64-v8a/libhermes.so"
  cp -f "$out/lib/x86_64/libhermes.so"    "$VENDOR/lib/x86_64/libhermes.so"
  cp -f "$out/lib/arm64-v8a/libjsi.so"    "$VENDOR/lib/arm64-v8a/libjsi.so"
  cp -f "$out/lib/x86_64/libjsi.so"       "$VENDOR/lib/x86_64/libjsi.so"
  cp -f "$out/onnxruntime/lib/arm64-v8a/libonnxruntime.so" "$VENDOR/onnxruntime/lib/arm64-v8a/libonnxruntime.so"
  cp -f "$out/onnxruntime/lib/x86_64/libonnxruntime.so"    "$VENDOR/onnxruntime/lib/x86_64/libonnxruntime.so"
  # Header trees: replace wholesale (a staged rename guards against partial writes).
  rm -rf "$VENDOR/hermes-include.new" "$VENDOR/jsi-include.new" "$VENDOR/onnxruntime/include.new"
  cp -R "$out/hermes-include"       "$VENDOR/hermes-include.new"
  cp -R "$out/jsi-include"          "$VENDOR/jsi-include.new"
  cp -R "$out/onnxruntime/include"  "$VENDOR/onnxruntime/include.new"
  rm -rf "$VENDOR/hermes-include" "$VENDOR/jsi-include" "$VENDOR/onnxruntime/include"
  mv "$VENDOR/hermes-include.new"      "$VENDOR/hermes-include"
  mv "$VENDOR/jsi-include.new"         "$VENDOR/jsi-include"
  mv "$VENDOR/onnxruntime/include.new" "$VENDOR/onnxruntime/include"
  log "    refreshed: libhermes.so, libjsi.so, libonnxruntime.so, hermes-include/, jsi-include/, onnxruntime/include/"
  log "    untouched (manual archaeology — see header): libfbjni.so, host/shared/third_party/jsi/"
  log

  # 4. Prove the result: byte-identity against the committed lock. This is the idempotency gate.
  log "--> [4/4] verifying the refreshed tree against host/vendor.lock.json"
  if [ "$rn" != "$DEFAULT_RN_VERSION" ]; then
    log "    NOTE: rn=$rn differs from the locked $DEFAULT_RN_VERSION — verify is EXPECTED to drift;"
    log "          re-run \`revendor.sh lock\`, then scripts/check-abi.sh, then move the C++ ABI pin."
    run_tool vendor-verify --root "$ROOT" || true
  else
    run_tool vendor-verify --root "$ROOT"
    log
    log "OK — fetch reproduced the vendored tree byte-identically (verify is green)."
  fi
}

# ── fetch (iOS) — authored here, runnable only on a Mac ───────────────────────────────────────
# There is no Mac/xcrun/pod in this environment, so the iOS pull cannot run here. This stub
# prints the exact, reproducible steps a Mac would run and validates the layout doc is present,
# so the path is authored + checked (bash -n) even though the network pull is Mac-gated.
fetch_ios_stub() {
  local rn="${1:-$DEFAULT_RN_VERSION}"
  local layout="$ROOT/host/ios/Frameworks/VENDOR-LAYOUT.md"
  log "==> revendor fetch --ios-stub: pod-vendor steps for react-native $rn (Mac-gated)"
  log
  [ -f "$layout" ] || die "iOS vendor layout doc missing: ${layout#$ROOT/} (RNV-3 expects it)"
  log "    layout doc OK: ${layout#$ROOT/}"
  log
  log "    On a Mac (no equivalent exists on this Linux box), the matched iOS prebuilts are"
  log "    pulled via CocoaPods from the SAME react-native release as Android (Risk #1):"
  log
  log "      cd host/ios"
  log "      npm install react-native@$rn          # populates node_modules/react-native"
  log "      pod install                            # fetches hermes-engine + Yoga prebuilts"
  log "      # to VENDOR them offline, copy the resolved frameworks into Frameworks/:"
  log "      cp -R Pods/hermes-engine/destroot/Library/Frameworks/universal/hermes.xcframework \\"
  log "            Frameworks/hermes.xcframework"
  log "      cp -R Pods/hermes-engine/destroot/.../jsi  Frameworks/jsi"
  log "      # Yoga: vendor Pods/Yoga or keep the Package.swift SPM fallback (see VENDOR-LAYOUT.md)"
  log
  log "    The iOS pins in host/vendor.lock.json (hermes-engine, Yoga) are version-only pod-pins:"
  log "    no in-repo binary to checksum, so \`verify\` confirms only their recorded versions."
  log "    After a Mac pull on a bump, update those pod-pin versions and re-run \`revendor.sh lock\`."
}

# ── cadence (RNV-6): the independent Hermes + Yoga pin ────────────────────────────────────────
# Validate host/android/vendor/cadence-pin.json, report the 2x/year-review policy + the active vs.
# independent pins, and — when run with --fetch-hermes — pull the STANDALONE facebook/hermes
# runtime (its OWN version line, decoupled from RN's) into a staging tree and probe it for the
# C-ABI vtable (get_hermes_abi_vtable, the RNV-4 backend-(B) gate). The plain `cadence` report is
# OFFLINE + toolchain-free (jq only) so CI can run it as a cheap gate; only --fetch-hermes touches
# the network and only into a scratch dir (the ACTIVE vendored libhermes is never disturbed).
#
#   revendor.sh cadence                     # validate + report (offline; CI-safe)
#   revendor.sh cadence --fetch-hermes       # pull the standalone runtime for the pinned tag + probe
#   revendor.sh cadence --fetch-hermes v0.12.0   # ...for a specific Hermes tag

# probe_so_for_vtable <libhermes.so> -> prints "yes"|"no"|"err" (mirrors check-hermes-cabi.sh:
# nm first, pure-python dynsym fallback so it works on a bare runner with no binutils).
probe_so_for_vtable() {
  local so="$1"
  if command -v nm >/dev/null 2>&1; then
    if nm -D --defined-only "$so" 2>/dev/null | grep -q 'get_hermes_abi_vtable'; then
      echo "yes"; else echo "no"; fi
    return 0
  fi
  python3 - "$so" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as fh:
    data = fh.read()
if data[:4] != b"\x7fELF":
    print("err"); sys.exit(0)
end = "<" if data[5] == 1 else ">"
e_shoff = struct.unpack_from(end + "Q", data, 40)[0]
e_shentsize = struct.unpack_from(end + "H", data, 58)[0]
e_shnum = struct.unpack_from(end + "H", data, 60)[0]
secs = []
for i in range(e_shnum):
    base = e_shoff + i * e_shentsize
    sh_type = struct.unpack_from(end + "I", data, base + 4)[0]
    sh_offset = struct.unpack_from(end + "Q", data, base + 24)[0]
    sh_size = struct.unpack_from(end + "Q", data, base + 32)[0]
    sh_link = struct.unpack_from(end + "I", data, base + 40)[0]
    sh_entsz = struct.unpack_from(end + "Q", data, base + 56)[0]
    secs.append((sh_type, sh_offset, sh_size, sh_link, sh_entsz))
for (sh_type, sh_offset, sh_size, sh_link, sh_entsz) in secs:
    if sh_type not in (2, 11) or sh_entsz == 0:
        continue
    str_off = secs[sh_link][1]; str_size = secs[sh_link][2]
    strtab = data[str_off:str_off + str_size]
    for off in range(sh_offset, sh_offset + sh_size, sh_entsz):
        st_name = struct.unpack_from(end + "I", data, off + 0)[0]
        if st_name == 0:
            continue
        e = strtab.find(b"\x00", st_name)
        if strtab[st_name:e] == b"get_hermes_abi_vtable":
            print("yes"); sys.exit(0)
print("no")
PY
}

# jqv <filter> — read a value from the cadence pin; die loudly if jq is missing or the key absent.
jqv() {
  need_tool jq
  jq -er "$1" "$CADENCE_PIN" 2>/dev/null
}

cadence_report() {
  need_tool jq
  [ -f "$CADENCE_PIN" ] || die "cadence pin missing: ${CADENCE_PIN#$ROOT/} (RNV-6 expects it)"
  # Validate the JSON parses + carries the load-bearing keys (a corrupt pin fails loud here).
  jq -e '.schema and .policy.reviewCadence and .yoga.android.coordinate and .hermes.standalonePin.version' \
     "$CADENCE_PIN" >/dev/null 2>&1 \
     || die "cadence-pin.json is malformed or missing required keys (schema/policy/yoga/hermes)"

  log "==> revendor cadence (RNV-6): the independent Hermes + Yoga pin"
  log "    pin file: ${CADENCE_PIN#$ROOT/}    record: ${VENDOR#$ROOT/}/CADENCE-PIN.md"
  log
  log "    POLICY: review the independent pins $(jqv '.policy.reviewCadence')"
  log "      last reviewed: $(jqv '.policy.lastReviewed')   next review by: $(jqv '.policy.nextReviewBy')"
  log
  log "    YOGA (decoupled from RN):"
  log "      android: $(jqv '.yoga.android.coordinate')  [$(jqv '.yoga.android.via')]  — decoupled=$(jqv '.yoga.decoupled')"
  log "      ios:     $(jqv '.yoga.ios.coordinate')  [$(jqv '.yoga.ios.via'), pod fallback]"
  log
  log "    HERMES (decouple vehicle: $(jqv '.hermes.decoupleVehicle')):"
  log "      standalone pin: $(jqv '.hermes.standalonePin.version')  ($(jqv '.hermes.standalonePin.commit' | cut -c1-12))"
  log "      C-ABI vtable exported: $(jqv '.hermes.cabiVtable.exported')   active backend: $(jqv '.hermes.activeBackend')"
  log
  if [ "$(jqv '.hermes.cabiVtable.exported')" = "true" ]; then
    log "    >>> C-ABI available — RNV-4 backend (B) can be flipped (see cabiVtable.flipTrigger)."
  else
    log "    NOTE: no prebuilt Hermes (RN's AARs OR the standalone runtime) exports the C-ABI vtable;"
    log "          RNV-4 backend (B) stays gated on a from-source Hermes build. This is correct + green."
    log "          The live probe is scripts/check-hermes-cabi.sh; it flips the day a vendored libhermes"
    log "          exports get_hermes_abi_vtable."
  fi
  log
  # Surface a soft reminder if the review window has passed (does NOT fail the gate — advisory only).
  local nextby today
  nextby="$(jqv '.policy.nextReviewBy')"
  today="$(date -u +%Y-%m-%d)"
  if [ "$today" \> "$nextby" ]; then
    log "    ADVISORY — the 2x/year pin review is OVERDUE (next-review-by $nextby has passed). Re-review"
    log "    the Hermes/Yoga pins, bump policy.nextReviewBy, and re-run scripts/check-abi.sh."
  fi
  log "OK — cadence pin is valid (offline report; --fetch-hermes exercises the standalone Hermes pull)."
}

cadence_fetch_hermes() {
  need_tool jq
  need_tool curl
  need_tool tar
  need_tool unzip
  [ -f "$CADENCE_PIN" ] || die "cadence pin missing: ${CADENCE_PIN#$ROOT/}"

  local tag="${1:-}"
  [ -n "$tag" ] || tag="$(jqv '.hermes.standalonePin.tag')"
  local asset="hermes-runtime-android-$tag.tar.gz"
  local url="$HERMES_GH_RELEASES/$tag/$asset"

  log "==> revendor cadence --fetch-hermes: standalone facebook/hermes runtime ($tag)"
  log "    This pulls Hermes from its OWN release line (decoupled from RN) into a SCRATCH tree and"
  log "    probes it for the C-ABI vtable. The ACTIVE vendored libhermes under host/android/vendor/lib"
  log "    is NOT modified (see CADENCE-PIN.md for why v0.11.0 is the vehicle, not the active binary)."
  log

  WORK="$(mktemp -d)"   # cleaned by the script-level EXIT trap
  local dl="$WORK/$asset"
  log "    GET     $url"
  curl -fSL --retry 3 --retry-delay 2 -o "$dl" "$url" \
    || die "download failed: $url (is '$tag' a facebook/hermes release with an android runtime asset?)"

  # Verify the tarball sha256 against the pin IFF this is the pinned tag (a bump uses a new tag, so
  # a mismatch there is expected — we only assert byte-identity for the recorded pin).
  local pinned_tag pinned_sha
  pinned_tag="$(jqv '.hermes.standalonePin.tag')"
  if [ "$tag" = "$pinned_tag" ] && command -v sha256sum >/dev/null 2>&1; then
    pinned_sha="$(jqv '.hermes.standalonePin.tarballSha256')"
    local got_sha
    got_sha="$(sha256sum "$dl" | cut -d' ' -f1)"
    if [ "$got_sha" = "$pinned_sha" ]; then
      log "    OK — tarball sha256 matches the pin ($pinned_sha)."
    else
      die "tarball sha256 drift for the pinned $tag: got $got_sha, pin records $pinned_sha"
    fi
  fi

  local ex="$WORK/ex"
  mkdir -p "$ex"
  tar -xzf "$dl" -C "$ex"
  # The stripped, app-shippable libhermes.so lives inside hermes-release.aar at jni/<abi>/.
  local aar
  aar="$(find "$ex" -name 'hermes-release.aar' | head -1)"
  [ -n "$aar" ] || die "standalone runtime tarball did not contain hermes-release.aar (unexpected layout)"
  local aex="$WORK/aar"; mkdir -p "$aex"
  unzip -q -o "$aar" -d "$aex"

  log
  log "    C-ABI vtable probe on the STANDALONE $tag libhermes (per ABI):"
  local any=0 all_yes=1
  local abi so res
  for abi in arm64-v8a x86_64; do
    so="$aex/jni/$abi/libhermes.so"
    if [ ! -f "$so" ]; then
      log "      $abi  -> (no jni/$abi/libhermes.so in this runtime)"; all_yes=0; continue
    fi
    any=1
    res="$(probe_so_for_vtable "$so")"
    case "$res" in
      yes) log "      $abi  -> EXPORTS get_hermes_abi_vtable (C-ABI available)";;
      no)  log "      $abi  -> does NOT export get_hermes_abi_vtable (C++ makeHermesRuntime only)"; all_yes=0;;
      *)   log "      $abi  -> could not parse the .so (treating as unavailable)"; all_yes=0;;
    esac
  done
  log
  if [ "$any" -eq 1 ] && [ "$all_yes" -eq 1 ]; then
    log "    CAPABILITY — standalone $tag EXPORTS the C-ABI vtable on every ABI."
    log "    >>> Flip RNV-4 backend (B): set cadence-pin.json .hermes.cabiVtable.exported=true, build"
    log "        with -DCANOPY_HERMES_CABI=1, and make backend (B) the default in CanopyHermes.cpp."
    log "        (Then re-vendor this libhermes as the active binary + move the C++ ABI pin in lockstep.)"
  else
    log "    ADVISORY — standalone $tag exports ONLY the C++ makeHermesRuntime (no C-ABI vtable)."
    log "    Matches the recorded RNV-6 finding: NO prebuilt Hermes ships get_hermes_abi_vtable; the"
    log "    durable C-vtable backend is gated on a from-source build. Backend (A) stays correct today."
  fi
  log
  log "    (Scratch-only: nothing under host/android/vendor/lib was modified.)"
}

# ── dispatch ──────────────────────────────────────────────────────────────────────────────────
cmd="${1:-verify}"
shift || true
case "$cmd" in
  verify)
    log "==> revendor: verifying host/vendor.lock.json against the files on disk"
    run_tool vendor-verify --root "$ROOT"
    ;;
  lock)
    log "==> revendor: regenerating host/vendor.lock.json from the files on disk"
    run_tool vendor-lock --root "$ROOT"
    ;;
  fetch|download)
    if [ "${1:-}" = "--ios-stub" ]; then
      shift
      fetch_ios_stub "${1:-}"
    else
      # A leading positional (non-flag) is the rn-version override.
      rn=""
      [ "${1:-}" != "" ] && [ "${1#-}" = "${1:-}" ] && rn="$1"
      fetch_android "$rn"
    fi
    ;;
  cadence)
    # RNV-6 — the independent Hermes + Yoga pin (decouple from RN's release cadence).
    if [ "${1:-}" = "--fetch-hermes" ]; then
      shift
      cadence_fetch_hermes "${1:-}"
    else
      cadence_report
    fi
    ;;
  *)
    {
      echo "usage: $(basename "$0") {verify|lock|fetch|cadence}"
      echo "  verify                    recompute checksums + diff the committed lock (non-zero on drift)"
      echo "  lock                      regenerate host/vendor.lock.json"
      echo "  fetch [<rn-version>]      download/unzip Hermes/JSI/onnx into host/android/vendor, then verify"
      echo "  fetch --ios-stub [<rn>]   print the Mac-gated iOS pod-vendor steps + check the layout doc"
      echo "  cadence                   RNV-6: validate the independent Hermes/Yoga pin + report the policy"
      echo "  cadence --fetch-hermes [<tag>]  pull the standalone facebook/hermes runtime + probe the C-ABI vtable"
    } >&2
    exit 2
    ;;
esac
